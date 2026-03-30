--------------------------------------------------------------------------------
-- Diagnostics.lua | MidnightUI
-- PURPOSE: Error capture, deduplication, filtering, session tracking, and a
--          full in-game debug console UI with grouped export (user-friendly
--          and LLM-ready formats). Also houses the /muimemory deep profiler.
-- DEPENDS ON: None (self-contained; optional integration with MidnightUI_Core,
--             MidnightUI_Settings, MidnightUI_SetDebugNotify)
-- EXPORTS: _G.MidnightUI_Diagnostics (module table M)
--          _G.MidnightUI_DiagnosticsActive (boolean)
--          _G.MidnightUI_DiagnosticsQueue (pre-init message buffer)
--          _G.MidnightUI_DiagnosticsLoadState (string, lifecycle marker)
--          _G.MidnightUI_DiagnosticsFrame (frame ref, after UI creation)
--          _G.MidnightUI_DebugSource(source, message) (convenience global)
--          _G.MidnightUI_ReportError(addon|table, ...) (external error API)
--          _G.MidnightUI_ReportWarning(addon|table, ...) (external warning API)
--          _G.MidnightUI_DiagnosticsHasEntries() (boolean helper)
--          SlashCmdList: /muibugs, /midnightbugs, /muimemory
-- ARCHITECTURE: Runs at BACKGROUND layer — loaded early, captures errors from
--   all addons via seterrorhandler(). Stores entries in SavedVariable
--   MidnightUIDiagnosticsDB. The console UI (CreateUI) is lazily built on
--   first M.Open(). The three-panel layout: left rail (filters/sessions/
--   addons/summary), center (issue stream list), right (inspector/copy-all).
--------------------------------------------------------------------------------
local _G = _G
local CreateFrame = CreateFrame
local date = date
local time = time
local pcall = pcall
local tostring = tostring
local type = type
local table = table
local wipe = wipe

-- ============================================================================
-- ADDON API COMPATIBILITY
-- Normalizes C_AddOns vs legacy global API for metadata, enable state, loaded.
-- ============================================================================
local C_AddOns = _G.C_AddOns
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
local GetAddOnEnableState = (C_AddOns and C_AddOns.GetAddOnEnableState) or _G.GetAddOnEnableState
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded

-- ============================================================================
-- MODULE TABLE & GLOBALS
-- M is the module table stored at _G.MidnightUI_Diagnostics.
-- DiagnosticsQueue buffers debug messages received before EnsureDB() runs.
-- DiagnosticsLoadState is a string lifecycle marker for debugging load order.
-- ============================================================================
local M = _G.MidnightUI_Diagnostics or {}
_G.MidnightUI_Diagnostics = M
_G.MidnightUI_DiagnosticsActive = true
_G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
_G.MidnightUI_DiagnosticsLoadState = "start"

--- M.filter: Per-kind visibility toggles for the console UI.
-- Shape: { LuaError=bool, Warning=bool, UIError=bool, Debug=bool,
--          TaintInferred=bool, TaintExplicit=bool }
M.filter = M.filter or {
    LuaError = true,
    Warning = true,
    UIError = true,
    Debug = true,
    TaintInferred = true,
    TaintExplicit = true,
}

--- M.view: Persisted view-state options (saved in MidnightUIDiagnosticsDB.view).
-- Shape: { groupBySig=bool, bucketView=bool, autoOpen=bool, sessionFilter=string|number,
--          searchText=string, copyAllMode=string, refreshMode=string }
M.view = M.view or { groupBySig = false }

-- ============================================================================
-- CONSTANTS & MODULE-LEVEL STATE
-- ============================================================================
local MAX_ERRORS = 1200          -- Hard cap on stored error entries per session DB
local FLOOD_LIMIT = 30           -- Max entries captured per second before throttling
local allowance = FLOOD_LIMIT    -- Remaining captures allowed this second
local lastSecond = 0             -- Epoch second of last throttle reset
local _droppedCount = 0          -- Entries dropped since last flood-control warning
local inHandler = false          -- Re-entry guard for seterrorhandler callback
local _inCapture = false         -- Re-entry guard for CaptureEntry

local frame                      -- Main diagnostics console frame (lazily created)
local filtered = {}              -- Current filtered view of db.errors (rebuilt on Refresh)
local listButtons = {}           -- Row button widgets in the issue stream list
local selectedIndex = 1          -- Currently highlighted row in filtered[]
local addonFilter = nil          -- Active addon name filter, or nil for "All Addons"
local addonButtons = {}          -- Addon filter button widgets
local addonList = {}             -- Built list of { name, count } for addon sidebar
local sessionList = {}           -- Sorted list of session IDs from db.context
local sessionButtons = {}        -- Session filter button widgets
local sessionMenuFrame           -- Dropdown frame for full session list
local sessionMenuOpen = false
local addonPage = 1              -- Current page in paginated addon sidebar
local addonPageSize = 12         -- Max addon buttons per page
local addonPageCount = 1         -- Total pages
local searchText = ""            -- Normalized search string for MatchesSearch
local sessionFilter = "all"      -- Active session filter: "all", "current", or number
local autoOpenCooldown = 2       -- Seconds between auto-open attempts
local lastAutoOpen = 0           -- Epoch time of last auto-open
local ROW_HEIGHT = 26            -- Pixel height of each issue stream row
local DETAIL_TEXT_MAX_HEIGHT = 180000  -- Max pixel height for detail EditBox content

-- ============================================================================
-- THEME COLORS
-- All UI element colors in one place. Used by StyleFrame, StylePanel, etc.
-- Each value is an {r, g, b} triplet (0-1 range).
-- ============================================================================
local UI_COLORS = {
    bg = {0.06, 0.07, 0.13},
    panel = {0.075, 0.09, 0.15},
    inset = {0.08, 0.10, 0.17},
    border = {0.18, 0.22, 0.30},
    text = {0.92, 0.93, 0.96},
    muted = {0.55, 0.58, 0.64},
    accent = {0.00, 0.78, 1.00},
    accentDim = {0.00, 0.45, 0.62},
    row = {0.12, 0.18, 0.28},
    rowAlt = {0.10, 0.14, 0.22},
}

--- KIND_COLORS: Color-coding for each entry kind in the issue stream.
local KIND_COLORS = {
    LuaError = {1.00, 0.35, 0.35},
    Taint   = {1.00, 0.70, 0.25},
    Warning = {1.00, 0.85, 0.20},
    UIError = {0.85, 0.55, 1.00},
    Debug   = {0.35, 0.85, 1.00},
}

-- ============================================================================
-- KIND LABELS & CLASSIFICATION HELPERS
-- ============================================================================

local KIND_LABELS = { UIError = "Blizzard Error" }

--- KindLabel: Returns the human-readable display label for an entry's kind.
--  Taint entries are further classified as "Potential Taint" when the meta
--  field contains "inferred=true".
-- @param kind (string) - Entry kind: "LuaError", "Taint", "Warning", "UIError", "Debug"
-- @param entry (table|nil) - The full entry, checked for inferred taint flag
-- @return (string) - Display label
local function KindLabel(kind, entry)
    if kind == "Taint" and entry and entry.meta and entry.meta:find("inferred=true", 1, true) then
        return "Potential Taint"
    end
    if kind == "Taint" then return "Taint" end
    return KIND_LABELS[kind] or kind
end

-- ============================================================================
-- COPY-ALL MODE MANAGEMENT
-- Two export formats: "user" (human-readable digest) and "llm" (chaptered
-- packet optimized for AI consumption). Persisted in M.view.copyAllMode.
-- ============================================================================
local COPYALL_MODE_USER = "user"
local COPYALL_MODE_LLM = "llm"

--- NormalizeCopyAllMode: Canonicalizes a mode string to "user" or "llm".
-- @param mode (string|nil) - Raw input from settings or UI
-- @return (string) - "user" or "llm"
local function NormalizeCopyAllMode(mode)
    local value = string.lower(tostring(mode or ""))
    if value == "llm" or value == "llm_ready" or value == "llm-ready" then
        return COPYALL_MODE_LLM
    end
    return COPYALL_MODE_USER
end

--- NormalizeRefreshMode: Canonicalizes refresh mode to "real" or "delayed".
-- @param mode (string|nil) - Raw input
-- @return (string) - "real" or "delayed"
local function NormalizeRefreshMode(mode)
    local value = string.lower(tostring(mode or ""))
    if value == "real" or value == "realtime" then
        return "real"
    end
    return "delayed"
end

--- CopyAllModeLabel: Returns the display label for a copy-all mode.
-- @param mode (string) - "user" or "llm"
-- @return (string) - "LLM-Ready" or "User Friendly"
local function CopyAllModeLabel(mode)
    local m = NormalizeCopyAllMode(mode)
    if m == COPYALL_MODE_LLM then return "LLM-Ready" end
    return "User Friendly"
end

--- GetCopyAllMode: Reads and normalizes the current copy-all mode from M.view.
-- @return (string) - "user" or "llm"
local function GetCopyAllMode()
    if M and M.view then
        local normalized = NormalizeCopyAllMode(M.view.copyAllMode)
        M.view.copyAllMode = normalized
        return normalized
    end
    return COPYALL_MODE_USER
end

--- SetCopyAllMode: Writes the copy-all mode to M.view and returns normalized value.
-- @param mode (string) - "user" or "llm" (or aliases)
-- @return (string) - Normalized mode
local function SetCopyAllMode(mode)
    local normalized = NormalizeCopyAllMode(mode)
    if M and M.view then
        M.view.copyAllMode = normalized
    end
    return normalized
end

-- ============================================================================
-- SAFE STRING HELPERS
-- WoW protects certain values (secrets, tainted strings) that can throw on
-- tostring, concatenation, or table-key indexing. These helpers wrap all
-- operations in pcall to avoid crashing the diagnostics system itself.
-- ============================================================================

--- SafeToString: Protected tostring that detects restricted/secret WoW values.
--  Three-layer check: (1) pcall(tostring), (2) pcall(concat), (3) pcall(table-key).
-- @param value (any) - Value to stringify
-- @return (string) - Safe representation, or "[Restricted]"/
--         "[Restricted Secret Value]" on failure
local function SafeToString(value)
    if value == nil then return "nil" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[Restricted]" end
    local ok2 = pcall(function() return s .. "" end)
    if not ok2 then return "[Restricted]" end
    local ok3 = pcall(function() local t = {}; t[s] = true end)
    if not ok3 then return "[Restricted Secret Value]" end
    return s
end

--- IsMsgSkippable: Returns true if a message is nil-like or restricted and
--  should be silently dropped. Uses pcall because the value may be tainted.
-- @param msg (string) - Message to check
-- @return (boolean)
local function IsMsgSkippable(msg)
    local ok, result = pcall(function()
        return msg == "nil" or msg == "[Restricted]" or msg == "[Restricted Message Hidden]"
    end)
    return ok and result
end

--- IsTaintTrace: Returns true if a message contains the [TaintTrace] marker,
--  indicating it should be classified as Taint rather than Debug.
-- @param msg (string) - Message to check (may be tainted)
-- @return (boolean)
local function IsTaintTrace(msg)
    local ok, result = pcall(function()
        return msg:find("%[TaintTrace%]")
    end)
    return ok and result
end

-- ============================================================================
-- ERROR SIGNATURE EXTRACTION
-- These functions parse file:line signatures from error messages and stacks
-- to produce deduplication keys and identify the source addon.
-- ============================================================================

--- ExtractFileLine: Pulls the first "file.lua:123" pattern from a message.
-- @param msg (string|nil) - Error message or stack line
-- @return (string|nil) - "file.lua:123" or nil
local function ExtractFileLine(msg)
    if not msg then return nil end
    local ok, file, line = pcall(function()
        return string.match(msg, "([^%s]+%.lua):(%d+)")
    end)
    if ok and file and line then return file .. ":" .. line end
    return nil
end

--- IsDiagnosticsFrame: Returns true if the given file path points to
--  Diagnostics.lua itself, used to skip self-references in stack parsing.
-- @param path (string|nil) - File path from a stack frame
-- @return (boolean)
local function IsDiagnosticsFrame(path)
    if not path then return false end
    if string.find(path, "MidnightUI/Diagnostics.lua", 1, true) then return true end
    if string.find(path, "MidnightUI\\Diagnostics.lua", 1, true) then return true end
    return false
end

--- ExtractPrimaryFileLine: Walks a stack trace to find the first file:line
--  that is NOT inside Diagnostics.lua. Falls back to extracting from message.
-- @param stack (string|nil) - Full debugstack output
-- @param message (string|nil) - The error message (fallback source)
-- @return (string|nil) - "file.lua:123" or nil
local function ExtractPrimaryFileLine(stack, message)
    if stack and stack ~= "" then
        local foundFallback = nil
        local ok = pcall(function()
            for rawFile, rawLine in string.gmatch(stack, "([^%s]+%.lua):(%d+)") do
                local sig = rawFile .. ":" .. rawLine
                if not foundFallback then
                    foundFallback = sig
                end
                if not IsDiagnosticsFrame(rawFile) then
                    foundFallback = sig
                    break
                end
            end
        end)
        if ok and foundFallback then
            return foundFallback
        end
    end
    return ExtractFileLine(message)
end

--- FindAddonFromText: Extracts the addon folder name from a file path or
--  error message. Recognizes Interface/AddOns/<name>, FrameXML, SharedXML,
--  and Blizzard_ prefixed addons.
-- @param text (string|nil) - Stack trace, file path, or error message
-- @return (string|nil) - Addon name or "Blizzard", or nil if undetectable
local function FindAddonFromText(text)
    if not text then return nil end
    local addon = string.match(text, "Interface\\AddOns\\([^\\]+)")
    if addon then return addon end
    addon = string.match(text, "Interface/AddOns/([^/]+)")
    if addon then return addon end
    if string.find(text, "Interface\\FrameXML") or string.find(text, "Interface/FrameXML") then return "Blizzard" end
    if string.find(text, "Interface\\SharedXML") or string.find(text, "Interface/SharedXML") then return "Blizzard" end
    if string.find(text, "Blizzard_") then return "Blizzard" end
    return addon
end

--- LooksLikeTaint: Heuristic check for taint-related keywords in text.
--  Used to auto-reclassify non-Taint entries that mention taint/forbidden/blocked.
-- @param text (string|nil) - Message or stack text to scan
-- @return (boolean)
local function LooksLikeTaint(text)
    if not text or text == "" then return false end
    local t = string.lower(text)
    if t:find("taint") then return true end
    if t:find("forbidden") then return true end
    if t:find("blocked") then return true end
    return false
end

-- ============================================================================
-- SETTINGS & DATABASE INITIALIZATION
-- ============================================================================

--- EnsureSettings: Guarantees MidnightUISettings.General exists with diagnostic
--  defaults (diagnosticsEnabled, suppressLuaErrors, diagnosticsToChat).
local function EnsureSettings()
    _G.MidnightUISettings = _G.MidnightUISettings or {}
    local s = _G.MidnightUISettings
    s.General = s.General or {}
    if s.General.diagnosticsEnabled == nil then s.General.diagnosticsEnabled = true end
    if s.General.suppressLuaErrors == nil then s.General.suppressLuaErrors = true end
    if s.General.diagnosticsToChat == nil then s.General.diagnosticsToChat = false end
end

--- BuildContext: Snapshots the current game environment (player info, location,
--  combat state, client version, screen resolution) into a table stored per session.
-- @return (table) - Context snapshot with fields: client, build, buildDate, toc,
--   locale, player, realm, class, classTag, race, raceTag, level, spec,
--   combatLockdown, inCombat, inInstance, instanceType, zone, subzone,
--   uiScale, screenW, screenH
local function BuildContext()
    local ctx = {}
    if GetBuildInfo then
        local version, build, dateStr, toc = GetBuildInfo()
        ctx.client = version
        ctx.build = build
        ctx.buildDate = dateStr
        ctx.toc = toc
    end
    ctx.locale = GetLocale and GetLocale() or nil
    ctx.player = UnitName and UnitName("player") or nil
    ctx.realm = GetRealmName and GetRealmName() or nil
    if UnitClass then
        local className, classTag = UnitClass("player")
        ctx.class = className
        ctx.classTag = classTag
    end
    if UnitRace then
        local raceName, raceTag = UnitRace("player")
        ctx.race = raceName
        ctx.raceTag = raceTag
    end
    ctx.level = UnitLevel and UnitLevel("player") or nil
    if GetSpecialization and GetSpecializationInfo then
        local specIndex = GetSpecialization()
        if specIndex then
            local _, specName = GetSpecializationInfo(specIndex)
            ctx.spec = specName
        end
    end
    if InCombatLockdown then
        ctx.combatLockdown = InCombatLockdown()
    end
    if UnitAffectingCombat then
        ctx.inCombat = UnitAffectingCombat("player")
    end
    if IsInInstance then
        local inInstance, instanceType = IsInInstance()
        ctx.inInstance = inInstance
        ctx.instanceType = instanceType
    end
    if GetRealZoneText then ctx.zone = GetRealZoneText() end
    if GetSubZoneText then ctx.subzone = GetSubZoneText() end
    if UIParent and UIParent.GetScale then
        ctx.uiScale = UIParent:GetScale()
    end
    if GetScreenWidth then ctx.screenW = GetScreenWidth() end
    if GetScreenHeight then ctx.screenH = GetScreenHeight() end
    return ctx
end

--- BuildErrorContext: Lightweight snapshot of game state at the exact moment an
--  error fires. Unlike BuildContext() which runs once at session start, this
--  captures the player's real-time state so exports show what was actually
--  happening when the error occurred.
-- @return (table) - Per-error context with combat, zone, instance, group state
local function BuildErrorContext()
    local ec = {}
    if InCombatLockdown then ec.combat = InCombatLockdown() and true or false end
    if GetRealZoneText then ec.zone = GetRealZoneText() or "" end
    if GetSubZoneText then
        local sz = GetSubZoneText()
        if sz and sz ~= "" then ec.subzone = sz end
    end
    if IsInInstance then
        local inInst, instType = IsInInstance()
        ec.inInstance = inInst and true or false
        ec.instanceType = instType or "none"
    end
    if GetNumGroupMembers then ec.groupSize = GetNumGroupMembers() or 0 end
    if GetSpecialization and GetSpecializationInfo then
        local si = GetSpecialization()
        if si then
            local _, specName = GetSpecializationInfo(si)
            ec.spec = specName
        end
    end
    return ec
end

--- BuildLoadedAddonsList: Returns a compact array of "AddonName:Version" strings
--  for every loaded addon. Stored once per session in the context snapshot.
-- @return (table) - Array of addon identifier strings
local function BuildLoadedAddonsList()
    local result = {}
    local getNum = C_AddOns and C_AddOns.GetNumAddOns or GetNumAddOns
    local getInfo = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
    local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    if not getNum or not getInfo or not isLoaded then return result end
    local ok, count = pcall(getNum)
    if not ok or not count then return result end
    for i = 1, count do
        local okI, name = pcall(getInfo, i)
        if okI and name then
            local okL, loaded = pcall(isLoaded, i)
            if okL and loaded then
                local ver = GetAddOnMetadata and GetAddOnMetadata(name, "Version") or ""
                if ver and ver ~= "" then
                    result[#result + 1] = name .. ":" .. ver
                else
                    result[#result + 1] = name
                end
            end
        end
    end
    return result
end

--- EnsureDB: Initializes the SavedVariable MidnightUIDiagnosticsDB, increments
--  the session counter, and restores persisted view state. Called once during
--  ADDON_LOADED. Also builds an initial context snapshot for this session.
-- @note Mutates M.db, M.view, M.index, M.context and the global SV table.
local function EnsureDB()
    if type(_G.MidnightUIDiagnosticsDB) ~= "table" then _G.MidnightUIDiagnosticsDB = {} end
    local db = _G.MidnightUIDiagnosticsDB
    if type(db.session) ~= "number" then db.session = 0 end
    if type(db.errors) ~= "table" then db.errors = {} end
    if type(db.context) ~= "table" then db.context = {} end
    if type(db.view) ~= "table" then db.view = {} end
    db.session = db.session + 1
    M.db = db
    M.view = db.view
    if M.view.groupBySig == nil then M.view.groupBySig = false end
    if M.view.sessionFilter == nil then M.view.sessionFilter = "all" end
    if M.view.searchText == nil then M.view.searchText = "" end
    if M.view.autoOpen == nil then M.view.autoOpen = false end
    if M.view.bucketView == nil then M.view.bucketView = false end
    if M.view.copyAllMode == nil then M.view.copyAllMode = COPYALL_MODE_USER end
    if M.view.refreshMode == nil then M.view.refreshMode = "delayed" end
    M.view.copyAllMode = NormalizeCopyAllMode(M.view.copyAllMode)
    M.view.refreshMode = NormalizeRefreshMode(M.view.refreshMode)
    M.index = M.index or {}
    M.context = BuildContext()
    M.context.loadedAddons = BuildLoadedAddonsList()
    db.context[db.session] = M.context
end

-- ============================================================================
-- THROTTLE & DEDUPLICATION
-- ============================================================================

--- ThrottleOk: Token-bucket rate limiter — allows FLOOD_LIMIT captures per
--  second. Returns false and increments _droppedCount when exhausted.
-- @return (boolean) - true if the entry may proceed
local function ThrottleOk()
    local now = time()
    if now ~= lastSecond then
        lastSecond = now
        allowance = FLOOD_LIMIT
    end
    if allowance <= 0 then
        _droppedCount = _droppedCount + 1
        return false
    end
    allowance = allowance - 1
    return true
end

--- BuildKey: Produces a deduplication key from kind + message for M.index lookup.
-- @param kind (string) - Entry kind
-- @param message (string) - Composite "message::sig" string
-- @return (string) - "kind::message::sig"
local function BuildKey(kind, message) return kind .. "::" .. message end

--- NormalizeSearch: Trims and lowercases a search string for case-insensitive matching.
-- @param text (string|nil) - Raw search input
-- @return (string) - Normalized needle, or ""
local function NormalizeSearch(text)
    if not text or text == "" then return "" end
    text = tostring(text)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return string.lower(text)
end

--- MatchesSearch: Returns true if an entry matches the current searchText
--  (checked against message, addon, kind, stack, locals, and meta fields).
-- @param e (table|nil) - Error entry
-- @return (boolean)
local function MatchesSearch(e)
    if not searchText or searchText == "" then return true end
    if not e then return false end
    local needle = searchText
    local function HayMatches(hay)
        if not hay or hay == "" then return false end
        return string.find(string.lower(hay), needle, 1, true) ~= nil
    end
    if HayMatches(e.message) then return true end
    if HayMatches(e.addon) then return true end
    if HayMatches(e.kind) then return true end
    if HayMatches(e.stack) then return true end
    if HayMatches(e.locals) then return true end
    if HayMatches(e.meta) then return true end
    return false
end

--- ClampAddonPage: Ensures addonPage stays within [1, addonPageCount].
local function ClampAddonPage()
    if addonPageCount < 1 then addonPageCount = 1 end
    if addonPage < 1 then addonPage = 1 end
    if addonPage > addonPageCount then addonPage = addonPageCount end
end

-- ============================================================================
-- SESSION MANAGEMENT
-- Sessions are auto-incremented on each login/reload. The session dropdown
-- lets users filter the issue stream to a single session for comparison.
-- ============================================================================

--- BuildSessionList: Populates sessionList[] with all session IDs from
--  db.context, sorted descending (newest first).
local function BuildSessionList()
    wipe(sessionList)
    if not M.db or not M.db.context then return end
    for k, _ in pairs(M.db.context) do
        if type(k) == "number" then
            sessionList[#sessionList + 1] = k
        end
    end
    table.sort(sessionList, function(a, b) return a > b end)
end

--- ShowSessionDropdown: Creates and shows a dropdown menu listing all sessions.
--  Uses EasyMenu if available, otherwise builds a manual fallback dropdown.
-- @param anchor (frame) - UI frame to anchor the dropdown to
-- @calls BuildSessionList, M.Refresh
local function ShowSessionDropdown(anchor)
    if not anchor then return end
    BuildSessionList()

    local menu = {}
    menu[#menu + 1] = {
        text = "All Sessions",
        value = "all",
        checked = sessionFilter == "all",
    }
    if M.db and M.db.session then
        menu[#menu + 1] = {
            text = "Current (" .. tostring(M.db.session) .. ")",
            value = "current",
            checked = sessionFilter == "current",
        }
    end
    for i = 1, #sessionList do
        local id = sessionList[i]
        menu[#menu + 1] = {
            text = "Session " .. tostring(id),
            value = id,
            checked = sessionFilter == id,
        }
    end

    local hasEasy = EasyMenu ~= nil

    if hasEasy then
        if not sessionMenuFrame then
            sessionMenuFrame = CreateFrame("Frame", "MidnightUI_SessionDropdown", UIParent, "UIDropDownMenuTemplate")
        end
        local easyMenu = {}
        for i = 1, #menu do
            local item = menu[i]
            easyMenu[#easyMenu + 1] = {
                text = item.text,
                checked = item.checked,
                func = function()
                    M.view.sessionFilter = item.value
                    M.Refresh()
                end,
            }
        end
        EasyMenu(easyMenu, sessionMenuFrame, "cursor", 0, 0, "MENU", 2)
        return
    end

    if not sessionMenuFrame then
        sessionMenuFrame = CreateFrame("Frame", "MidnightUI_SessionDropdownFallback", UIParent, "BackdropTemplate")
        sessionMenuFrame:SetFrameStrata("TOOLTIP")
        sessionMenuFrame:SetFrameLevel(999)
        sessionMenuFrame:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        sessionMenuFrame:SetBackdropColor(UI_COLORS.panel[1], UI_COLORS.panel[2], UI_COLORS.panel[3], 0.96)
        sessionMenuFrame:SetBackdropBorderColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 1)
        sessionMenuFrame.buttons = {}
        sessionMenuFrame:SetScript("OnLeave", function(self)
            if not self._hover then self:Hide() end
        end)
    end

    if sessionMenuFrame:IsShown() then
        sessionMenuFrame:Hide()
        sessionMenuOpen = false
        return
    end

    local maxVisible = 12
    local rowH = 20
    local count = #menu
    local visible = count
    if visible > maxVisible then visible = maxVisible end
    local width = 220
    local height = visible * rowH + 8
    sessionMenuFrame:SetSize(width, height)
    sessionMenuFrame:ClearAllPoints()
    sessionMenuFrame:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, -4)

    for i = 1, #sessionMenuFrame.buttons do
        sessionMenuFrame.buttons[i]:Hide()
    end

    for i = 1, visible do
        local b = sessionMenuFrame.buttons[i]
        if not b then
            b = CreateFrame("Button", nil, sessionMenuFrame, "BackdropTemplate")
            b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
            b:SetBackdropColor(0, 0, 0, 0)
            b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            b.text:SetPoint("LEFT", 8, 0)
            b.text:SetJustifyH("LEFT")
            b:SetHeight(rowH)
            b:SetScript("OnEnter", function(self)
                if sessionMenuFrame then sessionMenuFrame._hover = true end
                self:SetBackdropColor(0.15, 0.2, 0.3, 0.6)
            end)
            b:SetScript("OnLeave", function(self)
                if sessionMenuFrame then sessionMenuFrame._hover = false end
                self:SetBackdropColor(0, 0, 0, 0)
            end)
            sessionMenuFrame.buttons[i] = b
        end
        local item = menu[i]
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", 4, -4 - (i - 1) * rowH)
        b:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * rowH)
        b.text:SetText(item.text)
        if item.checked then
            b.text:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
        else
            b.text:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
        end
        b:SetScript("OnClick", function()
            M.view.sessionFilter = item.value
            M.Refresh()
            sessionMenuFrame:Hide()
            sessionMenuOpen = false
        end)
        b:Show()
    end

    sessionMenuFrame:Show()
    sessionMenuFrame:Raise()
    sessionMenuOpen = true
end

--- MatchesSession: Returns true if an entry belongs to the currently active
--  session filter ("all" passes everything, "current" checks M.db.session,
--  numeric values match e.session directly).
-- @param e (table) - Error entry
-- @return (boolean)
local function MatchesSession(e)
    if not sessionFilter or sessionFilter == "all" then return true end
    if sessionFilter == "current" then
        return M.db and e and e.session == M.db.session
    end
    if type(sessionFilter) == "number" then
        return e and e.session == sessionFilter
    end
    return true
end

-- ============================================================================
-- REFRESH SCHEDULING
-- "delayed" mode batches refreshes with a 10-second cooldown to avoid UI
-- thrash during error floods. "real" mode refreshes immediately.
-- ============================================================================
local refreshQueued = false
local lastRefreshTime = 0
local refreshDelaySeconds = 10
local refreshMode = NormalizeRefreshMode(M and M.view and M.view.refreshMode)

--- SetRefreshMode: Switches between "real" (0s delay) and "delayed" (10s delay).
-- @param mode (string) - "real" or "delayed"
local function SetRefreshMode(mode)
    refreshMode = NormalizeRefreshMode(mode)
    if refreshMode == "real" then
        refreshMode = "real"
        refreshDelaySeconds = 0
    else
        refreshMode = "delayed"
        refreshDelaySeconds = 10
    end
    if M and M.view then
        M.view.refreshMode = refreshMode
    end
end
--- RequestRefresh: Schedules a UI refresh after the rate-limit delay expires.
--  No-ops if the console is not shown or a refresh is already queued.
-- @calls M.Refresh (via C_Timer.After or synchronously)
local function RequestRefresh()
    if not frame or not frame.IsShown or not frame:IsShown() then return end
    if refreshQueued then return end
    local now = time()
    local delay = 0
    if lastRefreshTime > 0 then
        local elapsed = now - lastRefreshTime
        if elapsed < refreshDelaySeconds then
            delay = refreshDelaySeconds - elapsed
        end
    end
    refreshQueued = true
    local timer = _G.C_Timer
    if timer and timer.After then
        timer.After(delay, function()
            refreshQueued = false
            lastRefreshTime = time()
            M.Refresh()
        end)
    else
        refreshQueued = false
        lastRefreshTime = time()
        M.Refresh()
    end
end


-- ============================================================================
-- ENTRY CAPTURE PIPELINE
-- Flow: event handler -> CaptureEntry -> StoreEntry -> RequestRefresh
-- Deduplication: M.index[key] maps to existing entries; repeated errors
-- increment count + update lastSeen instead of creating new rows.
-- ============================================================================

--- StoreEntry: Appends an entry to db.errors, evicting the oldest if over MAX_ERRORS.
-- @param entry (table) - Fully formed error entry
local function StoreEntry(entry)
    local db = M.db
    if not db or not db.errors then return end
    db.errors[#db.errors + 1] = entry
    if #db.errors > MAX_ERRORS then table.remove(db.errors, 1) end
end

--- IsSuppressedDebugMessage: Returns true for known noisy debug messages that
--  should be silently dropped (e.g. Watcher bootstrap, Consumables chatter).
-- @param msg (string) - Debug message text
-- @return (boolean)
local function IsSuppressedDebugMessage(msg)
    if not msg or msg == "" then return false end
    if string.find(msg, "Next clicked: currentStep=", 1, true) then
        return true
    end
    if string.find(msg, "[Watcher] READY bootstrap watcher active", 1, true) then
        return true
    end
    if string.find(msg, "[TaintWatch] READY bootstrap watcher active", 1, true) then
        return true
    end
    if string.find(msg, "[Consumables]", 1, true) then
        return true
    end
    return false
end

--- IsSuppressedBlizzardTargetFrame1097: Suppresses a known Blizzard bug at
--  TargetFrame.lua:1097 ("attempt to compare number with nil").
-- @param msg (string) - Error message
-- @return (boolean)
local function IsSuppressedBlizzardTargetFrame1097(msg)
    if not msg or msg == "" then return false end
    if string.find(msg, "TargetFrame.lua:1097", 1, true)
        and string.find(msg, "attempt to compare number with nil", 1, true) then
        return true
    end
    return false
end

--- IsStackOverflowMessage: Detects "stack overflow" errors. When true,
--  CaptureEntry skips debugstack/debuglocals to avoid deepening the overflow.
-- @param msg (string) - Error message
-- @return (boolean)
local function IsStackOverflowMessage(msg)
    if not msg or msg == "" then return false end
    return string.find(msg, "stack overflow", 1, true) ~= nil
end

--- PruneSuppressedDebugEntries: Retroactively removes previously-stored debug
--  entries that match the suppression list. Called once during ADDON_LOADED
--  to clean up entries captured before the suppression list was finalized.
--  Rebuilds M.index from the surviving entries.
local function PruneSuppressedDebugEntries()
    if not M.db or type(M.db.errors) ~= "table" then return end
    local kept = {}
    for i = 1, #M.db.errors do
        local e = M.db.errors[i]
        if not (e and e.kind == "Debug" and IsSuppressedDebugMessage(e.message)) then
            kept[#kept + 1] = e
        end
    end
    M.db.errors = kept
    M.index = {}
    for i = 1, #kept do
        local e = kept[i]
        if e and e.key then
            M.index[e.key] = e
        end
    end
end

--- CaptureEntry: Central entry point for all diagnostics capture. Deduplicates
--  via M.index, applies throttle, auto-reclassifies taint, and optionally
--  auto-opens the console on new errors outside combat.
-- @param kind (string) - "LuaError", "Warning", "UIError", "Debug", or "Taint"
-- @param message (string) - The error/warning/debug message text
-- @param stack (string) - debugstack output (may be "")
-- @param locals (string) - debuglocals output (may be "")
-- @param meta (string) - Freeform metadata (key=value pairs)
-- @param opts (table|nil) - { skipThrottle=bool, _floodMeta=bool }
-- @return (table|nil) - The entry (new or existing), or nil if skipped
-- @calls SafeToString, ThrottleOk, ExtractPrimaryFileLine, BuildKey,
--        FindAddonFromText, LooksLikeTaint, StoreEntry, RequestRefresh
-- @note Protected by _inCapture re-entry guard to prevent infinite recursion
--       if Diagnostics.lua itself throws during capture.
local function CaptureEntry(kind, message, stack, locals, meta, opts)
    if _inCapture then return end
    _inCapture = true
    local ok, result = pcall(function()
        if not M.db then return nil end
        local msg = SafeToString(message)
        if IsMsgSkippable(msg) then return nil end
        if kind == "Debug" and IsSuppressedDebugMessage(msg) then return nil end
        if not (opts and opts.skipThrottle) and not ThrottleOk() then return nil end
        -- When the flood subsides, emit a Warning about how many entries were dropped
        if _droppedCount > 0 and not (opts and opts._floodMeta) then
            local dropped = _droppedCount
            _droppedCount = 0
            _inCapture = false
            CaptureEntry("Warning",
                "[Diagnostics] " .. tostring(dropped) .. " entries dropped due to flood control",
                "", "", "source=Diagnostics flood_dropped=" .. tostring(dropped),
                { skipThrottle = true, _floodMeta = true })
            _inCapture = true
        end
        local sig = ExtractPrimaryFileLine(stack, msg) or ""
        local key = BuildKey(kind, msg .. "::" .. sig)
        local existing = M.index[key]
        if existing then
            existing.count = (existing.count or 0) + 1
            existing.lastSeen = time()
            existing.errorContext = BuildErrorContext()
            RequestRefresh()
            return existing
        end
        local addon = FindAddonFromText(msg) or FindAddonFromText(stack)
        if kind ~= "Taint" and (LooksLikeTaint(msg) or LooksLikeTaint(stack)) then
            kind = "Taint"
            meta = (meta and meta ~= "" and (meta .. " ")) or ""
            meta = meta .. "inferred=true"
        end
        if (not addon or addon == "") and kind == "Debug" then addon = "MidnightUI" end
        if addon == "Blizzard" and (meta == nil or meta == "") then meta = "source=Blizzard UI" end
        local addonVersion = (GetAddOnMetadata and addon) and GetAddOnMetadata(addon, "Version") or nil
        local addonEnabled = (GetAddOnEnableState and addon) and GetAddOnEnableState(addon, UnitName and UnitName("player") or nil) or nil
        local addonLoaded = (IsAddOnLoaded and addon) and IsAddOnLoaded(addon) or nil
        local entry = {
            key = key,
            kind = kind,
            message = msg,
            stack = stack or "",
            locals = locals or "",
            meta = meta or "",
            sig = sig,
            addon = addon,
            addonVersion = addonVersion,
            addonEnabled = addonEnabled,
            addonLoaded = addonLoaded,
            session = M.db.session or 0,
            contextId = M.db.session or 0,
            errorContext = BuildErrorContext(),
            firstSeen = time(),
            lastSeen = time(),
            count = 1,
        }
        M.index[key] = entry
        StoreEntry(entry)
        RequestRefresh()
        if M.view and M.view.autoOpen then
            local now = time()
            if (now - lastAutoOpen) >= autoOpenCooldown then
                if not (InCombatLockdown and InCombatLockdown()) then
                    if M.Open and (not frame or not frame:IsShown()) then
                        lastAutoOpen = now
                        pcall(M.Open)
                    end
                end
            end
        end
        return entry
    end)
    _inCapture = false
    if ok then return result end
    return nil
end

--- DrainQueuedDiagnostics: Replays messages buffered in MidnightUI_DiagnosticsQueue
--  (captured before EnsureDB ran) into the real capture pipeline.
-- @return (number) - Count of entries drained
-- @calls CaptureEntry
local function DrainQueuedDiagnostics()
    if not M.db then return 0 end
    local q = _G.MidnightUI_DiagnosticsQueue
    if type(q) ~= "table" or #q == 0 then return 0 end
    local drained = 0
    for i = 1, #q do
        local raw = SafeToString(q[i])
        if raw ~= "nil" and raw ~= "[Restricted]" and raw ~= "[Restricted Message Hidden]" then
            local src, msg = string.match(raw, "^%[([^%]]+)%]%s+(.+)$")
            if src and msg then
                local entry = CaptureEntry("Debug", msg, "", "", "source=" .. src .. " queued=true", { skipThrottle = true })
                if entry then entry.addon = src end
            else
                CaptureEntry("Debug", raw, "", "", "source=Queue queued=true", { skipThrottle = true })
            end
            drained = drained + 1
        end
    end
    wipe(q)
    return drained
end

-- ============================================================================
-- ERROR HANDLER & EVENT CALLBACKS
-- These are the entry points from WoW's error/event system into CaptureEntry.
-- ============================================================================

--- GetStackAndLocals: Captures debugstack and debuglocals at depth 3 (caller's
--  caller), protected by pcall in case the debug API is restricted.
-- @return (string) - Stack trace (or "")
-- @return (string) - Local variables dump (or "")
local function GetStackAndLocals()
    local stack = ""
    local locals = ""
    if debugstack then
        local ok, ds = pcall(debugstack, 3, 12, 12)
        if ok and ds then stack = ds end
    end
    if debuglocals then
        local ok2, dl = pcall(debuglocals, 3)
        if ok2 and dl then locals = dl end
    end
    return stack, locals
end

--- OnLuaError: Called by the custom seterrorhandler callback. Captures
--  the error as a LuaError entry. Skips stack capture on stack overflows.
-- @param err (any) - The error value from Lua's error system
-- @calls CaptureEntry
local function OnLuaError(err)
    local msg = SafeToString(err)
    if IsSuppressedBlizzardTargetFrame1097(msg) then
        return
    end
    local stack = ""
    local locals = ""
    local meta = ""
    if not IsStackOverflowMessage(msg) then
        stack, locals = GetStackAndLocals()
    else
        meta = "guard=stack_overflow"
    end
    CaptureEntry("LuaError", msg, stack, locals, meta)
end

--- OnTaint: Handles ADDON_ACTION_BLOCKED and ADDON_ACTION_FORBIDDEN events.
-- @param event (string) - WoW event name
-- @param addonName (string) - Addon that triggered the taint
-- @param action (string) - The blocked/forbidden action
-- @calls CaptureEntry
local function OnTaint(event, addonName, action)
    local meta = "addon=" .. SafeToString(addonName) .. " action=" .. SafeToString(action)
    local msg = SafeToString(event) .. " addon=" .. SafeToString(addonName) .. " action=" .. SafeToString(action)
    local entry = CaptureEntry("Taint", msg, "", "", meta)
    if entry and addonName and addonName ~= "" then entry.addon = addonName end
end

--- OnLuaWarning: Handles the LUA_WARNING event. Captures as Warning kind and
--  also echoes the warning to DEFAULT_CHAT_FRAME for immediate visibility.
-- @param event (string) - "LUA_WARNING"
-- @param warningText (string) - Warning text (post-11.1.5 parameter order)
-- @param pre11_1_5warningText (string|nil) - Warning text (pre-11.1.5 order)
-- @note Parameter order changed in WoW 11.1.5; both orderings are handled.
-- @calls CaptureEntry
local function OnLuaWarning(event, warningText, pre11_1_5warningText)
    local msg = pre11_1_5warningText or warningText
    local rawWarning = tostring(warningText or "") .. " | " .. tostring(pre11_1_5warningText or "")
    if msg == nil or msg == "" then msg = rawWarning end
    if IsMsgSkippable(msg) then return end
    if IsSuppressedBlizzardTargetFrame1097(msg) then return end
    local stack = ""
    local locals = ""
    if debugstack then
        local ok, ds = pcall(debugstack, 3, 10, 10)
        if ok and ds then stack = ds end
    end
    if debuglocals then
        local ok2, dl = pcall(debuglocals, 3)
        if ok2 and dl then locals = dl end
    end
    CaptureEntry("Warning", msg, stack, locals, "raw=" .. rawWarning)
    -- Print warnings directly to the default chat frame (bypassing the
    -- Messenger print override) so they are always visible and don't
    -- re-enter the diagnostics system as a Debug entry.
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        local safe = type(msg) == "string" and msg:gsub("|", "||") or tostring(msg)
        DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[LUA_WARNING]|r " .. safe)
    end
end

local function BuildFocusMeta()
    local focus = _G.GetMouseFocus and _G.GetMouseFocus()
    if not focus then
        return "focus=none"
    end
    local name = ""
    if focus.GetName then
        name = focus:GetName()
    end
    if (not name or name == "") and focus.GetDebugName then
        name = focus:GetDebugName()
    end
    if not name or name == "" then
        local objType = focus.GetObjectType and focus:GetObjectType() or "frame"
        name = "<" .. tostring(objType) .. ">"
    end
    local meta = "focus=" .. SafeToString(name)
    if focus.GetObjectType then
        meta = meta .. " type=" .. SafeToString(focus:GetObjectType())
    end
    return meta
end

local function OnUiError(_, message)
    if message == nil or message == "[Restricted]" or message == "[Restricted Message Hidden]" then return end
    local msgText = message
    local msgId = tonumber(message)
    if msgId then
        local resolved = nil
        if type(_G.GetGameMessageInfo) == "function" then
            local ok, text = pcall(_G.GetGameMessageInfo, msgId)
            if ok and text then resolved = text end
        end
        if not resolved and type(_G.GetGameMessage) == "function" then
            local ok, text = pcall(_G.GetGameMessage, msgId)
            if ok and text then resolved = text end
        end
        if resolved then
            msgText = string.format("%s (id=%d)", tostring(resolved), msgId)
        else
            msgText = string.format("UI_ERROR_ID=%d", msgId)
        end
    end
    local meta = BuildFocusMeta()
    CaptureEntry("UIError", msgText, "", "", meta)
end

function M.LogDebug(message)
    if not M.IsEnabled() then return end
    local msg = SafeToString(message)
    if IsMsgSkippable(msg) then return end
    if not M.db then
        _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
        table.insert(_G.MidnightUI_DiagnosticsQueue, msg)
        return
    end
    local stack = ""
    if debugstack then
        local ok, ds = pcall(debugstack, 3, 10, 10)
        if ok and ds then stack = ds end
    end
    local kind = "Debug"
    local meta = ""
    if IsTaintTrace(msg) then kind = "Taint"; meta = "source=TaintTrace" end
    local entry = CaptureEntry(kind, msg, stack, "", meta)
    if entry and _G.MidnightUI_SetDebugNotify then _G.MidnightUI_SetDebugNotify() end
end

function M.LogDebugSource(source, message)
    if not M.IsEnabled() then return end
    local src = SafeToString(source)
    local msg = SafeToString(message)
    if IsMsgSkippable(msg) then return end
    if not M.db then
        _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
        table.insert(_G.MidnightUI_DiagnosticsQueue, ("[%s] %s"):format(src, msg))
        return
    end
    local meta = "source=" .. src
    local kind = "Debug"
    if IsTaintTrace(msg) then kind = "Taint"; meta = "source=TaintTrace" end
    local entry = CaptureEntry(kind, msg, "", "", meta)
    if entry then entry.addon = src end
    if _G.MidnightUI_SetDebugNotify then _G.MidnightUI_SetDebugNotify() end
end

function M.LogExternal(addon, message, stack, locals, meta, kind)
    if not M.IsEnabled() then return end
    local msg = SafeToString(message)
    if IsMsgSkippable(msg) then return end
    local k = kind or "LuaError"
    local entry = CaptureEntry(k, msg, stack or "", locals or "", meta or "")
    if entry and addon and addon ~= "" then entry.addon = addon end
    if entry and _G.MidnightUI_SetDebugNotify then _G.MidnightUI_SetDebugNotify() end
end

_G.MidnightUI_DebugSource = function(source, message)
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
        _G.MidnightUI_Diagnostics.LogDebugSource(source, message)
    end
end

_G.MidnightUI_ReportError = function(addon, message, stack, locals, meta)
    if type(addon) == "table" then
        local t = addon
        addon = t.addon or t.source or t.name
        message = t.message or t.msg or t.error
        stack = t.stack
        locals = t.locals
        meta = t.meta
    end
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogExternal then
        _G.MidnightUI_Diagnostics.LogExternal(addon, message, stack, locals, meta, "LuaError")
    end
end

_G.MidnightUI_ReportWarning = function(addon, message, stack, locals, meta)
    if type(addon) == "table" then
        local t = addon
        addon = t.addon or t.source or t.name
        message = t.message or t.msg or t.warning
        stack = t.stack
        locals = t.locals
        meta = t.meta
    end
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogExternal then
        _G.MidnightUI_Diagnostics.LogExternal(addon, message, stack, locals, meta, "Warning")
    end
end


function M.HasEntries() return M.db and M.db.errors and #M.db.errors > 0 end
_G.MidnightUI_DiagnosticsHasEntries = function() return M.HasEntries() end

local function SuppressScriptErrors()
    if not ScriptErrorsFrame then return end
    if ScriptErrorsFrame._muiSuppressed then return end
    ScriptErrorsFrame._muiSuppressed = true
    ScriptErrorsFrame:Hide()
    ScriptErrorsFrame.Show = function() return end
    ScriptErrorsFrame:HookScript("OnShow", function(self)
        self:Hide()
    end)
end

local function InstallErrorHandler()
    if not seterrorhandler or not geterrorhandler then return end
    local current = geterrorhandler()
    if current == M._muiErrorHandler then return end
    local priorHandler = current
    local function handler(err)
        if inHandler then return end
        inHandler = true
        pcall(OnLuaError, err)
        local suppressBlizzardErrorFrame = ScriptErrorsFrame and ScriptErrorsFrame._muiSuppressed
        if priorHandler and priorHandler ~= handler and not suppressBlizzardErrorFrame and not IsStackOverflowMessage(SafeToString(err)) then
            pcall(priorHandler, err)
        end
        inHandler = false
    end
    M._muiErrorHandler = handler
    seterrorhandler(handler)
end

local function StyleFrame(f, bg, border)
    if not f then return end
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(bg[1], bg[2], bg[3], 0.96)
    f:SetBackdropBorderColor(border[1], border[2], border[3], 1.0)
end

local function StylePanel(f)
    if not f then return end
    f:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 }
    })
    f:SetBackdropColor(UI_COLORS.panel[1], UI_COLORS.panel[2], UI_COLORS.panel[3], 0.92)
    f:SetBackdropBorderColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.85)
end

local function StyleButton(b)
    if not b or b.MidnightUI_Styled then return end
    b.MidnightUI_Styled = true
    if b.Left then b.Left:Hide() end
    if b.Middle then b.Middle:Hide() end
    if b.Right then b.Right:Hide() end
    local border = b:CreateTexture(nil, "BACKGROUND")
    border:SetTexture("Interface\\Buttons\\WHITE8X8")
    border:SetVertexColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 1.0)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", 0, 0)
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
    bg:SetPoint("TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    local sheen = b:CreateTexture(nil, "ARTWORK")
    sheen:SetTexture("Interface\\Buttons\\WHITE8X8")
    sheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
    sheen:SetPoint("TOPLEFT", 3, -3)
    sheen:SetPoint("BOTTOMRIGHT", -3, 12)
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetTexture("Interface\\Buttons\\WHITE8X8")
    hover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
    hover:SetPoint("TOPLEFT", 2, -2)
    hover:SetPoint("BOTTOMRIGHT", -2, 2)
    b:SetNormalTexture("")
    b:SetHighlightTexture(hover)
    b:SetPushedTexture("")
end

local function CreateHelpIcon(parent, anchorTo, title, lines)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(16, 16)
    btn:SetPoint("LEFT", anchorTo, "RIGHT", 8, 0)
    btn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    btn:SetBackdropColor(0.10, 0.12, 0.18, 0.9)
    btn:SetBackdropBorderColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 1)
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.text:SetPoint("CENTER", 0, 0)
    btn.text:SetText("?")
    btn.text:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    btn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 0.82, 0)
        if lines then
            for i = 1, #lines do
                GameTooltip:AddLine(lines[i], 1, 1, 1, true)
            end
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
    return btn
end

local function BuildFiltered()
    wipe(filtered)
    if not M.db or not M.db.errors then return end
    local function MatchesTaintFilter(e)
        if e.kind ~= "Taint" then return true end
        local inferred = e.meta and e.meta:find("inferred=true", 1, true)
        local allowInferred = M.filter.TaintInferred ~= false
        local allowExplicit = M.filter.TaintExplicit ~= false
        if inferred and not allowInferred then return false end
        if (not inferred) and not allowExplicit then return false end
        return true
    end
    if M.view and (M.view.groupBySig or M.view.bucketView) then
        local groups = {}
        for i = #M.db.errors, 1, -1 do
            local e = M.db.errors[i]
            if e and e.kind and ((e.kind == "Taint" and (M.filter.TaintInferred or M.filter.TaintExplicit)) or M.filter[e.kind]) and MatchesTaintFilter(e) then
                if addonFilter then
                    local name = e.addon or "NoAddon"
                    if addonFilter ~= name then
                        e = nil
                    end
                end
            end
            if e and e.kind and ((e.kind == "Taint" and (M.filter.TaintInferred or M.filter.TaintExplicit)) or M.filter[e.kind]) and MatchesTaintFilter(e) and MatchesSession(e) then
                local sig = e.sig or ""
                local key = (e.kind or "?") .. "::" .. sig
                local g = groups[key]
                if not g then
                    g = {
                        key = key,
                        kind = e.kind,
                        message = e.message,
                        stack = e.stack or "",
                        locals = e.locals or "",
                        meta = e.meta or "",
                        sig = sig,
                        addon = e.addon,
                        session = e.session,
                        contextId = e.contextId,
                        firstSeen = e.firstSeen,
                        lastSeen = e.lastSeen,
                        count = 0,
                        _messages = {},
                        _sessions = {},
                        bucket = M.view and M.view.bucketView == true,
                    }
                    groups[key] = g
                end
                local count = e.count or 1
                g.count = g.count + count
                if e.firstSeen and (not g.firstSeen or e.firstSeen < g.firstSeen) then g.firstSeen = e.firstSeen end
                if e.lastSeen and (not g.lastSeen or e.lastSeen > g.lastSeen) then g.lastSeen = e.lastSeen end
                if g.addon and e.addon and g.addon ~= e.addon then g.addon = "Multiple" end
                if e.message and not g._messages[e.message] then
                    g._messages[e.message] = true
                end
                if e.session then
                    g._sessions[e.session] = true
                end
            end
        end
        for _, g in pairs(groups) do
            local uniqueCount = 0
            for _ in pairs(g._messages) do uniqueCount = uniqueCount + 1 end
            if uniqueCount > 1 then
                g.message = string.format("Grouped %d unique messages", uniqueCount)
            end
            local sessionCount = 0
            for _ in pairs(g._sessions) do sessionCount = sessionCount + 1 end
            g.sessionCount = sessionCount
            g._messages = nil
            g._sessions = nil
            if MatchesSearch(g) then
                filtered[#filtered + 1] = g
            end
        end
        table.sort(filtered, function(a, b)
            return (a.lastSeen or 0) > (b.lastSeen or 0)
        end)
    else
        for i = #M.db.errors, 1, -1 do
            local e = M.db.errors[i]
            if e and e.kind and ((e.kind == "Taint" and (M.filter.TaintInferred or M.filter.TaintExplicit)) or M.filter[e.kind]) and MatchesTaintFilter(e) then
                if not addonFilter then
                    if MatchesSession(e) and MatchesSearch(e) then
                        filtered[#filtered + 1] = e
                    end
                else
                    local name = e.addon or "NoAddon"
                    if addonFilter == name and MatchesSession(e) and MatchesSearch(e) then
                        filtered[#filtered + 1] = e
                    end
                end
            end
        end
    end
    if selectedIndex > #filtered then selectedIndex = #filtered end
    if selectedIndex < 1 then selectedIndex = 1 end
end

local function CountEntriesByKind(list, kind)
    if type(list) ~= "table" then return 0 end
    local count = 0
    for i = 1, #list do
        local e = list[i]
        if e and e.kind == kind then
            count = count + 1
        end
    end
    return count
end

local function NormalizeInlineText(value, maxLen)
    local text = SafeToString(value or "")
    text = text:gsub("[\r\n\t]", " ")
    if maxLen and #text > maxLen then
        text = text:sub(1, maxLen) .. "..."
    end
    return text
end

local function TraceCopyAll(_)
    return
end

local function SetInspectorCopyMode(enabled)
    if not frame then return end
    local active = enabled == true
    frame._muiCopyAllActive = active
    if frame.copyAllScroll then
        if active then frame.copyAllScroll:Show() else frame.copyAllScroll:Hide() end
    end
    if frame.detailScroll then
        if active then frame.detailScroll:Hide() else frame.detailScroll:Show() end
    end
end

local function ShowCopyAllInInspector(text)
    if not frame or not frame.copyAllBox then
        return false, 0, 0, false, "missing_box"
    end
    local payload = text or ""
    local requestedLen = #payload
    SetInspectorCopyMode(true)

    local mode = "raw"
    local okSet = pcall(frame.copyAllBox.SetText, frame.copyAllBox, payload)
    local actualLen = #(frame.copyAllBox:GetText() or "")

    if requestedLen > 0 and actualLen == 0 then
        pcall(frame.copyAllBox.SetText, frame.copyAllBox, "")
        okSet = pcall(frame.copyAllBox.SetText, frame.copyAllBox, payload)
        actualLen = #(frame.copyAllBox:GetText() or "")
    end

    -- Raw diagnostics can include WoW escape-pipe tokens (|...) that can make
    -- EditBox rendering reject the payload. Escape pipes for copy view fallback.
    if requestedLen > 0 and actualLen == 0 then
        local escaped = payload:gsub("|", "||")
        mode = "escaped_pipes"
        pcall(frame.copyAllBox.SetText, frame.copyAllBox, escaped)
        actualLen = #(frame.copyAllBox:GetText() or "")
        requestedLen = #escaped
        okSet = actualLen > 0
    end

    local success = okSet and requestedLen == actualLen and (requestedLen == 0 or actualLen > 0)
    if success then
        if frame.copyAllScroll and frame.copyAllScroll.SetVerticalScroll then
            frame.copyAllScroll:SetVerticalScroll(0)
        end
        frame.copyAllBox:SetFocus()
        frame.copyAllBox:HighlightText()
    else
        SetInspectorCopyMode(false)
    end
    return success, requestedLen, actualLen, okSet, mode
end

local function ClearCopyAllState(reason)
    if not frame then return end
    local wasActive = frame._muiCopyAllActive == true
    SetInspectorCopyMode(false)
    if frame.copyAllBox then
        frame.copyAllBox:SetText("")
    end
    if wasActive then
        TraceCopyAll(string.format(
            "clear_state reason=%s wasActive=%s",
            NormalizeInlineText(reason or "unspecified", 80),
            tostring(wasActive)
        ))
    end
end

local function ClearAllIssuesOnly()
    ClearCopyAllState("clear_issues")
    if M.db and M.db.errors then
        M.db.errors = {}
        M.index = {}
        selectedIndex = 1
        M.Refresh()
        if _G.UpdateTabLayout then _G.UpdateTabLayout() end
    end
end

local function ClearSessionsAndHistory()
    if not (IsShiftKeyDown and IsShiftKeyDown()) then return false end
    if not M.db then return false end
    ClearCopyAllState("clear_sessions")
    M.db.errors = {}
    M.index = {}
    M.db.context = {}
    M.db.session = 0
    selectedIndex = 1
    EnsureDB()
    M.Refresh()
    if _G.UpdateTabLayout then _G.UpdateTabLayout() end
    return true
end

local function ClearSelectedIssue()
    if not M.db or not M.db.errors then return end
    BuildFiltered()
    if #filtered == 0 then return end
    if selectedIndex < 1 or selectedIndex > #filtered then selectedIndex = 1 end
    local picked = filtered[selectedIndex]
    if not picked then return end

    local removed = 0
    if picked.key and M.view and (M.view.groupBySig or M.view.bucketView) then
        for i = #M.db.errors, 1, -1 do
            local e = M.db.errors[i]
            if e then
                local key = (e.kind or "?") .. "::" .. (e.sig or "")
                if key == picked.key then
                    table.remove(M.db.errors, i)
                    removed = removed + 1
                end
            end
        end
    else
        for i = #M.db.errors, 1, -1 do
            if M.db.errors[i] == picked then
                table.remove(M.db.errors, i)
                removed = 1
                break
            end
        end
    end

    if removed > 0 then
        ClearCopyAllState("clear_selected")
        -- Remove only the specific key from the dedup index, then rebuild
        -- from remaining entries so future identical errors still dedup.
        if picked.key then
            M.index[picked.key] = nil
        end
        -- Rebuild index from remaining entries
        for _, e in ipairs(M.db.errors) do
            if e and e.key then
                M.index[e.key] = e
            end
        end
        if selectedIndex > 1 then selectedIndex = selectedIndex - 1 end
        M.Refresh()
        if _G.UpdateTabLayout then _G.UpdateTabLayout() end
    end
end


local function FormatEntryShort(e)
    local msg = e.message or ""
    msg = msg:gsub("\n", " ")
    if #msg > 80 then msg = msg:sub(1, 77) .. "..." end
    local kind = KindLabel(e.kind or "?", e)
    local addon = e.addon or "NoAddon"
    if #addon > 12 then addon = addon:sub(1, 11) .. "..." end
    local count = e.count or 1
    local stamp = e.lastSeen and date("%H:%M:%S", e.lastSeen) or "--:--:--"
    return kind, addon, msg, count, stamp
end

local function BuildEntryText(entry)
    local lines = {}
    lines[#lines + 1] = string.format("Type: %s", SafeToString(KindLabel(entry.kind, entry)))
    lines[#lines + 1] = string.format("Count: %s", SafeToString(entry.count))
    lines[#lines + 1] = string.format("Session: %s", SafeToString(entry.session))
    if entry.sessionCount and entry.sessionCount > 0 then
        lines[#lines + 1] = string.format("Sessions: %s", SafeToString(entry.sessionCount))
    end
    if entry.sig and entry.sig ~= "" then lines[#lines + 1] = "Signature: " .. SafeToString(entry.sig) end
    if entry.addon then
        local addonLine = SafeToString(entry.addon)
        if entry.addonVersion and entry.addonVersion ~= "" then
            addonLine = addonLine .. " v" .. SafeToString(entry.addonVersion)
        end
        lines[#lines + 1] = "Addon: " .. addonLine
    end
    lines[#lines + 1] = string.format("First: %s", SafeToString(entry.firstSeen and date("%H:%M:%S", entry.firstSeen) or ""))
    lines[#lines + 1] = string.format("Last: %s", SafeToString(entry.lastSeen and date("%H:%M:%S", entry.lastSeen) or ""))
    if entry.meta and entry.meta ~= "" then lines[#lines + 1] = "Meta: " .. SafeToString(entry.meta) end

    -- Per-error context (what was happening when the error fired)
    local ec = entry.errorContext
    if ec then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "At Error:"
        if ec.combat ~= nil then lines[#lines + 1] = "  In Combat: " .. (ec.combat and "Yes" or "No") end
        if ec.zone and ec.zone ~= "" then
            local zoneLine = SafeToString(ec.zone)
            if ec.subzone and ec.subzone ~= "" and ec.subzone ~= ec.zone then
                zoneLine = zoneLine .. " - " .. SafeToString(ec.subzone)
            end
            lines[#lines + 1] = "  Zone: " .. zoneLine
        end
        if ec.inInstance ~= nil then
            lines[#lines + 1] = "  In Instance: " .. (ec.inInstance and ("Yes (" .. SafeToString(ec.instanceType or "unknown") .. ")") or "No")
        end
        if ec.groupSize and ec.groupSize > 0 then
            lines[#lines + 1] = "  Group Size: " .. tostring(ec.groupSize)
        end
    end

    -- Session context (fallback if no per-error context)
    if not ec and M.db and M.db.context and entry.contextId and M.db.context[entry.contextId] then
        local ctx = M.db.context[entry.contextId]
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Session Context:"
        if ctx.client then lines[#lines + 1] = "  Client: " .. SafeToString(ctx.client) end
        if ctx.class then lines[#lines + 1] = "  Class: " .. SafeToString(ctx.class) end
        if ctx.spec then lines[#lines + 1] = "  Spec: " .. SafeToString(ctx.spec) end
        if ctx.zone then lines[#lines + 1] = "  Zone: " .. SafeToString(ctx.zone) end
        if ctx.inInstance ~= nil then lines[#lines + 1] = "  In Instance: " .. SafeToString(ctx.inInstance) end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = "Message:"
    lines[#lines + 1] = SafeToString(entry.message)
    if entry.stack and entry.stack ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Stack:"
        lines[#lines + 1] = SafeToString(entry.stack)
    end
    if entry.locals and entry.locals ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Locals:"
        lines[#lines + 1] = SafeToString(entry.locals)
    end
    -- Escape pipe characters so EditBox always renders the text.
    -- Raw pipe sequences (|cff..., |r, |H etc.) can cause the EditBox
    -- to silently reject the entire payload.
    local result = table.concat(lines, "\n")
    return result:gsub("|", "||")
end

local function CompactValue(value)
    local text = SafeToString(value)
    text = text:gsub("\\", "\\\\")
    text = text:gsub("\r", "\\r")
    text = text:gsub("\n", "\\n")
    return text
end

local function AddCompactKV(out, key, value, allowEmpty)
    if value == nil then return end
    local val = CompactValue(value)
    if (not allowEmpty) and val == "" then return end
    out[#out + 1] = key .. "=" .. val
end

local function SortContextIds(ids)
    table.sort(ids, function(a, b)
        if type(a) == "number" and type(b) == "number" then
            return a < b
        end
        return tostring(a) < tostring(b)
    end)
end

local function CompactOr(value, fallback)
    if value == nil then return fallback or "?" end
    local v = CompactValue(value)
    if v == "" then return fallback or "?" end
    return v
end

local function ExtractKVToken(message, key)
    if type(message) ~= "string" or message == "" then return nil end
    if type(key) ~= "string" or key == "" then return nil end
    local pattern = key .. "=([^%s]+)"
    local value = string.match(message, pattern)
    if value and value ~= "" then
        return value
    end
    return nil
end

local function ParseIntToken(value)
    if type(value) ~= "string" then return nil end
    local n = tonumber(value)
    if not n then return nil end
    return math.floor(n)
end

local function ParseBoolToken(value)
    if value == "true" then return true end
    if value == "false" then return false end
    return nil
end

local function ParseBNKeyIdentity(key)
    if type(key) ~= "string" or key == "" then
        return "unknown", nil
    end
    local id = key:match("^bn:(%d+)$")
    if id then
        return "bn-id", tonumber(id)
    end
    local token = key:match("^bn_token:(j%d+)$")
    if token then
        return "bn-token", token
    end
    return "other", key
end

local function IsBNPlaceholderName(value)
    return type(value) == "string" and value:match("^|Kj%d+|k$") ~= nil
end

local function SafeEventToken(value)
    local t = tostring(value or "unknown")
    t = t:gsub("[^%w]+", "_")
    t = t:gsub("_+", "_")
    t = t:gsub("^_", "")
    t = t:gsub("_$", "")
    if t == "" then return "unknown" end
    return string.lower(t)
end

local function BoolFlag(v)
    if v == true then return "1" end
    if v == false then return "0" end
    return "?"
end

local function AddAIKVLine(lines, prefix, pairs)
    if type(lines) ~= "table" or type(pairs) ~= "table" then return end
    local out = {}
    for i = 1, #pairs do
        local item = pairs[i]
        local key = item and item[1]
        local value = item and item[2]
        if key and value ~= nil then
            local v = CompactValue(value)
            if v ~= "" then
                out[#out + 1] = tostring(key) .. "=" .. v
            end
        end
    end
    if #out > 0 then
        lines[#lines + 1] = "  " .. tostring(prefix or "ai:") .. " " .. table.concat(out, " ")
    end
end

local function BuildEntryAIExplanation(entry)
    local lines = {}
    local addon = entry and tostring(entry.addon or "") or ""
    local msg = entry and tostring(entry.message or "") or ""
    local kind = entry and tostring(entry.kind or "") or ""

    if addon == "DirectDM" then
        if string.find(msg, "BuildFromLegacy bn-token", 1, true) then
            local key = ExtractKVToken(msg, "key") or "bn_token:?"
            local token = ExtractKVToken(msg, "token") or "?"
            AddAIKVLine(lines, "ai:", {
                { "event", "directdm_build_legacy_token" },
                { "src", "DirectDM" },
                { "class", "identity_migration" },
            })
            AddAIKVLine(lines, "ai.data:", {
                { "key", key },
                { "token", token },
                { "keyType", "bn-token" },
            })
            AddAIKVLine(lines, "ai.action:", {
                { "code", "migrate_alias_to_bnid" },
                { "canonicalKey", "bn:<id>" },
            })
        elseif string.find(msg, "BuildFromLegacy bn-id", 1, true) then
            local key = ExtractKVToken(msg, "key") or "bn:?"
            local bnetID = ExtractKVToken(msg, "bnetID") or "?"
            local keyType, keyIdentity = ParseBNKeyIdentity(key)
            local bnetIDNum = ParseIntToken(bnetID)
            local keyMatches = (keyType == "bn-id" and type(keyIdentity) == "number" and bnetIDNum and keyIdentity == bnetIDNum) or false
            local keyMismatch = (keyType == "bn-id" and type(keyIdentity) == "number" and bnetIDNum and keyIdentity ~= bnetIDNum) or false
            local action = keyMismatch and "repair_key_bnetid_mismatch" or "keep_canonical_bnid"
            AddAIKVLine(lines, "ai:", {
                { "event", "directdm_build_legacy_bnid" },
                { "src", "DirectDM" },
                { "class", "identity_restore" },
            })
            AddAIKVLine(lines, "ai.data:", {
                { "key", key },
                { "keyType", keyType },
                { "keyIdentity", keyIdentity },
                { "bnetID", bnetID },
            })
            AddAIKVLine(lines, "ai.flags:", {
                { "keyMatch", BoolFlag(keyMatches) },
                { "keyMismatch", BoolFlag(keyMismatch) },
            })
            AddAIKVLine(lines, "ai.action:", {
                { "code", action },
            })
        elseif string.find(msg, "RegisterContact insert", 1, true) then
            local key = ExtractKVToken(msg, "key") or "?"
            local bnetID = ExtractKVToken(msg, "bnetID") or "?"
            local hadMeta = ExtractKVToken(msg, "hadMeta") or "?"
            local display = ExtractKVToken(msg, "display")
            local tell = ExtractKVToken(msg, "tell")
            local keyType, keyIdentity = ParseBNKeyIdentity(key)
            local bnetIDNum = ParseIntToken(bnetID)
            local aliasKey = (keyType == "bn-token")
            local keyMismatch = (keyType == "bn-id" and type(keyIdentity) == "number" and bnetIDNum and keyIdentity ~= bnetIDNum) or false
            local keyMatches = (keyType == "bn-id" and type(keyIdentity) == "number" and bnetIDNum and keyIdentity == bnetIDNum) or false
            local placeholderDisplay = IsBNPlaceholderName(display)
            local placeholderTell = IsBNPlaceholderName(tell)
            local tellNil = (tell == nil or tell == "nil")
            local action = "verify_contact_map_stability"
            if aliasKey then
                action = "migrate_alias_to_bnid"
            elseif keyMismatch then
                action = "repair_key_bnetid_mismatch"
            elseif placeholderDisplay or placeholderTell then
                action = "defer_label_until_presence"
            end

            AddAIKVLine(lines, "ai:", {
                { "event", "directdm_register_contact" },
                { "src", "DirectDM" },
                { "class", "contact_upsert" },
            })
            AddAIKVLine(lines, "ai.data:", {
                { "key", key },
                { "keyType", keyType },
                { "keyIdentity", keyIdentity },
                { "bnetID", bnetID },
                { "hadMeta", hadMeta },
                { "display", display or "nil" },
                { "tell", tell or "nil" },
            })
            AddAIKVLine(lines, "ai.flags:", {
                { "aliasKey", BoolFlag(aliasKey) },
                { "keyMatch", BoolFlag(keyMatches) },
                { "keyMismatch", BoolFlag(keyMismatch) },
                { "placeholderDisplay", BoolFlag(placeholderDisplay) },
                { "placeholderTell", BoolFlag(placeholderTell) },
                { "tellNil", BoolFlag(tellNil) },
            })
            AddAIKVLine(lines, "ai.action:", {
                { "code", action },
            })
        elseif string.find(msg, "InitDB start", 1, true) then
            AddAIKVLine(lines, "ai:", {
                { "event", "directdm_initdb_start" },
                { "src", "DirectDM" },
                { "class", "init" },
            })
            AddAIKVLine(lines, "ai.action:", {
                { "code", "correlate_following_events" },
            })
        end
    elseif addon == "Diagnostics/CopyAll" and string.find(msg, "copy_all_click", 1, true) then
        local setOk = ExtractKVToken(msg, "setOk") or "?"
        local mode = ExtractKVToken(msg, "mode") or "?"
        local requested = ExtractKVToken(msg, "requested") or "?"
        local actual = ExtractKVToken(msg, "actual") or "?"
        local okSet = ExtractKVToken(msg, "okSet") or "?"
        local copyAllActive = ExtractKVToken(msg, "copyAllActive") or "?"
        local setOkBool = ParseBoolToken(setOk)
        local requestedNum = ParseIntToken(requested)
        local actualNum = ParseIntToken(actual)
        local emptyWrite = actualNum and actualNum <= 0
        local truncated = requestedNum and actualNum and actualNum < requestedNum or false
        local status = "ok"
        local action = "use_export"
        if setOkBool == false or emptyWrite then
            status = "set_fail"
            action = "retry_copyall_after_sanitize"
        elseif truncated then
            status = "partial"
            action = "treat_as_partial_export"
        end

        AddAIKVLine(lines, "ai:", {
            { "event", "diagnostics_copyall_click" },
            { "src", "Diagnostics/CopyAll" },
            { "class", "export_write" },
        })
        AddAIKVLine(lines, "ai.data:", {
            { "setOk", setOk },
            { "okSet", okSet },
            { "mode", mode },
            { "requested", requested },
            { "actual", actual },
            { "copyAllActive", copyAllActive },
        })
        AddAIKVLine(lines, "ai.flags:", {
            { "emptyWrite", BoolFlag(emptyWrite) },
            { "truncated", BoolFlag(truncated) },
            { "status", status },
        })
        AddAIKVLine(lines, "ai.action:", {
            { "code", action },
        })
    elseif addon == "Diagnostics/CopyAll" and string.find(msg, "clear_state", 1, true) then
        AddAIKVLine(lines, "ai:", {
            { "event", "diagnostics_copyall_clear_state" },
            { "src", "Diagnostics/CopyAll" },
            { "class", "state_reset" },
        })
        AddAIKVLine(lines, "ai.action:", {
            { "code", "evaluate_nearest_copyall_click" },
        })
    end

    if #lines == 0 then
        AddAIKVLine(lines, "ai:", {
            { "event", SafeEventToken(addon) .. "_entry" },
            { "src", addon ~= "" and addon or "unknown" },
            { "class", "generic" },
        })
        AddAIKVLine(lines, "ai.action:", {
            { "code", "use_group_context" },
        })
    end

    if kind ~= "" and kind ~= "Debug" then
        AddAIKVLine(lines, "ai.kind:", {
            { "value", kind },
        })
    end

    return lines
end

local function BuildContextReadableLines(ctxId, ctx)
    local lines = {}
    local res = "?"
    if ctx and ctx.screenW and ctx.screenH then
        res = tostring(ctx.screenW) .. "x" .. tostring(ctx.screenH)
    end

    lines[#lines + 1] = string.format(
        "[CTX %s] player=%s realm=%s class=%s race=%s level=%s spec=%s",
        CompactOr(ctxId, "?"),
        CompactOr(ctx and ctx.player, "?"),
        CompactOr(ctx and ctx.realm, "?"),
        CompactOr(ctx and ctx.class, "?"),
        CompactOr(ctx and ctx.race, "?"),
        CompactOr(ctx and ctx.level, "?"),
        CompactOr(ctx and ctx.spec, "n/a")
    )
    lines[#lines + 1] = string.format(
        "  location: zone=%s subzone=%s inCombat=%s inInstance=%s instanceType=%s combatLockdown=%s",
        CompactOr(ctx and ctx.zone, "?"),
        CompactOr(ctx and ctx.subzone, "n/a"),
        CompactOr(ctx and ctx.inCombat, "?"),
        CompactOr(ctx and ctx.inInstance, "?"),
        CompactOr(ctx and ctx.instanceType, "n/a"),
        CompactOr(ctx and ctx.combatLockdown, "?")
    )
    lines[#lines + 1] = string.format(
        "  client: client=%s build=%s buildDate=%s toc=%s locale=%s uiScale=%s resolution=%s",
        CompactOr(ctx and ctx.client, "?"),
        CompactOr(ctx and ctx.build, "?"),
        CompactOr(ctx and ctx.buildDate, "?"),
        CompactOr(ctx and ctx.toc, "?"),
        CompactOr(ctx and ctx.locale, "?"),
        CompactOr(ctx and ctx.uiScale, "?"),
        CompactOr(res, "?")
    )
    return lines
end

local function BuildEntryReadableLines(index, entry)
    local lines = {}
    lines[#lines + 1] = string.format(
        "#%d [%s] addon=%s count=%s session=%s ctx=%s first=%s last=%s",
        index or 0,
        CompactOr(KindLabel(entry and entry.kind, entry), "?"),
        CompactOr(entry and entry.addon, "?"),
        CompactOr(entry and entry.count, "1"),
        CompactOr(entry and entry.session, "?"),
        CompactOr(entry and entry.contextId, "?"),
        CompactOr(entry and entry.firstSeen and date("%H:%M:%S", entry.firstSeen) or "", "n/a"),
        CompactOr(entry and entry.lastSeen and date("%H:%M:%S", entry.lastSeen) or "", "n/a")
    )
    if entry and entry.sig and entry.sig ~= "" then
        lines[#lines + 1] = "  sig: " .. CompactValue(entry.sig)
    end
    if entry and entry.meta and entry.meta ~= "" then
        lines[#lines + 1] = "  meta: " .. CompactValue(entry.meta)
    end
    lines[#lines + 1] = "  msg: " .. CompactValue(entry and entry.message or "")
    if entry and entry.stack and entry.stack ~= "" then
        lines[#lines + 1] = "  stk: " .. CompactValue(entry.stack)
    end
    local ai = BuildEntryAIExplanation(entry)
    for i = 1, #ai do
        lines[#lines + 1] = ai[i]
    end
    return lines
end

local function ShortenForInline(value, maxLen)
    local text = CompactValue(value or "")
    local lim = tonumber(maxLen) or 160
    if lim < 20 then lim = 20 end
    if #text > lim then
        return text:sub(1, lim - 3) .. "..."
    end
    return text
end

local function NormalizeGroupTemplate(message)
    local t = CompactValue(message or "")
    t = t:gsub("bn_token:j%d+", "bn_token:jN")
    t = t:gsub("bn:%d+", "bn:N")
    t = t:gsub("|Kj%d+|k", "|KjN|k")
    t = t:gsub("bnetID=%d+", "bnetID=N")
    t = t:gsub("key=bn_token:j%d+", "key=bn_token:jN")
    t = t:gsub("key=bn:%d+", "key=bn:N")
    t = t:gsub("count=%d+", "count=N")
    t = t:gsub("session=%d+", "session=N")
    t = t:gsub("selected=%d+", "selected=N")
    t = t:gsub("dbTotal=%d+", "dbTotal=N")
    t = t:gsub("filtered=%d+", "filtered=N")
    t = t:gsub("filteredDebug=%d+", "filteredDebug=N")
    t = t:gsub("totalChars=%d+", "totalChars=N")
    t = t:gsub("requested=%d+", "requested=N")
    t = t:gsub("actual=%d+", "actual=N")
    return ShortenForInline(t, 180)
end

local COPYALL_MAX_GROUPS = 18
local COPYALL_MAX_GROUP_FIELDS = 8
local COPYALL_MAX_GROUP_SAMPLES = 2
local COPYALL_MAX_ENTRY_CAPSULES = 140
local COPYALL_MAX_USER_TIMELINE = 90
local COPYALL_MAX_LLM_VARIANTS = 3

local function SetKeysToSortedList(setTable)
    local out = {}
    if type(setTable) ~= "table" then return out end
    for key in pairs(setTable) do
        out[#out + 1] = key
    end
    table.sort(out, function(a, b)
        if type(a) == "number" and type(b) == "number" then
            return a < b
        end
        return tostring(a) < tostring(b)
    end)
    return out
end

local function JoinLimitedList(values, maxItems)
    local list = values or {}
    local total = #list
    if total == 0 then return "-" end
    local limit = tonumber(maxItems) or total
    if limit < 1 then limit = 1 end
    if limit > total then limit = total end
    local out = {}
    for i = 1, limit do
        out[#out + 1] = tostring(list[i])
    end
    local text = table.concat(out, ",")
    if limit < total then
        text = text .. ",...+" .. tostring(total - limit)
    end
    return text
end

local function PipeToken(value, maxLen)
    local text = ShortenForInline(value or "", maxLen or 120)
    text = text:gsub("|", "<pipe>")
    text = text:gsub(";", ",")
    text = text:gsub("[%c]+", " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return "-" end
    return text
end

local function TrackLimitedUnique(setTable, list, value, maxItems)
    if type(setTable) ~= "table" or type(list) ~= "table" then return false end
    if value == nil then return false end
    local text = tostring(value)
    if text == "" then return false end
    if setTable[text] then return false end
    setTable[text] = true
    local limit = tonumber(maxItems) or 3
    if #list < limit then
        list[#list + 1] = text
    end
    return true
end

local function ParseMessageKV(message, maxPairs)
    local out = {}
    if type(message) ~= "string" or message == "" then return out end
    local text = message
    local len = #text
    local i = 1
    local limit = tonumber(maxPairs) or 24
    while i <= len and #out < limit do
        local keyStart, keyEnd, key = string.find(text, "([%a_][%w_:%./%-]*)=", i)
        if not keyStart then break end

        local prev = " "
        if keyStart > 1 then
            prev = string.sub(text, keyStart - 1, keyStart - 1)
        end
        if string.match(prev, "[%w_]") then
            i = keyEnd + 1
        else
            local valueStart = keyEnd + 1
            local valueEnd = len
            local value = ""
            local first = string.sub(text, valueStart, valueStart)
            if first == "\"" or first == "'" then
                local quote = first
                local j = valueStart + 1
                while j <= len do
                    local ch = string.sub(text, j, j)
                    if ch == quote and string.sub(text, j - 1, j - 1) ~= "\\" then
                        break
                    end
                    j = j + 1
                end
                if j <= len then
                    value = string.sub(text, valueStart + 1, j - 1)
                    valueEnd = j
                else
                    value = string.sub(text, valueStart + 1)
                    valueEnd = len
                end
            else
                local spacePos = string.find(text, "%s", valueStart)
                if spacePos then
                    value = string.sub(text, valueStart, spacePos - 1)
                    valueEnd = spacePos - 1
                else
                    value = string.sub(text, valueStart)
                    valueEnd = len
                end
            end
            value = value:gsub("^%s+", ""):gsub("%s+$", "")
            if value ~= "" then
                out[#out + 1] = { key = key, value = value }
            end
            i = valueEnd + 1
        end
    end
    return out
end

local function ExtractMessageStem(message)
    local text = type(message) == "string" and message or ""
    if text == "" then return "" end
    local firstKV = string.find(text, "%s[%a_][%w_:%./%-]*=", 1)
    local stem = text
    if firstKV and firstKV > 1 then
        stem = string.sub(text, 1, firstKV - 1)
    end
    stem = stem:gsub("%s+$", "")
    return ShortenForInline(stem, 90)
end

local function BuildFieldValuePreview(field, maxValues)
    if type(field) ~= "table" or type(field.valueList) ~= "table" then
        return "?"
    end
    local limit = tonumber(maxValues) or 3
    if limit < 1 then limit = 1 end
    local n = #field.valueList
    if n > limit then n = limit end
    local values = {}
    for i = 1, n do
        values[#values + 1] = field.valueList[i]
    end
    local extra = (field.unique or #field.valueList) - n
    if extra > 0 then
        values[#values + 1] = "...+" .. tostring(extra)
    end
    if #values == 0 then return "?" end
    return table.concat(values, "/")
end

local function BuildGroupFieldBuckets(group, maxFields)
    local stable = {}
    local varying = {}
    if type(group) ~= "table" or type(group.fieldOrder) ~= "table" then
        return stable, varying
    end
    local fieldLimit = tonumber(maxFields) or 8
    if fieldLimit < 1 then fieldLimit = 1 end
    local used = 0
    for i = 1, #group.fieldOrder do
        if used >= fieldLimit then break end
        local key = group.fieldOrder[i]
        local field = group.fields and group.fields[key]
        if field and (field.unique or 0) > 0 then
            if field.unique == 1 then
                stable[#stable + 1] = key .. "=" .. tostring(field.valueList and field.valueList[1] or "?")
            else
                varying[#varying + 1] = key .. "={" .. BuildFieldValuePreview(field, 3) .. "}"
            end
            used = used + 1
        end
    end
    return stable, varying
end

local function BuildEntryKVInline(entry, maxPairs)
    local kv = ParseMessageKV(entry and entry.message or "", maxPairs or 6)
    if #kv == 0 then return "-" end
    local out = {}
    for i = 1, #kv do
        out[#out + 1] = kv[i].key .. ":" .. PipeToken(kv[i].value, 40)
    end
    return table.concat(out, ",")
end

local function BuildKVSignature(kv, maxPairs)
    if type(kv) ~= "table" or #kv == 0 then
        return "-"
    end
    local list = {}
    for i = 1, #kv do
        local pair = kv[i]
        local key = pair and pair.key
        local value = pair and pair.value
        if key and value then
            list[#list + 1] = {
                key = tostring(key),
                value = PipeToken(value, 40),
            }
        end
    end
    if #list == 0 then
        return "-"
    end
    table.sort(list, function(a, b)
        return a.key < b.key
    end)
    local limit = tonumber(maxPairs) or 6
    if limit < 1 then limit = 1 end
    if limit > #list then limit = #list end
    local out = {}
    for i = 1, limit do
        local item = list[i]
        out[#out + 1] = item.key .. ":" .. item.value
    end
    if limit < #list then
        out[#out + 1] = "...+" .. tostring(#list - limit)
    end
    return table.concat(out, ",")
end

local function BuildEntryAICapsule(entry, group)
    local addon = entry and entry.addon or "unknown"
    local kind = entry and entry.kind or "Debug"
    local message = entry and entry.message or ""
    local stem = (group and group.stemList and group.stemList[1]) or ExtractMessageStem(message)
    local eventSeed = stem ~= "" and stem or message
    if eventSeed == "" then
        eventSeed = addon .. "_entry"
    end
    local event = SafeEventToken(addon .. "_" .. eventSeed)
    local class = (kind == "Debug") and "debug_entry" or "issue_entry"
    local action = "use_group_context"
    local lowerMsg = string.lower(message)

    if kind ~= "Debug" then
        action = "triage_issue"
    elseif string.find(message, "copy_all_click", 1, true) then
        action = "validate_export_write"
    elseif string.find(message, "BuildFromLegacy", 1, true) then
        action = "inspect_identity_migration"
    elseif string.find(message, "RegisterContact insert", 1, true) then
        action = "inspect_contact_upsert"
    elseif string.find(lowerMsg, "error", 1, true) or string.find(lowerMsg, "failed", 1, true) then
        action = "inspect_failure_path"
    end

    local kv = ParseMessageKV(message, 8)
    local keyList = {}
    local keySeen = {}
    for i = 1, #kv do
        local key = kv[i].key
        if key and not keySeen[key] then
            keySeen[key] = true
            keyList[#keyList + 1] = key
        end
    end

    local aiKeys = JoinLimitedList(keyList, 6)
    return event, class, action, aiKeys
end

local function BuildEntryGroups(list)
    local groupsByKey = {}
    local groups = {}
    local entryGroups = {}
    local entries = list or {}
    for i = 1, #entries do
        local e = entries[i]
        local kind = e and e.kind or "?"
        local addon = e and e.addon or "NoAddon"
        local template = (e and e.sig and e.sig ~= "") and CompactValue(e.sig) or NormalizeGroupTemplate(e and e.message or "")
        local key = tostring(kind) .. "\031" .. tostring(addon) .. "\031" .. tostring(template)
        local g = groupsByKey[key]
        if not g then
            g = {
                kind = kind,
                addon = addon,
                template = template,
                events = 0,
                entries = 0,
                firstSeen = e and e.firstSeen or nil,
                lastSeen = e and e.lastSeen or nil,
                sessions = {},
                contexts = {},
                ids = {},
                samples = {},
                stems = {},
                stemList = {},
                metaValues = {},
                metaList = {},
                fields = {},
                fieldOrder = {},
                variantsByKey = {},
                variants = {},
            }
            groupsByKey[key] = g
            groups[#groups + 1] = g
        end
        entryGroups[i] = g

        local count = tonumber(e and e.count) or 1
        g.events = g.events + count
        g.entries = g.entries + 1
        if e and e.firstSeen and (not g.firstSeen or e.firstSeen < g.firstSeen) then g.firstSeen = e.firstSeen end
        if e and e.lastSeen and (not g.lastSeen or e.lastSeen > g.lastSeen) then g.lastSeen = e.lastSeen end
        if e and e.session ~= nil then g.sessions[e.session] = true end
        if e and e.contextId ~= nil then g.contexts[e.contextId] = true end
        if #g.ids < 16 then g.ids[#g.ids + 1] = i end

        local rawSample = ShortenForInline(e and e.message or "", 200)
        local sample = ""
        if rawSample ~= "" then
            sample = PipeToken(rawSample, 200)
        end
        if sample ~= "" then
            local exists = false
            for s = 1, #g.samples do
                if g.samples[s] == sample then
                    exists = true
                    break
                end
            end
            if not exists and #g.samples < COPYALL_MAX_GROUP_SAMPLES then
                g.samples[#g.samples + 1] = sample
            end
        end

        local stem = ExtractMessageStem(e and e.message or "")
        if stem ~= "" then
            TrackLimitedUnique(g.stems, g.stemList, PipeToken(stem, 120), 3)
        end

        if e and e.meta and e.meta ~= "" then
            TrackLimitedUnique(g.metaValues, g.metaList, PipeToken(e.meta, 140), 3)
        end

        local kv = ParseMessageKV(e and e.message or "", 18)
        for p = 1, #kv do
            local keyName = kv[p].key
            local value = PipeToken(kv[p].value, 48)
            local field = g.fields[keyName]
            if not field then
                field = {
                    count = 0,
                    unique = 0,
                    values = {},
                    valueList = {},
                }
                g.fields[keyName] = field
                g.fieldOrder[#g.fieldOrder + 1] = keyName
            end
            field.count = field.count + 1
            if not field.values[value] then
                field.values[value] = true
                field.unique = field.unique + 1
                if #field.valueList < 5 then
                    field.valueList[#field.valueList + 1] = value
                end
            end
        end

        local variantStem = stem ~= "" and PipeToken(stem, 120) or "-"
        local variantKV = BuildKVSignature(kv, 6)
        local variantKey = variantStem .. "\031" .. variantKV
        local variant = g.variantsByKey[variantKey]
        if not variant then
            local aiEvent, aiClass, aiAction, aiKeys = BuildEntryAICapsule(e, g)
            variant = {
                stem = variantStem,
                kv = variantKV,
                events = 0,
                entries = 0,
                firstSeen = e and e.firstSeen or nil,
                lastSeen = e and e.lastSeen or nil,
                sessions = {},
                contexts = {},
                samples = {},
                aiEvent = aiEvent,
                aiClass = aiClass,
                aiAction = aiAction,
                aiKeys = aiKeys,
            }
            g.variantsByKey[variantKey] = variant
            g.variants[#g.variants + 1] = variant
        end
        variant.events = (variant.events or 0) + count
        variant.entries = (variant.entries or 0) + 1
        if e and e.firstSeen and (not variant.firstSeen or e.firstSeen < variant.firstSeen) then
            variant.firstSeen = e.firstSeen
        end
        if e and e.lastSeen and (not variant.lastSeen or e.lastSeen > variant.lastSeen) then
            variant.lastSeen = e.lastSeen
        end
        if e and e.session ~= nil then
            variant.sessions[e.session] = true
        end
        if e and e.contextId ~= nil then
            variant.contexts[e.contextId] = true
        end
        if sample ~= "" and #variant.samples < 1 then
            variant.samples[#variant.samples + 1] = sample
        end
    end

    table.sort(groups, function(a, b)
        if a.events ~= b.events then return a.events > b.events end
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)
    for i = 1, #groups do
        local g = groups[i]
        g._id = i
        if g.variants then
            table.sort(g.variants, function(a, b)
                if (a.events or 0) ~= (b.events or 0) then
                    return (a.events or 0) > (b.events or 0)
                end
                return (a.lastSeen or 0) > (b.lastSeen or 0)
            end)
        end
    end
    return groups, entryGroups
end

local function BuildAIHints(list, groups, counts)
    local findings = {}
    local actions = {}
    local entries = list or {}
    local cLegacyBN = 0
    local cRegisterContact = 0
    local cAliasKey = 0
    local cKeyMismatch = 0
    local cPlaceholder = 0
    local cCopyAllSetFail = 0
    local cCopyAllPartial = 0
    local cCopyAllEscaped = 0

    for i = 1, #entries do
        local e = entries[i]
        local addon = (e and e.addon) or ""
        local msg = (e and e.message) or ""
        local n = tonumber(e and e.count) or 1

        if addon == "DirectDM" and string.find(msg, "BuildFromLegacy bn-token", 1, true) then
            cLegacyBN = cLegacyBN + n
        end

        if addon == "DirectDM" and string.find(msg, "RegisterContact insert", 1, true) then
            cRegisterContact = cRegisterContact + n
            local key = ExtractKVToken(msg, "key")
            local bnetID = ExtractKVToken(msg, "bnetID")
            local display = ExtractKVToken(msg, "display")
            local tell = ExtractKVToken(msg, "tell")
            local keyType, keyIdentity = ParseBNKeyIdentity(key)
            local bnetIDNum = ParseIntToken(bnetID)
            if keyType == "bn-token" then
                cAliasKey = cAliasKey + n
            end
            if keyType == "bn-id" and type(keyIdentity) == "number" and bnetIDNum and keyIdentity ~= bnetIDNum then
                cKeyMismatch = cKeyMismatch + n
            end
            if IsBNPlaceholderName(display) or IsBNPlaceholderName(tell) then
                cPlaceholder = cPlaceholder + n
            end
        end

        if addon == "Diagnostics/CopyAll" and string.find(msg, "copy_all_click", 1, true) then
            local setOk = ParseBoolToken(ExtractKVToken(msg, "setOk"))
            local mode = ExtractKVToken(msg, "mode")
            local requested = ParseIntToken(ExtractKVToken(msg, "requested"))
            local actual = ParseIntToken(ExtractKVToken(msg, "actual"))
            if setOk == false or (actual and actual <= 0) then
                cCopyAllSetFail = cCopyAllSetFail + n
            elseif requested and actual and actual < requested then
                cCopyAllPartial = cCopyAllPartial + n
            end
            if mode == "escaped_pipes" then
                cCopyAllEscaped = cCopyAllEscaped + n
            end
        end
    end

    if groups and groups[1] then
        findings[#findings + 1] = string.format(
            "topPattern kind=%s addon=%s events=%d template=%s",
            CompactOr(groups[1].kind, "?"),
            CompactOr(groups[1].addon, "?"),
            groups[1].events or 0,
            ShortenForInline(groups[1].template or "", 120)
        )
    end

    findings[#findings + 1] = string.format(
        "directdm legacyTokenEvents=%d registerEvents=%d aliasKeyEvents=%d keyMismatchEvents=%d placeholderEvents=%d",
        cLegacyBN, cRegisterContact, cAliasKey, cKeyMismatch, cPlaceholder
    )
    findings[#findings + 1] = string.format(
        "copyall setFailEvents=%d partialEvents=%d escapedPipeEvents=%d",
        cCopyAllSetFail, cCopyAllPartial, cCopyAllEscaped
    )
    findings[#findings + 1] = string.format(
        "kinds debug=%d warning=%d luaError=%d taint=%d uiError=%d",
        counts and (counts.Debug or 0) or 0,
        counts and (counts.Warning or 0) or 0,
        counts and (counts.LuaError or 0) or 0,
        counts and (counts.Taint or 0) or 0,
        counts and (counts.UIError or 0) or 0
    )

    if cLegacyBN > 0 or cAliasKey > 0 then
        actions[#actions + 1] = "directdm_identity canonicalKey=bn:<id> aliasKey=bn_token:* persistCanonicalOnly=1"
    end
    if cKeyMismatch > 0 then
        actions[#actions + 1] = "directdm_guard requireKeyEqBnetID=1 onMismatch=drop_write+repair_map"
    end
    if cPlaceholder > 0 then
        actions[#actions + 1] = "label_policy placeholderName=|KjN|k finalizeAfterPresence=1"
    end
    if cCopyAllSetFail > 0 or cCopyAllPartial > 0 then
        actions[#actions + 1] = "copyall_policy requireStatus=ok rejectStatus=set_fail,partial"
    end
    if #actions == 0 then
        actions[#actions + 1] = "analysis_scope useGroupedFindings=1 useEntryAI=1"
    end
    return findings, actions
end

local function BuildAddonKindSpread(kindCounts)
    local order = { "Debug", "Warning", "LuaError", "Taint", "UIError" }
    local out = {}
    for i = 1, #order do
        local kind = order[i]
        local n = kindCounts and kindCounts[kind]
        if n and n > 0 then
            out[#out + 1] = kind .. "=" .. tostring(n)
        end
    end
    if #out == 0 then return "none" end
    return table.concat(out, ",")
end

local function BuildAddonSummary(list)
    local map = {}
    local out = {}
    local entries = list or {}
    for i = 1, #entries do
        local e = entries[i]
        local addon = e and e.addon or "NoAddon"
        local bucket = map[addon]
        if not bucket then
            bucket = {
                addon = addon,
                events = 0,
                entries = 0,
                kinds = {},
                lastSeen = 0,
            }
            map[addon] = bucket
            out[#out + 1] = bucket
        end
        local count = tonumber(e and e.count) or 1
        bucket.events = bucket.events + count
        bucket.entries = bucket.entries + 1
        local kind = e and e.kind
        if kind and kind ~= "" then
            bucket.kinds[kind] = (bucket.kinds[kind] or 0) + count
        end
        if e and e.lastSeen and e.lastSeen > bucket.lastSeen then
            bucket.lastSeen = e.lastSeen
        end
    end
    table.sort(out, function(a, b)
        if a.events ~= b.events then return a.events > b.events end
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)
    return out
end

local function BuildCopyAllModel(entries, activeAddonFilter)
    local list = entries or {}
    local counts = {
        Debug = CountEntriesByKind(list, "Debug"),
        Warning = CountEntriesByKind(list, "Warning"),
        LuaError = CountEntriesByKind(list, "LuaError"),
        Taint = CountEntriesByKind(list, "Taint"),
        UIError = CountEntriesByKind(list, "UIError"),
    }
    local groups, entryGroups = BuildEntryGroups(list)
    local exportCtx = BuildContext()

    local ctxTable = (M.db and M.db.context) or nil
    local ctxSeen = {}
    local ctxIds = {}
    if ctxTable then
        for i = 1, #list do
            local e = list[i]
            local ctxId = e and e.contextId
            if ctxId ~= nil and ctxTable[ctxId] and not ctxSeen[ctxId] then
                ctxSeen[ctxId] = true
                ctxIds[#ctxIds + 1] = ctxId
            end
        end
    end
    SortContextIds(ctxIds)

    return {
        list = list,
        filter = activeAddonFilter or "All Addons",
        counts = counts,
        groups = groups,
        entryGroups = entryGroups,
        exportCtx = exportCtx,
        ctxIds = ctxIds,
        ctxTable = ctxTable,
        addons = BuildAddonSummary(list),
    }
end

local function BuildUserFriendlyCopyAllText(model)
    local parts = {}
    local counts = model and model.counts or {}
    local list = model and model.list or {}
    local addons = model and model.addons or {}
    local exportCtx = model and model.exportCtx or {}

    -- Header
    parts[#parts + 1] = "========================================"
    parts[#parts + 1] = "   MidnightUI Diagnostics Report"
    parts[#parts + 1] = "========================================"
    parts[#parts + 1] = "Exported: " .. date("%B %d, %Y at %I:%M %p")

    local playerLine = SafeToString(exportCtx.player or "Unknown")
    if exportCtx.spec then playerLine = playerLine .. " - " .. SafeToString(exportCtx.spec) end
    if exportCtx.class then playerLine = playerLine .. " " .. SafeToString(exportCtx.class) end
    if exportCtx.level then playerLine = playerLine .. " (" .. SafeToString(exportCtx.level) .. ")" end
    parts[#parts + 1] = "Player:   " .. playerLine
    parts[#parts + 1] = "Realm:    " .. SafeToString(exportCtx.realm or "Unknown")
    parts[#parts + 1] = string.format("Client:   %s (Build %s)",
        SafeToString(exportCtx.client or "?"), SafeToString(exportCtx.build or "?"))

    local sessionCtx = M.db and M.db.context and M.db.context[M.db.session]
    local loadedAddons = sessionCtx and sessionCtx.loadedAddons
    if loadedAddons then
        parts[#parts + 1] = "Addons:   " .. tostring(#loadedAddons) .. " loaded"
    end
    parts[#parts + 1] = ""

    -- Summary
    parts[#parts + 1] = "--- Summary ---"
    parts[#parts + 1] = tostring(#list) .. " unique error" .. (#list ~= 1 and "s" or "") .. " captured"
    local kindNames = {
        LuaError = "Lua Errors",
        Taint = "Taint Warnings",
        Warning = "Warnings",
        Debug = "Debug Messages",
        UIError = "UI Errors",
    }
    local kindOrder = { "LuaError", "Taint", "Warning", "UIError", "Debug" }
    for _, k in ipairs(kindOrder) do
        local c = counts[k] or 0
        if c > 0 then
            local totalOccurrences = 0
            for _, e in ipairs(list) do
                if e.kind == k then totalOccurrences = totalOccurrences + (e.count or 1) end
            end
            parts[#parts + 1] = string.format("  %-20s %d unique (%d total occurrences)",
                (kindNames[k] or k) .. ":", c, totalOccurrences)
        end
    end

    -- Source addons
    if #addons > 0 then
        parts[#parts + 1] = ""
        parts[#parts + 1] = "Source Addons:"
        local maxA = #addons
        if maxA > 10 then maxA = 10 end
        for i = 1, maxA do
            local a = addons[i]
            local name = SafeToString(a.addon or "Unknown")
            local ver = nil
            for _, e in ipairs(list) do
                if e.addon == a.addon and e.addonVersion and e.addonVersion ~= "" then
                    ver = e.addonVersion
                    break
                end
            end
            if ver then name = name .. " v" .. ver end
            parts[#parts + 1] = string.format("  %-35s %d events", name, a.events or 0)
        end
    end

    parts[#parts + 1] = ""
    parts[#parts + 1] = ""

    -- Individual error details
    for i = 1, #list do
        local e = list[i]
        if e then
            local kindLabel = "Error"
            if e.kind == "LuaError" then kindLabel = "Lua Error"
            elseif e.kind == "Taint" then kindLabel = "Taint Warning"
            elseif e.kind == "Warning" then kindLabel = "Warning"
            elseif e.kind == "Debug" then kindLabel = "Debug Message"
            elseif e.kind == "UIError" then kindLabel = "UI Error"
            end

            parts[#parts + 1] = "========================================"
            parts[#parts + 1] = string.format("  Error %d of %d - %s", i, #list, kindLabel)
            parts[#parts + 1] = "========================================"

            -- Source and location
            local source = SafeToString(e.addon or "Unknown")
            if e.addonVersion and e.addonVersion ~= "" then
                source = source .. " v" .. SafeToString(e.addonVersion)
            end
            parts[#parts + 1] = "Source:     " .. source
            if e.sig and e.sig ~= "" then
                parts[#parts + 1] = "Location:   " .. SafeToString(e.sig)
            end

            -- Occurrence info
            local countNum = e.count or 1
            parts[#parts + 1] = "Occurred:   " .. tostring(countNum) .. " time" .. (countNum ~= 1 and "s" or "")
            local firstStr = e.firstSeen and date("%I:%M %p", e.firstSeen) or "?"
            local lastStr = e.lastSeen and date("%I:%M %p", e.lastSeen) or "?"
            if countNum > 1 then
                parts[#parts + 1] = "First seen: " .. firstStr .. "   Last seen: " .. lastStr
            else
                parts[#parts + 1] = "Time:       " .. firstStr
            end

            -- Per-error context
            local ec = e.errorContext
            if ec then
                parts[#parts + 1] = ""
                parts[#parts + 1] = "What was happening:"
                if ec.combat ~= nil then
                    parts[#parts + 1] = "  In combat:   " .. (ec.combat and "Yes" or "No")
                end
                if ec.zone and ec.zone ~= "" then
                    local zoneLine = SafeToString(ec.zone)
                    if ec.subzone and ec.subzone ~= "" and ec.subzone ~= ec.zone then
                        zoneLine = zoneLine .. " - " .. SafeToString(ec.subzone)
                    end
                    parts[#parts + 1] = "  Zone:        " .. zoneLine
                end
                if ec.inInstance ~= nil then
                    if ec.inInstance then
                        parts[#parts + 1] = "  In instance: Yes (" .. SafeToString(ec.instanceType or "unknown") .. ")"
                    else
                        parts[#parts + 1] = "  In instance: No"
                    end
                end
                if ec.groupSize and ec.groupSize > 0 then
                    parts[#parts + 1] = "  Group size:  " .. tostring(ec.groupSize)
                end
            end

            -- Error message
            parts[#parts + 1] = ""
            parts[#parts + 1] = "Error:"
            parts[#parts + 1] = "  " .. SafeToString(e.message or "")

            -- Taint explanation for non-technical players
            if e.kind == "Taint" then
                parts[#parts + 1] = ""
                parts[#parts + 1] = "  Note: This means an addon modified a Blizzard UI element"
                parts[#parts + 1] = "  in a way that prevents it from working during combat."
                parts[#parts + 1] = "  This does not affect gameplay but may cause minor UI"
                parts[#parts + 1] = "  glitches until combat ends."
            end

            -- Stack trace (formatted with indentation)
            if e.stack and e.stack ~= "" then
                parts[#parts + 1] = ""
                parts[#parts + 1] = "Call Stack:"
                for line in SafeToString(e.stack):gmatch("[^\n]+") do
                    local trimmed = line:match("^%s*(.-)%s*$") or line
                    if trimmed ~= "" then
                        parts[#parts + 1] = "  " .. trimmed
                    end
                end
            end

            -- Local variables
            if e.locals and e.locals ~= "" then
                parts[#parts + 1] = ""
                parts[#parts + 1] = "Variables at crash:"
                for line in SafeToString(e.locals):gmatch("[^\n]+") do
                    local trimmed = line:match("^%s*(.-)%s*$") or line
                    if trimmed ~= "" then
                        parts[#parts + 1] = "  " .. trimmed
                    end
                end
            end

            parts[#parts + 1] = ""
            parts[#parts + 1] = ""
        end
    end

    local okConcat, text = pcall(table.concat, parts, "\n")
    if not okConcat then
        return "Diagnostics export failed while building user friendly text."
    end
    -- Escape pipes for WoW EditBox display (|| displays as | in-game)
    return text:gsub("|", "||")
end

local function BuildLLMReadyCopyAllText(model)
    local parts = {}
    local list = model and model.list or {}
    local exportCtx = model and model.exportCtx or {}

    -- Header - concise instruction for the LLM
    parts[#parts + 1] = "@@MIDNIGHTUI_DIAG@@"
    parts[#parts + 1] = "World of Warcraft addon diagnostic export from MidnightUI."
    parts[#parts + 1] = "Each [error] block is a unique captured error with full context."
    parts[#parts + 1] = "Diagnose the root cause, identify the exact file and line, and provide a fix."
    parts[#parts + 1] = "Note: || represents a literal | character (WoW EditBox escaping)."
    parts[#parts + 1] = ""

    -- Environment
    parts[#parts + 1] = "[env]"
    parts[#parts + 1] = string.format("client=%s build=%s toc=%s locale=%s",
        SafeToString(exportCtx.client or "?"), SafeToString(exportCtx.build or "?"),
        SafeToString(exportCtx.toc or "?"), SafeToString(exportCtx.locale or "?"))
    parts[#parts + 1] = string.format("player=%s realm=%s class=%s spec=%s race=%s level=%s",
        SafeToString(exportCtx.player or "?"), SafeToString(exportCtx.realm or "?"),
        SafeToString(exportCtx.class or "?"), SafeToString(exportCtx.spec or "n/a"),
        SafeToString(exportCtx.race or "?"), SafeToString(exportCtx.level or "?"))
    local resW = exportCtx.screenW and string.format("%.0f", exportCtx.screenW) or "?"
    local resH = exportCtx.screenH and string.format("%.0f", exportCtx.screenH) or "?"
    parts[#parts + 1] = string.format("resolution=%sx%s ui_scale=%s",
        resW, resH, SafeToString(exportCtx.uiScale or "?"))
    parts[#parts + 1] = ""

    -- Loaded addons manifest
    local sessionCtx = M.db and M.db.context and M.db.context[M.db.session]
    local loadedAddons = sessionCtx and sessionCtx.loadedAddons
    if loadedAddons and #loadedAddons > 0 then
        parts[#parts + 1] = "[addons]"
        parts[#parts + 1] = table.concat(loadedAddons, ", ")
        parts[#parts + 1] = ""
    end

    -- Error entries - complete, untruncated, with all diagnostic data
    local total = #list
    for i = 1, total do
        local e = list[i]
        if e then
            local kind = e.kind or "Unknown"
            local count = e.count or 1
            local addon = SafeToString(e.addon or "Unknown")
            local ver = e.addonVersion
            local addonStr = (ver and ver ~= "") and (addon .. ":" .. ver) or addon
            local sig = e.sig or ""

            parts[#parts + 1] = string.format("[error %d/%d] %s x%d addon=%s sig=%s",
                i, total, kind, count, addonStr, sig)

            -- ISO timestamps with date
            local first = e.firstSeen and date("!%Y-%m-%dT%H:%M:%S", e.firstSeen) or "?"
            local last = e.lastSeen and date("!%Y-%m-%dT%H:%M:%S", e.lastSeen) or "?"
            parts[#parts + 1] = string.format("first=%s last=%s", first, last)

            -- Per-error context (captured at the moment the error fired)
            local ec = e.errorContext
            if ec then
                local zoneName = SafeToString(ec.zone or "?")
                if ec.subzone and ec.subzone ~= "" and ec.subzone ~= ec.zone then
                    zoneName = zoneName .. " / " .. SafeToString(ec.subzone)
                end
                parts[#parts + 1] = string.format('at_error: combat=%s zone="%s" instance=%s group=%s',
                    tostring(ec.combat or false),
                    zoneName,
                    SafeToString(ec.instanceType or "none"),
                    tostring(ec.groupSize or 0))
                if ec.spec then
                    parts[#parts + 1] = "spec_at_error=" .. SafeToString(ec.spec)
                end
            end

            -- Message (full, no truncation)
            local msg = SafeToString(e.message or "")
            parts[#parts + 1] = "msg<<<"
            parts[#parts + 1] = msg
            parts[#parts + 1] = ">>>"

            -- Stack trace (full, no truncation)
            if e.stack and e.stack ~= "" then
                parts[#parts + 1] = "stack<<<"
                parts[#parts + 1] = SafeToString(e.stack)
                parts[#parts + 1] = ">>>"
            end

            -- Local variables (the key diagnostic data that was previously never exported)
            if e.locals and e.locals ~= "" then
                parts[#parts + 1] = "locals<<<"
                parts[#parts + 1] = SafeToString(e.locals)
                parts[#parts + 1] = ">>>"
            end

            -- Meta (if present)
            if e.meta and e.meta ~= "" then
                parts[#parts + 1] = "meta=" .. SafeToString(e.meta)
            end

            parts[#parts + 1] = ""
        end
    end

    parts[#parts + 1] = "@@END@@"

    local okConcat, text = pcall(table.concat, parts, "\n")
    if not okConcat then
        return "Diagnostics export failed while building LLM diagnostic text."
    end
    -- Escape pipes for WoW EditBox display (|| displays as | in-game)
    return text:gsub("|", "||")
end

local function BuildCopyAllTextByMode(entries, activeAddonFilter, copyMode)
    local model = BuildCopyAllModel(entries, activeAddonFilter)
    local mode = NormalizeCopyAllMode(copyMode)
    if mode == COPYALL_MODE_LLM then
        return BuildLLMReadyCopyAllText(model), "llm_ready"
    end
    return BuildUserFriendlyCopyAllText(model), "user_friendly"
end

local function BuildCompactCopyAllText(entries, activeAddonFilter, copyMode)
    return BuildCopyAllTextByMode(entries, activeAddonFilter, copyMode)
end

local UpdateDetailScrollbar

local function UpdateDetails()
    if not frame or not frame.detailBox then return end
    if frame._muiCopyAllActive then return end
    local e = filtered[selectedIndex]
    if not e then frame.detailBox:SetText("No diagnostics captured.") return end
    local text = BuildEntryText(e)
    -- EditBox silently rejects text with malformed WoW pipe sequences (|c, |r,
    -- |H etc.).  Warning messages from the engine can contain these.  Try raw
    -- first, then fall back to escaped pipes so the inspector never appears empty.
    frame.detailBox:SetText(text)
    if (frame.detailBox:GetText() or "") == "" and text ~= "" then
        frame.detailBox:SetText(text:gsub("|", "||"))
    end
    UpdateDetailScrollbar()
end

local function UpdateSummary()
    if not frame or not frame.summaryLabel then return end
    if not M.db or not M.db.errors then
        if frame.summaryLabel.luaValue then
            frame.summaryLabel.luaValue:SetText("0")
            frame.summaryLabel.taintValue:SetText("0")
            frame.summaryLabel.warnValue:SetText("0")
            frame.summaryLabel.uiValue:SetText("0")
            frame.summaryLabel.debugValue:SetText("0")
        end
        return
    end
    local totals = { LuaError = 0, Taint = 0, Warning = 0, UIError = 0, Debug = 0 }
    for _, e in ipairs(filtered) do
        if e and e.kind and totals[e.kind] ~= nil then
            if e.kind ~= "UIError" then
                totals[e.kind] = totals[e.kind] + 1
            end
        end
        if e and (e.kind == "UIError" or e.addon == "Blizzard") then
            totals.UIError = totals.UIError + 1
        end
    end
    if frame.summaryLabel.luaValue then
        frame.summaryLabel.luaValue:SetText(tostring(totals.LuaError))
        frame.summaryLabel.taintValue:SetText(tostring(totals.Taint))
        frame.summaryLabel.warnValue:SetText(tostring(totals.Warning))
        frame.summaryLabel.uiValue:SetText(tostring(totals.UIError))
        frame.summaryLabel.debugValue:SetText(tostring(totals.Debug))
    end
end

UpdateDetailScrollbar = function()
    if not frame or not frame.detailBox or not frame.detailScroll then return end
    local scroll = frame.detailScroll
    local box = frame.detailBox
    local height = box.GetStringHeight and box:GetStringHeight() or 0
    if height < 1 then height = 1 end
    if height > DETAIL_TEXT_MAX_HEIGHT then height = DETAIL_TEXT_MAX_HEIGHT end
    local contentHeight = height + 20
    box:SetHeight(contentHeight)
    local scrollHeight = scroll:GetHeight() or 0
    if scroll.ScrollBar then
        if contentHeight <= scrollHeight then
            scroll.ScrollBar:Hide()
            scroll:SetVerticalScroll(0)
        else
            scroll.ScrollBar:Show()
        end
    end
end

local function UpdateListButtons()
    if not frame or not frame.scroll then return end
    local offset = FauxScrollFrame_GetOffset(frame.scroll)
    for i = 1, #listButtons do
        local idx = i + offset
        local btn = listButtons[i]
        local e = filtered[idx]
        if e then
            btn:Show()
            local kind, addon, msg, count, stamp = FormatEntryShort(e)
            btn.kind:SetText(kind)
            btn.addon:SetText(addon)
            btn.message:SetText(msg)
            btn.count:SetText("x" .. tostring(count))
            btn.time:SetText(stamp)
            local c = KIND_COLORS[e.kind or kind] or UI_COLORS.text
            btn.kind:SetTextColor(c[1], c[2], c[3])
            btn.bar:SetColorTexture(c[1], c[2], c[3], 0.9)
            if idx == selectedIndex then btn.bg:Show() else btn.bg:Hide() end
            btn.entryIndex = idx
        else
            btn:Hide()
            btn.entryIndex = nil
        end
    end
    FauxScrollFrame_Update(frame.scroll, #filtered, #listButtons, ROW_HEIGHT)
    if frame.scroll and frame.scroll.ScrollBar then
        if #filtered <= #listButtons then
            frame.scroll.ScrollBar:Hide()
        else
            frame.scroll.ScrollBar:Show()
        end
    end
end
local function CreateRow(parent, index, onClick)
    local btn = CreateFrame("Button", nil, parent)
    local rowTop = (frame and frame._listRowTop) or -66
    local leftInset = (frame and frame._listRowLeftInset) or 10
    local rightInset = (frame and frame._listRowRightInset) or 32
    btn:SetHeight(ROW_HEIGHT)
    btn:SetPoint("TOPLEFT", leftInset, rowTop - (index - 1) * ROW_HEIGHT)
    btn:SetPoint("TOPRIGHT", -rightInset, rowTop - (index - 1) * ROW_HEIGHT)

    btn.alt = btn:CreateTexture(nil, "BACKGROUND")
    btn.alt:SetAllPoints()
    btn.alt:SetColorTexture(UI_COLORS.rowAlt[1], UI_COLORS.rowAlt[2], UI_COLORS.rowAlt[3], 0.25)
    if index % 2 == 0 then btn.alt:Show() else btn.alt:Hide() end

    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(UI_COLORS.row[1], UI_COLORS.row[2], UI_COLORS.row[3], 0.45)
    btn.bg:Hide()

    btn.bar = btn:CreateTexture(nil, "ARTWORK")
    btn.bar:SetSize(3, ROW_HEIGHT - 8)
    btn.bar:SetPoint("LEFT", 1, 0)

    btn.kind = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.kind:SetPoint("LEFT", 10, 0)
    btn.kind:SetWidth(110)
    btn.kind:SetJustifyH("LEFT")

    btn.addon = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.addon:SetPoint("LEFT", btn.kind, "RIGHT", 6, 0)
    btn.addon:SetWidth(120)
    btn.addon:SetJustifyH("LEFT")

    btn.message = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.message:SetPoint("LEFT", btn.addon, "RIGHT", 6, 0)
    btn.message:SetPoint("RIGHT", -170, 0)
    btn.message:SetJustifyH("LEFT")
    btn.message:SetWordWrap(false)

    btn.count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.count:SetPoint("RIGHT", -92, 0)
    btn.count:SetJustifyH("RIGHT")

    btn.time = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    btn.time:SetPoint("RIGHT", -14, 0)
    btn.time:SetJustifyH("RIGHT")

    btn:SetScript("OnClick", onClick)
    btn:SetScript("OnEnter", function(self) if self.entryIndex ~= selectedIndex then self.bg:Show() end end)
    btn:SetScript("OnLeave", function(self) if self.entryIndex ~= selectedIndex then self.bg:Hide() end end)

    return btn
end

local function EnsureListButtonsCount(parent, onClick)
    if not parent then return end
    local scrollHeight = (frame and frame.scroll and frame.scroll.GetHeight) and (frame.scroll:GetHeight() or 0) or 0
    local h = parent:GetHeight() or 0
    local available = scrollHeight
    if available <= 0 then
        local topOffset = math.abs((frame and frame._listRowTop) or -66)
        local bottomInset = (frame and frame._listBottomInset) or 10
        available = h - topOffset - bottomInset - 8
    end
    local count = math.floor(available / ROW_HEIGHT)
    if count < 4 then count = 4 end
    if count > 26 then count = 26 end
    if #listButtons > count then
        for i = #listButtons, count + 1, -1 do
            if listButtons[i] then listButtons[i]:Hide() end
            table.remove(listButtons, i)
        end
    elseif #listButtons < count then
        for i = #listButtons + 1, count do
            listButtons[i] = CreateRow(parent, i, onClick)
        end
    end
    local rowTop = (frame and frame._listRowTop) or -66
    local leftInset = (frame and frame._listRowLeftInset) or 10
    local rightInset = (frame and frame._listRowRightInset) or 32
    for i = 1, #listButtons do
        local btn = listButtons[i]
        if btn then
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", leftInset, rowTop - (i - 1) * ROW_HEIGHT)
            btn:SetPoint("TOPRIGHT", -rightInset, rowTop - (i - 1) * ROW_HEIGHT)
        end
    end
end

local function BuildAddonList()
    wipe(addonList)
    if not M.db or not M.db.errors then return end
    local counts = {}
    for _, e in ipairs(M.db.errors) do
        if e and e.kind then
            local enabled = M.filter[e.kind]
            if e.kind == "Taint" then
                enabled = (M.filter.TaintInferred or M.filter.TaintExplicit)
            end
            if enabled and MatchesSession(e) and MatchesSearch(e) then
                local name = e.addon or "NoAddon"
                counts[name] = (counts[name] or 0) + 1
            end
        end
    end
    local items = {}
    for name, count in pairs(counts) do
        items[#items + 1] = { name = name, count = count }
    end
    table.sort(items, function(a, b)
        if a.count == b.count then return a.name < b.name end
        return a.count > b.count
    end)
    addonList[1] = { name = "ALL", count = 0 }
    for i = 1, #items do
        addonList[#addonList + 1] = items[i]
    end
    local visibleCount = #addonList - 1
    if visibleCount < 1 then visibleCount = 1 end
    addonPageCount = math.ceil(visibleCount / addonPageSize)
    ClampAddonPage()
end

local function EnsureAddonButtons()
    if not frame or not frame.addonPanel then return end
    BuildAddonList()
    if #addonButtons == 0 then
        for i = 1, 7 do
            local b = CreateFrame("Button", nil, frame.addonPanel, "UIPanelButtonTemplate")
            b:SetSize(146, 22)
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            b:SetPoint("TOPLEFT", col * 152, -row * 24)
            b:SetText("Addon")
            StyleButton(b)
            b:SetScript("OnClick", function(self)
                if self.addonName == "__more" then
                    addonPage = addonPage + 1
                    ClampAddonPage()
                    M.Refresh()
                    return
                end
                if self.addonName == "ALL" or self.addonName == nil then
                    addonFilter = nil
                else
                    addonFilter = self.addonName
                end
                M.Refresh()
            end)
            addonButtons[i] = b
        end
    end
    local startIndex = 2 + (addonPage - 1) * addonPageSize
    for i = 1, #addonButtons do
        local btn = addonButtons[i]
        local info = nil
        if i == 1 then
            info = addonList[1]
        else
            info = addonList[startIndex + (i - 2)]
        end
        if info then
            btn:Show()
            if info.name == "ALL" then
                btn:SetText("All Addons")
                btn.addonName = nil
            else
                btn:SetText(string.format("%s (%d)", info.name, info.count))
                btn.addonName = info.name
            end
        else
            btn:Hide()
            btn.addonName = nil
        end
    end
    if addonPageCount > 1 then
        local lastBtn = addonButtons[#addonButtons]
        if lastBtn then
            lastBtn:Show()
            lastBtn:SetText("More...")
            lastBtn.addonName = "__more"
        end
    end
end

local function EnsureSessionButtons()
    if not frame or not frame.sessionPanel then return end
    BuildSessionList()
    if #sessionButtons == 0 then
        for i = 1, 6 do
            local b = CreateFrame("Button", nil, frame.sessionPanel, "UIPanelButtonTemplate")
            b:SetSize(146, 22)
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            b:SetPoint("TOPLEFT", col * 152, -row * 24)
            b:SetText("Session")
            StyleButton(b)
            b:SetScript("OnClick", function(self)
                if self._sessionValue == "all" or self._sessionValue == nil then
                    M.view.sessionFilter = "all"
                else
                    M.view.sessionFilter = self._sessionValue
                end
                M.Refresh()
            end)
            sessionButtons[i] = b
        end
    end

    local items = {}
    items[#items + 1] = { label = "All Sessions", value = "all" }
    if M.db and M.db.session then
        items[#items + 1] = { label = "Current (" .. tostring(M.db.session) .. ")", value = "current" }
    end
    for i = 1, math.min(4, #sessionList) do
        local id = sessionList[i]
        items[#items + 1] = { label = "Session " .. tostring(id), value = id }
    end

    for i = 1, #sessionButtons do
        local btn = sessionButtons[i]
        local info = items[i]
        if info then
            btn:Show()
            btn:SetText(info.label)
            btn._sessionValue = info.value
            local fs = btn:GetFontString()
            if fs then
                if sessionFilter == info.value then
                    fs:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
                else
                    fs:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
                end
            end
        else
            btn:Hide()
            btn._sessionValue = nil
        end
    end
end

local function CreateUI()
    _G.MidnightUI_DiagnosticsLoadState = "ui_create_start"
    frame = CreateFrame("Frame", "MidnightUI_DiagnosticsFrame", UIParent, "BackdropTemplate")
    frame:SetSize(1320, 780)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetResizable(true)
    if frame.SetMinResize then
        frame:SetMinResize(1280, 760)
    end
    StyleFrame(frame, UI_COLORS.bg, UI_COLORS.border)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)

    local PAD = 14
    local GUTTER = 12
    local HEADER_H = 54
    local RAIL_W = 340
    local DETAIL_W = 420

    local header = frame:CreateTexture(nil, "BACKGROUND")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    header:SetVertexColor(UI_COLORS.inset[1], UI_COLORS.inset[2], UI_COLORS.inset[3], 0.95)

    local headerAccent = frame:CreateTexture(nil, "ARTWORK")
    headerAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerAccent:SetPoint("TOPLEFT", 1, -1)
    headerAccent:SetPoint("TOPRIGHT", -1, -1)
    headerAccent:SetHeight(2)
    headerAccent:SetVertexColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 1)

    local headerLine = frame:CreateTexture(nil, "BACKGROUND")
    headerLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerLine:SetPoint("TOPLEFT", PAD, -(HEADER_H + 1))
    headerLine:SetPoint("TOPRIGHT", -PAD, -(HEADER_H + 1))
    headerLine:SetHeight(1)
    headerLine:SetVertexColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.65)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", PAD + 4, -10)
    title:SetText("MIDNIGHT UI DIAGNOSTICS")
    title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", PAD + 4, -30)
    subtitle:SetText("Capture, triage, and export issue traces by session and source.")
    subtitle:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local close = CreateFrame("Button", nil, frame, "BackdropTemplate")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetText("X")
    close:SetNormalFontObject("GameFontNormalSmall")
    StyleButton(close)
    close:SetScript("OnClick", function() frame:Hide() end)

    -- ESC to close (via UISpecialFrames)
    table.insert(UISpecialFrames, "MidnightUI_DiagnosticsFrame")

    local countLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    countLabel:SetPoint("RIGHT", close, "LEFT", -12, 0)
    countLabel:SetText("Entry 0 of 0")
    countLabel:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    frame.countLabel = countLabel

    local searchBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    searchBtn:SetSize(70, 24)
    searchBtn:SetPoint("RIGHT", countLabel, "LEFT", -10, 0)
    searchBtn:SetText("Search")
    StyleButton(searchBtn)

    local searchFrame = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    searchFrame:SetSize(280, 24)
    searchFrame:SetPoint("RIGHT", searchBtn, "LEFT", -8, 0)
    StyleFrame(searchFrame, UI_COLORS.inset, UI_COLORS.border)

    local searchBox = CreateFrame("EditBox", nil, searchFrame)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(80)
    searchBox:SetFontObject("GameFontNormalSmall")
    searchBox:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    searchBox:SetTextInsets(4, 4, 2, 2)
    searchBox:SetPoint("TOPLEFT", searchFrame, "TOPLEFT", 6, -2)
    searchBox:SetPoint("BOTTOMRIGHT", searchFrame, "BOTTOMRIGHT", -6, 2)
    searchBox:SetText(M.view and M.view.searchText or "")

    local searchHint = searchFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchHint:SetPoint("LEFT", searchFrame, "LEFT", 8, 0)
    searchHint:SetText("message / addon / stack")
    searchHint:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local function UpdateSearchHint()
        local txt = searchBox:GetText() or ""
        if txt == "" then searchHint:Show() else searchHint:Hide() end
    end

    searchBox:SetScript("OnTextChanged", function(self)
        M.view.searchText = self:GetText() or ""
        UpdateSearchHint()
        M.Refresh()
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)
    searchBtn:SetScript("OnClick", function()
        if searchBox then
            searchBox:SetFocus()
            searchBox:HighlightText()
        end
    end)
    UpdateSearchHint()
    frame.searchBox = searchBox

    local leftRail = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    leftRail:SetPoint("TOPLEFT", PAD, -(HEADER_H + PAD))
    leftRail:SetPoint("BOTTOMLEFT", PAD, PAD)
    leftRail:SetWidth(RAIL_W)
    StylePanel(leftRail)

    local detailPane = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    detailPane:SetPoint("TOPRIGHT", -PAD, -(HEADER_H + PAD))
    detailPane:SetPoint("BOTTOMRIGHT", -PAD, PAD)
    detailPane:SetWidth(DETAIL_W)
    StylePanel(detailPane)

    local listPane = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    listPane:SetPoint("TOPLEFT", leftRail, "TOPRIGHT", GUTTER, 0)
    listPane:SetPoint("BOTTOMRIGHT", detailPane, "BOTTOMLEFT", -GUTTER, 0)
    StylePanel(listPane)

    frame.left = listPane
    frame.right = detailPane
    frame.leftRail = leftRail
    frame.listPanel = listPane

    local function SetCheckLabel(cb, label)
        local text = cb.Text or cb.text or cb.Label or cb.label
        if not text then return end
        text:SetText(label)
        text:SetFontObject("GameFontNormalSmall")
        text:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    end

    local filterCard = CreateFrame("Frame", nil, leftRail, "BackdropTemplate")
    filterCard:SetPoint("TOPLEFT", leftRail, "TOPLEFT", 10, -10)
    filterCard:SetPoint("TOPRIGHT", leftRail, "TOPRIGHT", -10, -10)
    filterCard:SetHeight(204)
    StyleFrame(filterCard, UI_COLORS.inset, UI_COLORS.border)

    local filterTitle = filterCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    filterTitle:SetPoint("TOPLEFT", 12, -10)
    filterTitle:SetText("Filters")
    filterTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    CreateHelpIcon(filterCard, filterTitle, "Filters", {
        "|cffffd200What this does|r",
        "Turn categories on or off so the list only shows what you care about.",
        " ",
        "|cffffd200Lua Errors|r are real errors that stopped code.",
        "|cffffd200Warnings|r are softer problems that may still matter.",
        "|cffffd200Blizzard Errors|r come from the default UI.",
        "|cffffd200Taint|r means the UI blocked insecure actions.",
        " ",
        "|cffffd200Group By Signature|r collapses repeats into one row with a count.",
        "|cffffd200Bucket View|r builds a summary across sessions.",
        "|cffffd200Auto-Open On Error|r pops this window when a new error happens out of combat.",
        "|cff00ccffTip|r: If you only want hard errors, uncheck |cffffd200Debug|r.",
    })

    local typeSub = filterCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    typeSub:SetPoint("TOPLEFT", 12, -26)
    typeSub:SetText("TYPE")
    typeSub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local function CreateFilter(label, key, x, y)
        local cb = CreateFrame("CheckButton", nil, filterCard, "UICheckButtonTemplate")
        cb:SetPoint("TOPLEFT", x, y)
        cb:SetChecked(M.filter[key])
        SetCheckLabel(cb, label)
        cb:SetScript("OnClick", function(self)
            M.filter[key] = self:GetChecked() == true
            M.Refresh()
        end)
        return cb
    end

    M.filter = {
        LuaError = true,
        Warning = true,
        UIError = false,
        Debug = true,
        TaintInferred = true,
        TaintExplicit = true,
    }
    local FILTER_COL1_X = 12
    local FILTER_COL2_X = 162
    local FILTER_ROW1_Y = -40
    local FILTER_STEP = 20
    local VIEW_HEADER_Y = -118
    local VIEW_ROW1_Y = -132
    local VIEW_STEP = 22
    CreateFilter("Lua Errors", "LuaError", FILTER_COL1_X, FILTER_ROW1_Y)
    CreateFilter("Warnings", "Warning", FILTER_COL1_X, FILTER_ROW1_Y - FILTER_STEP)
    CreateFilter("Debug", "Debug", FILTER_COL1_X, FILTER_ROW1_Y - FILTER_STEP * 2)
    CreateFilter("Blizzard Errors", "UIError", FILTER_COL2_X, FILTER_ROW1_Y)
    CreateFilter("Potential Taint", "TaintInferred", FILTER_COL2_X, FILTER_ROW1_Y - FILTER_STEP)
    CreateFilter("Confirmed Taint", "TaintExplicit", FILTER_COL2_X, FILTER_ROW1_Y - FILTER_STEP * 2)

    local filterLine = filterCard:CreateTexture(nil, "BACKGROUND")
    filterLine:SetColorTexture(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.5)
    filterLine:SetPoint("TOPLEFT", 10, VIEW_HEADER_Y + 8)
    filterLine:SetPoint("TOPRIGHT", -10, VIEW_HEADER_Y + 8)
    filterLine:SetHeight(1)

    local viewSub = filterCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    viewSub:SetPoint("TOPLEFT", 12, VIEW_HEADER_Y)
    viewSub:SetText("VIEW")
    viewSub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    viewSub:SetDrawLayer("OVERLAY", 7)

    local groupCheck = CreateFrame("CheckButton", nil, filterCard, "UICheckButtonTemplate")
    groupCheck:SetPoint("TOPLEFT", FILTER_COL1_X, VIEW_ROW1_Y)
    groupCheck:SetChecked(M.view and M.view.groupBySig or false)
    SetCheckLabel(groupCheck, "Group By Signature")
    groupCheck:SetScript("OnClick", function(self)
        M.view.groupBySig = self:GetChecked() == true
        M.Refresh()
    end)

    local bucketCheck = CreateFrame("CheckButton", nil, filterCard, "UICheckButtonTemplate")
    bucketCheck:SetPoint("TOPLEFT", FILTER_COL2_X, VIEW_ROW1_Y)
    bucketCheck:SetChecked(M.view and M.view.bucketView == true)
    SetCheckLabel(bucketCheck, "Bucket View")
    bucketCheck:SetScript("OnClick", function(self)
        M.view.bucketView = self:GetChecked() == true
        M.Refresh()
    end)

    local autoOpenCheck = CreateFrame("CheckButton", nil, filterCard, "UICheckButtonTemplate")
    autoOpenCheck:SetPoint("TOPLEFT", FILTER_COL1_X, VIEW_ROW1_Y - VIEW_STEP)
    autoOpenCheck:SetChecked(M.view and M.view.autoOpen == true)
    SetCheckLabel(autoOpenCheck, "Auto-Open On Error")
    autoOpenCheck:SetScript("OnClick", function(self)
        M.view.autoOpen = self:GetChecked() == true
    end)

    local sessionCard = CreateFrame("Frame", nil, leftRail, "BackdropTemplate")
    sessionCard:SetPoint("TOPLEFT", filterCard, "BOTTOMLEFT", 0, -10)
    sessionCard:SetPoint("TOPRIGHT", filterCard, "BOTTOMRIGHT", 0, -10)
    sessionCard:SetHeight(120)
    StyleFrame(sessionCard, UI_COLORS.inset, UI_COLORS.border)

    local sessionTitle = sessionCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sessionTitle:SetPoint("TOPLEFT", 12, -10)
    sessionTitle:SetText("Sessions")
    sessionTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    local sessionHelp = CreateHelpIcon(sessionCard, sessionTitle, "Sessions", {
        "|cffffd200What this does|r",
        "Sessions are automatic snapshots made on login or reload.",
        "Each entry is tagged with the session it happened in.",
        " ",
        "|cffffd200All Sessions|r shows everything captured across time.",
        "|cffffd200Current|r is only this login. Great for testing changes.",
        "|cffffd200Session 26|r, |cffffd200Session 25|r, and so on are older runs.",
        " ",
        "Use a past session to compare if a bug stopped happening.",
        "|cff00ccffTip|r: Bucket View makes this comparison cleaner.",
    })

    local sessionMoreBtn = CreateFrame("Button", nil, sessionCard, "BackdropTemplate")
    sessionMoreBtn:SetSize(22, 16)
    sessionMoreBtn:SetPoint("LEFT", sessionHelp, "RIGHT", 6, 0)
    sessionMoreBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    sessionMoreBtn:SetBackdropColor(0.10, 0.12, 0.18, 0.9)
    sessionMoreBtn:SetBackdropBorderColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 1)
    sessionMoreBtn.text = sessionMoreBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sessionMoreBtn.text:SetPoint("CENTER", 0, -1)
    sessionMoreBtn.text:SetText("...")
    sessionMoreBtn.text:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    sessionMoreBtn:SetScript("OnClick", function(self)
        ShowSessionDropdown(self)
    end)
    sessionMoreBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("All Sessions", 1, 0.82, 0)
        GameTooltip:AddLine("Show the full session list.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    sessionMoreBtn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    local sessionPanel = CreateFrame("Frame", nil, sessionCard)
    sessionPanel:SetPoint("TOPLEFT", 10, -34)
    sessionPanel:SetPoint("TOPRIGHT", -10, -34)
    sessionPanel:SetHeight(74)
    frame.sessionPanel = sessionPanel

    local addonCard = CreateFrame("Frame", nil, leftRail, "BackdropTemplate")
    addonCard:SetPoint("TOPLEFT", sessionCard, "BOTTOMLEFT", 0, -10)
    addonCard:SetPoint("TOPRIGHT", sessionCard, "BOTTOMRIGHT", 0, -10)
    addonCard:SetHeight(200)
    StyleFrame(addonCard, UI_COLORS.inset, UI_COLORS.border)

    local addonTitle = addonCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    addonTitle:SetPoint("TOPLEFT", 12, -10)
    addonTitle:SetText("Addons")
    addonTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    CreateHelpIcon(addonCard, addonTitle, "Filter by Addon", {
        "|cffffd200What this does|r",
        "Shows entries for one addon at a time.",
        "Each button includes the addon name and how many entries match.",
        " ",
        "|cffffd200All Addons|r clears the filter.",
        "|cffffd200More...|r cycles to the next set if you have many addons.",
        "Use |cffffd200Search|r to find a name quickly.",
    })

    local addonPanel = CreateFrame("Frame", nil, addonCard)
    addonPanel:SetPoint("TOPLEFT", 10, -34)
    addonPanel:SetPoint("TOPRIGHT", -10, -34)
    addonPanel:SetHeight(146)
    frame.addonPanel = addonPanel

    local summaryCard = CreateFrame("Frame", nil, leftRail, "BackdropTemplate")
    summaryCard:SetPoint("TOPLEFT", addonCard, "BOTTOMLEFT", 0, -10)
    summaryCard:SetPoint("TOPRIGHT", addonCard, "BOTTOMRIGHT", 0, -10)
    summaryCard:SetPoint("BOTTOMLEFT", leftRail, "BOTTOMLEFT", 10, 10)
    summaryCard:SetPoint("BOTTOMRIGHT", leftRail, "BOTTOMRIGHT", -10, 10)
    StyleFrame(summaryCard, UI_COLORS.inset, UI_COLORS.border)

    local summaryTitle = summaryCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    summaryTitle:SetPoint("TOPLEFT", 12, -10)
    summaryTitle:SetText("Summary")
    summaryTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    CreateHelpIcon(summaryCard, summaryTitle, "All Issues Summary", {
        "|cffffd200What this does|r",
        "Quick totals for each category in the current view.",
        "Counts update with filters, sessions, and search.",
        " ",
        "Spikes in |cffffd200Lua Errors|r or |cffffd200Taint|r usually mean addon trouble.",
        "|cff00ccffTip|r: Use Bucket View to see repeat offenders fast.",
    })

    local summaryBox = CreateFrame("Frame", nil, summaryCard, "BackdropTemplate")
    summaryBox:SetPoint("TOPLEFT", 10, -34)
    summaryBox:SetPoint("TOPRIGHT", -10, -34)
    summaryBox:SetHeight(78)
    StyleFrame(summaryBox, UI_COLORS.inset, UI_COLORS.border)
    frame.summaryBox = summaryBox

    local function MakeSummaryLabel(parent, label, x, y)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText(label)
        fs:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
        return fs
    end

    local function MakeSummaryValue(parent, x, y)
        local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("TOPLEFT", x, y)
        fs:SetText("0")
        fs:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
        return fs
    end

    local SUMMARY_X0 = 14
    local SUMMARY_STEP = 56
    local SUMMARY_CELL_W = 46

    local luaCol = KIND_COLORS.LuaError
    local warnCol = KIND_COLORS.Warning
    local debugCol = KIND_COLORS.Debug
    local taintCol = KIND_COLORS.Taint
    local uiCol = KIND_COLORS.UIError

    summaryBox.luaLabel = MakeSummaryLabel(summaryBox, "Lua", SUMMARY_X0 + SUMMARY_STEP * 0, -10)
    summaryBox.warnLabel = MakeSummaryLabel(summaryBox, "Warn", SUMMARY_X0 + SUMMARY_STEP * 1, -10)
    summaryBox.debugLabel = MakeSummaryLabel(summaryBox, "Debug", SUMMARY_X0 + SUMMARY_STEP * 2, -10)
    summaryBox.taintLabel = MakeSummaryLabel(summaryBox, "Taint", SUMMARY_X0 + SUMMARY_STEP * 3, -10)
    summaryBox.uiLabel = MakeSummaryLabel(summaryBox, "Blizz", SUMMARY_X0 + SUMMARY_STEP * 4, -10)

    summaryBox.luaLabel:SetWidth(SUMMARY_CELL_W)
    summaryBox.warnLabel:SetWidth(SUMMARY_CELL_W)
    summaryBox.debugLabel:SetWidth(SUMMARY_CELL_W)
    summaryBox.taintLabel:SetWidth(SUMMARY_CELL_W)
    summaryBox.uiLabel:SetWidth(SUMMARY_CELL_W)
    summaryBox.luaLabel:SetJustifyH("CENTER")
    summaryBox.warnLabel:SetJustifyH("CENTER")
    summaryBox.debugLabel:SetJustifyH("CENTER")
    summaryBox.taintLabel:SetJustifyH("CENTER")
    summaryBox.uiLabel:SetJustifyH("CENTER")

    summaryBox.luaValue = MakeSummaryValue(summaryBox, SUMMARY_X0 + SUMMARY_STEP * 0, -34)
    summaryBox.warnValue = MakeSummaryValue(summaryBox, SUMMARY_X0 + SUMMARY_STEP * 1, -34)
    summaryBox.debugValue = MakeSummaryValue(summaryBox, SUMMARY_X0 + SUMMARY_STEP * 2, -34)
    summaryBox.taintValue = MakeSummaryValue(summaryBox, SUMMARY_X0 + SUMMARY_STEP * 3, -34)
    summaryBox.uiValue = MakeSummaryValue(summaryBox, SUMMARY_X0 + SUMMARY_STEP * 4, -34)

    summaryBox.luaValue:SetWidth(SUMMARY_CELL_W)
    summaryBox.warnValue:SetWidth(SUMMARY_CELL_W)
    summaryBox.debugValue:SetWidth(SUMMARY_CELL_W)
    summaryBox.taintValue:SetWidth(SUMMARY_CELL_W)
    summaryBox.uiValue:SetWidth(SUMMARY_CELL_W)
    summaryBox.luaValue:SetJustifyH("CENTER")
    summaryBox.warnValue:SetJustifyH("CENTER")
    summaryBox.debugValue:SetJustifyH("CENTER")
    summaryBox.taintValue:SetJustifyH("CENTER")
    summaryBox.uiValue:SetJustifyH("CENTER")
    summaryBox.luaValue:SetTextColor(luaCol[1], luaCol[2], luaCol[3])
    summaryBox.warnValue:SetTextColor(warnCol[1], warnCol[2], warnCol[3])
    summaryBox.debugValue:SetTextColor(debugCol[1], debugCol[2], debugCol[3])
    summaryBox.taintValue:SetTextColor(taintCol[1], taintCol[2], taintCol[3])
    summaryBox.uiValue:SetTextColor(uiCol[1], uiCol[2], uiCol[3])

    frame.summaryLabel = summaryBox
    local copyAllBtn
    local copyAllModeMenuFrame

    local function ShowCopyAllTooltip(button)
        if not button or not GameTooltip then return end
        local currentMode = GetCopyAllMode()
        GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
        GameTooltip:SetText("Copy All", 1, 0.82, 0)
        GameTooltip:AddLine("Left Click: Build grouped export in Inspector using current mode.", 1, 1, 1, true)
        GameTooltip:AddLine("Right Click: Choose LLM-Ready or User Friendly.", 1, 1, 1, true)
        GameTooltip:AddLine("Current Mode: " .. CopyAllModeLabel(currentMode), 0.35, 0.85, 1.00, true)
        if currentMode == COPYALL_MODE_LLM then
            GameTooltip:AddLine("LLM-Ready: chaptered packet (Triage, Context, Groups, Variant Cards).", 0.60, 0.85, 1.00, true)
        else
            GameTooltip:AddLine("User Friendly: grouped human-readable digest with no AI blocks.", 0.60, 0.85, 1.00, true)
        end
        GameTooltip:Show()
    end

    local function CopyAllToDetail(trigger)
        BuildFiltered()
        local dbCount = (M.db and M.db.errors and #M.db.errors) or 0
        local filteredCount = #filtered
        local filteredDebugCount = CountEntriesByKind(filtered, "Debug")
        local searchLabel = NormalizeInlineText(searchText or "", 120)
        local addonLabel = NormalizeInlineText(addonFilter or "All Addons", 80)
        local sessionLabel = NormalizeInlineText(sessionFilter or "all", 40)
        local selectedBefore = selectedIndex or 0
        local copyMode = GetCopyAllMode()
        local triggerLabel = NormalizeInlineText(trigger or "left_click", 40)
        local text, formatToken = BuildCompactCopyAllText(filtered, addonFilter, copyMode)
        local setOk, requestedLen, actualLen, okSet, mode = ShowCopyAllInInspector(text)
        TraceCopyAll(string.format(
            "copy_all_click format=%s profile=%s trigger=%s addon=%s session=%s search=\"%s\" selected=%d dbTotal=%d filtered=%d filteredDebug=%d totalChars=%d setOk=%s okSet=%s mode=%s requested=%d actual=%d copyAllActive=%s",
            NormalizeInlineText(formatToken or "unknown", 40),
            NormalizeInlineText(copyMode, 24),
            triggerLabel,
            addonLabel,
            sessionLabel,
            searchLabel,
            selectedBefore,
            dbCount,
            filteredCount,
            filteredDebugCount,
            #text,
            tostring(setOk),
            tostring(okSet),
            tostring(mode or "raw"),
            requestedLen,
            actualLen,
            tostring(frame and frame._muiCopyAllActive == true)
        ))
    end

    local function ApplyCopyAllMode(nextMode, source)
        local normalized = SetCopyAllMode(nextMode)
        TraceCopyAll(string.format(
            "copy_all_mode_set mode=%s source=%s",
            NormalizeInlineText(normalized, 24),
            NormalizeInlineText(source or "menu", 24)
        ))
        local hoverRefresh = false
        if copyAllBtn and copyAllBtn.IsMouseOver then
            local okHover, isHover = pcall(copyAllBtn.IsMouseOver, copyAllBtn)
            hoverRefresh = okHover and isHover == true
        end
        local ownedRefresh = false
        if copyAllBtn and GameTooltip and GameTooltip.IsOwned then
            ownedRefresh = GameTooltip:IsOwned(copyAllBtn)
        end
        if copyAllBtn and (hoverRefresh or ownedRefresh) then
            ShowCopyAllTooltip(copyAllBtn)
        end
        CopyAllToDetail("mode_switch")
    end

    local function ShowCopyAllModeMenu(anchor)
        local current = GetCopyAllMode()
        if not EasyMenu then
            local nextMode = (current == COPYALL_MODE_LLM) and COPYALL_MODE_USER or COPYALL_MODE_LLM
            ApplyCopyAllMode(nextMode, "fallback_toggle")
            return
        end
        if not copyAllModeMenuFrame then
            copyAllModeMenuFrame = CreateFrame("Frame", "MidnightUI_CopyAllModeMenu", UIParent, "UIDropDownMenuTemplate")
        end
        local menu = {
            {
                text = "Copy All Mode",
                isTitle = true,
                notCheckable = true,
            },
            {
                text = "LLM-Ready",
                checked = current == COPYALL_MODE_LLM,
                func = function()
                    ApplyCopyAllMode(COPYALL_MODE_LLM, "menu")
                end,
            },
            {
                text = "User Friendly",
                checked = current == COPYALL_MODE_USER,
                func = function()
                    ApplyCopyAllMode(COPYALL_MODE_USER, "menu")
                end,
            },
        }
        EasyMenu(menu, copyAllModeMenuFrame, "cursor", 0, 0, "MENU", 2)
    end

    local listTitle = listPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listTitle:SetPoint("LEFT", listPane, "TOPLEFT", 12, -21)
    listTitle:SetText("Issue Stream")
    listTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    CreateHelpIcon(listPane, listTitle, "Issue Stream", {
        "|cffffd200What this does|r",
        "This table updates from captured diagnostics in saved history.",
        "Click any row to inspect the full report.",
        " ",
        "|cffffd200Group By Signature|r collapses repeated patterns.",
        "|cffffd200Bucket View|r summarizes repeated signatures across sessions.",
        "|cff00ccffTip|r: search and addon filters apply before rows are listed here.",
    })

    copyAllBtn = CreateFrame("Button", nil, listPane, "UIPanelButtonTemplate")
    copyAllBtn:SetSize(92, 22)
    copyAllBtn:SetPoint("TOPRIGHT", listPane, "TOPRIGHT", -12, -10)
    copyAllBtn:SetText("Copy All")
    StyleButton(copyAllBtn)
    copyAllBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    copyAllBtn:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ShowCopyAllModeMenu(self)
            return
        end
        CopyAllToDetail("left_click")
    end)
    copyAllBtn:SetScript("OnEnter", function(self)
        ShowCopyAllTooltip(self)
    end)
    copyAllBtn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    local realCheck = CreateFrame("CheckButton", nil, listPane, "UICheckButtonTemplate")
    realCheck:SetPoint("CENTER", copyAllBtn, "CENTER", -310, 0)
    SetRefreshMode((M and M.view and M.view.refreshMode) or refreshMode)
    realCheck:SetChecked(refreshMode == "real")
    SetCheckLabel(realCheck, "Realtime")

    local delayedCheck = CreateFrame("CheckButton", nil, listPane, "UICheckButtonTemplate")
    delayedCheck:SetPoint("CENTER", copyAllBtn, "CENTER", -170, 0)
    delayedCheck:SetChecked(refreshMode ~= "real")
    SetCheckLabel(delayedCheck, "Delayed")

    realCheck:SetScript("OnClick", function(self)
        if not self:GetChecked() then
            if delayedCheck then delayedCheck:SetChecked(true) end
            return
        end
        if delayedCheck then delayedCheck:SetChecked(false) end
        SetRefreshMode("real")
        M.Refresh()
    end)

    delayedCheck:SetScript("OnClick", function(self)
        if not self:GetChecked() then
            if realCheck then realCheck:SetChecked(true) end
            return
        end
        if realCheck then realCheck:SetChecked(false) end
        SetRefreshMode("delayed")
        M.Refresh()
    end)

    local listHeader = CreateFrame("Frame", nil, listPane, "BackdropTemplate")
    listHeader:SetPoint("TOPLEFT", listPane, "TOPLEFT", 10, -52)
    listHeader:SetPoint("TOPRIGHT", listPane, "TOPRIGHT", -32, -52)
    listHeader:SetHeight(20)
    StyleFrame(listHeader, UI_COLORS.inset, UI_COLORS.border)

    local hdrType = listHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrType:SetPoint("LEFT", 8, 0)
    hdrType:SetText("Type")
    hdrType:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    hdrType:SetDrawLayer("OVERLAY", 2)

    local hdrAddon = listHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrAddon:SetPoint("LEFT", 118, 0)
    hdrAddon:SetText("Addon")
    hdrAddon:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    hdrAddon:SetDrawLayer("OVERLAY", 2)

    local hdrMessage = listHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrMessage:SetPoint("LEFT", 242, 0)
    hdrMessage:SetText("Message")
    hdrMessage:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    hdrMessage:SetDrawLayer("OVERLAY", 2)

    local hdrCount = listHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrCount:SetPoint("RIGHT", -86, 0)
    hdrCount:SetJustifyH("RIGHT")
    hdrCount:SetText("Count")
    hdrCount:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    hdrCount:SetDrawLayer("OVERLAY", 2)
    hdrCount:SetAlpha(1)

    local hdrTime = listHeader:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdrTime:SetPoint("RIGHT", -12, 0)
    hdrTime:SetJustifyH("RIGHT")
    hdrTime:SetText("Time")
    hdrTime:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    hdrTime:SetDrawLayer("OVERLAY", 2)
    hdrTime:SetAlpha(1)

    local scroll = CreateFrame("ScrollFrame", nil, listPane, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", listPane, "TOPLEFT", 0, -76)
    scroll:SetPoint("BOTTOMRIGHT", listPane, "BOTTOMRIGHT", -24, 12)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, ROW_HEIGHT, M.Refresh)
    end)
    frame.scroll = scroll

    frame._listRowTop = -78
    frame._listRowLeftInset = 10
    frame._listRowRightInset = 32
    frame._listBottomInset = 12

    local detailTitle = detailPane:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    detailTitle:SetPoint("TOPLEFT", 12, -10)
    detailTitle:SetText("Inspector")
    detailTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    CreateHelpIcon(detailPane, detailTitle, "Details", {
        "|cffffd200What this does|r",
        "Click any row to see the full report here.",
        " ",
        "|cffffd200Type|r is the category.",
        "|cffffd200Count|r shows repeats.",
        "|cffffd200Session|r shows when it happened.",
        "|cffffd200Signature|r is the grouping fingerprint.",
        "|cffffd200Addon|r is the best guess at the source.",
        " ",
        "|cffffd200Stack|r shows the file and line where it happened.",
        "|cffffd200Meta|r includes extra context like taint source.",
        "|cff00ccffTip|r: Use |cffffd200Copy|r or |cffffd200Copy All|r when sharing.",
    })

    local detailScroll = CreateFrame("ScrollFrame", nil, detailPane, "UIPanelScrollFrameTemplate")
    detailScroll:SetPoint("TOPLEFT", 8, -44)
    detailScroll:SetPoint("BOTTOMRIGHT", -30, 66)
    frame.detailScroll = detailScroll

    local detailBox = CreateFrame("EditBox", nil, detailScroll)
    detailBox:SetMultiLine(true)
    detailBox:SetMaxLetters(0)
    detailBox:SetFontObject("ChatFontNormal")
    detailBox:SetWidth(detailPane:GetWidth() - 46)
    detailBox:SetAutoFocus(false)
    detailBox:EnableMouse(true)
    if detailBox.SetWordWrap then
        detailBox:SetWordWrap(true)
    end
    detailBox:SetScript("OnTextChanged", function()
        UpdateDetailScrollbar()
    end)
    detailBox:SetScript("OnEscapePressed", detailBox.ClearFocus)
    detailScroll:SetScrollChild(detailBox)
    frame.detailBox = detailBox

    local copyAllScroll = CreateFrame("ScrollFrame", nil, detailPane, "UIPanelScrollFrameTemplate")
    copyAllScroll:SetPoint("TOPLEFT", 8, -44)
    copyAllScroll:SetPoint("BOTTOMRIGHT", -30, 66)
    copyAllScroll:Hide()
    frame.copyAllScroll = copyAllScroll

    local copyAllBox = CreateFrame("EditBox", nil, copyAllScroll)
    copyAllBox:SetMultiLine(true)
    copyAllBox:SetMaxLetters(0)
    copyAllBox:SetFontObject("ChatFontNormal")
    copyAllBox:SetWidth(detailPane:GetWidth() - 46)
    copyAllBox:SetAutoFocus(false)
    copyAllBox:EnableMouse(true)
    if copyAllBox.SetWordWrap then
        copyAllBox:SetWordWrap(true)
    end
    copyAllBox:SetScript("OnTextChanged", function(self)
        local h = self.GetStringHeight and self:GetStringHeight() or 1
        if h < 1 then h = 1 end
        if h > DETAIL_TEXT_MAX_HEIGHT then h = DETAIL_TEXT_MAX_HEIGHT end
        self:SetHeight(h + 20)
    end)
    copyAllBox:SetScript("OnEscapePressed", function()
        ClearCopyAllState("copy_escape")
    end)
    copyAllScroll:SetScrollChild(copyAllBox)
    frame.copyAllBox = copyAllBox

    local actionBar = CreateFrame("Frame", nil, detailPane)
    actionBar:SetPoint("BOTTOMLEFT", 8, 10)
    actionBar:SetPoint("BOTTOMRIGHT", -8, 10)
    actionBar:SetHeight(52)

    local function OnButtonClick(self)
        if not self.entryIndex then return end
        ClearCopyAllState("list_row_click")
        selectedIndex = self.entryIndex
        M.Refresh()
    end

    EnsureListButtonsCount(listPane, OnButtonClick)


    local copyBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    copyBtn:SetSize(124, 24)
    copyBtn:SetPoint("TOPLEFT", 0, 0)
    copyBtn:SetText("Copy")
    StyleButton(copyBtn)
    copyBtn:SetScript("OnClick", function()
        if frame and frame._muiCopyAllActive and frame.copyAllBox then
            frame.copyAllBox:SetFocus()
            frame.copyAllBox:HighlightText()
            return
        end
        BuildFiltered()
        if #filtered > 0 and (selectedIndex < 1 or selectedIndex > #filtered) then selectedIndex = 1 end
        local e = filtered[selectedIndex]
        if e and frame.detailBox then frame.detailBox:SetText(BuildEntryText(e)) end
        local text = frame.detailBox and (frame.detailBox:GetText() or "") or ""
        if text == "" or text:match("^No diagnostics captured%.?$") then return end
        frame.detailBox:SetFocus()
        frame.detailBox:HighlightText()
    end)

    local closeBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    closeBtn:SetSize(124, 24)
    closeBtn:SetPoint("LEFT", copyBtn, "RIGHT", 6, 0)
    closeBtn:SetText("Close")
    StyleButton(closeBtn)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    local clearSelectedBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    clearSelectedBtn:SetSize(124, 24)
    clearSelectedBtn:SetPoint("BOTTOMLEFT", 0, 0)
    clearSelectedBtn:SetText("Clear Selected")
    StyleButton(clearSelectedBtn)
    clearSelectedBtn:SetScript("OnClick", function()
        ClearSelectedIssue()
    end)

    local clearIssuesBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    clearIssuesBtn:SetSize(124, 24)
    clearIssuesBtn:SetPoint("LEFT", clearSelectedBtn, "RIGHT", 6, 0)
    clearIssuesBtn:SetText("Clear Issues")
    StyleButton(clearIssuesBtn)
    clearIssuesBtn:SetScript("OnClick", function()
        ClearAllIssuesOnly()
    end)

    local clearSessionsBtn = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
    clearSessionsBtn:SetSize(124, 24)
    clearSessionsBtn:SetPoint("LEFT", clearIssuesBtn, "RIGHT", 6, 0)
    clearSessionsBtn:SetText("Clear Sessions")
    StyleButton(clearSessionsBtn)
    clearSessionsBtn:SetScript("OnClick", function()
        ClearSessionsAndHistory()
    end)
    clearSessionsBtn:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Clear Sessions", 1, 0.82, 0)
        GameTooltip:AddLine("Hold |cffffd200Shift|r and click to clear saved history.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    clearSessionsBtn:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)

    _G.MidnightUI_DiagnosticsFrame = frame
    _G.MidnightUI_DiagnosticsLoadState = "ui_create_done"
    frame._muiCopyAllActive = false
    SetInspectorCopyMode(false)

    frame:SetScript("OnSizeChanged", function()
        if frame.detailBox and detailPane then
            frame.detailBox:SetWidth(detailPane:GetWidth() - 46)
        end
        if frame.copyAllBox and detailPane then
            frame.copyAllBox:SetWidth(detailPane:GetWidth() - 46)
        end
        EnsureListButtonsCount(listPane, OnButtonClick)
        M.Refresh()
    end)

    frame:SetScript("OnHide", function()
        ClearCopyAllState("frame_hide")
        frame._muiOpenCheckRan = nil
    end)
end

function M.Open()
    _G.MidnightUI_DiagnosticsLoadState = "open_start"
    if not frame then
        local ok, err = pcall(CreateUI)
        if not ok then
            _G.MidnightUI_DiagnosticsLastError = err
            return false, err
        end
    end
    if not frame then return end
    frame:SetParent(UIParent)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(999)
    frame:SetToplevel(true)
    frame:SetScale(1)
    frame:SetAlpha(1)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:Show()
    frame:Raise()
    if _G.MidnightUI_DiagnosticsStatusFrame and _G.MidnightUI_DiagnosticsStatusFrame.Hide then
        _G.MidnightUI_DiagnosticsStatusFrame:Hide()
    end
    if _G.MidnightUI_DiagnosticsFallbackFrame and _G.MidnightUI_DiagnosticsFallbackFrame.Hide then
        _G.MidnightUI_DiagnosticsFallbackFrame:Hide()
    end
    local ok = pcall(M.Refresh)
    if not ok then return false, "Refresh failed" end
    _G.MidnightUI_DiagnosticsLoadState = "open_done"
    return true
end

function M.IsEnabled()
    local s = _G.MidnightUISettings
    return s and s.General and s.General.diagnosticsEnabled
end

function M.Refresh()
    if not frame then return end
    DrainQueuedDiagnostics()
    if not M.filter then
        M.filter = {
            LuaError = true,
            Warning = true,
            UIError = true,
            Debug = true,
            TaintInferred = true,
            TaintExplicit = true,
        }
    end
    if M.view then
        searchText = NormalizeSearch(M.view.searchText or "")
        sessionFilter = M.view.sessionFilter or "all"
    end
    EnsureSessionButtons()
    EnsureAddonButtons()
    BuildFiltered()
    UpdateListButtons()
    UpdateDetails()
    UpdateSummary()
    UpdateDetailScrollbar()
    if frame.countLabel then
        frame.countLabel:SetText(string.format("Entry %d of %d", selectedIndex, #filtered))
    end
end

-- =========================================================================
--  Events
-- =========================================================================

local events = {}
local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, ...) if events[event] then events[event](events, event, ...) end end)
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
eventFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
eventFrame:RegisterEvent("LUA_WARNING")
-- UI_ERROR_MESSAGE intentionally not registered: it fires for normal
-- gameplay messages (cooldowns, out-of-range, etc.) which are not errors.
_G.MidnightUI_DiagnosticsLoadState = "events_registered"

function events:ADDON_LOADED(_, name)
    if name ~= "MidnightUI" then return end
    EnsureSettings()
    EnsureDB()
    PruneSuppressedDebugEntries()
    DrainQueuedDiagnostics()
    SuppressScriptErrors()
end

function events:PLAYER_LOGIN()
    if not M.IsEnabled() then return end
    InstallErrorHandler()
    -- Deferred summary: after loading is done, report any warnings from this session.
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(3, function()
            if not M.db or not M.db.errors then return end
            local session = M.db.session or 0
            local warnCount = 0
            local firstMsg = nil
            for i = 1, #M.db.errors do
                local e = M.db.errors[i]
                if e and e.kind == "Warning" and e.session == session then
                    warnCount = warnCount + (e.count or 1)
                    if not firstMsg then firstMsg = e.message end
                end
            end
            if warnCount > 0 and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
                local safe = type(firstMsg) == "string" and firstMsg:gsub("|", "||") or "unknown"
                if #safe > 200 then safe = safe:sub(1, 200) .. "..." end
                DEFAULT_CHAT_FRAME:AddMessage(string.format(
                    "|cffffcc00[MidnightUI Diagnostics]|r %d warning(s) this session. Latest: %s",
                    warnCount, safe
                ))
                DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00[MidnightUI Diagnostics]|r Open the Debug tab or type |cff00ccff/mui diag|r to inspect.")
            end
        end)
    end
end

function events:ADDON_ACTION_FORBIDDEN(event, addonName, action)
    if not M.IsEnabled() then return end
    OnTaint(event, addonName, action)
end
events.ADDON_ACTION_BLOCKED = events.ADDON_ACTION_FORBIDDEN

function events:LUA_WARNING(event, warningText, pre11_1_5warningText)
    if not M.IsEnabled() then return end
    OnLuaWarning(event, warningText, pre11_1_5warningText)
end

function events:UI_ERROR_MESSAGE(event, message)
    if not M.IsEnabled() then return end
    OnUiError(event, message)
end

_G.MidnightUI_DiagnosticsLoadState = "loaded"

-- Slash command to open diagnostics UI
SlashCmdList.MidnightUIDiagnostics = function() M.Open() end
SLASH_MidnightUIDiagnostics1 = "/muibugs"
SLASH_MidnightUIDiagnostics2 = "/midnightbugs"

-- =========================================================================
--  MEMORY PROFILER (/muimemory)
-- =========================================================================

-- Helper: inject a raw entry into the Diagnostics console, bypassing all filters
local function InjectDiagEntry(message, sig)
    if not M.db then
        M.db = _G.MidnightUIDiagnosticsDB or {}
        _G.MidnightUIDiagnosticsDB = M.db
        M.db.errors = M.db.errors or {}
        M.db.session = M.db.session or 1
        M.db.context = M.db.context or {}
    end
    if not M.index then M.index = {} end
    local ts = time()
    local key = "Debug::" .. (sig or "inject") .. "::" .. ts
    local entry = {
        key = key, kind = "Debug", message = tostring(message),
        stack = "", locals = "", meta = "source=MemoryProfiler",
        sig = sig or "inject", addon = "MidnightUI",
        session = M.db.session or 0, contextId = M.db.session or 0,
        firstSeen = ts, lastSeen = ts, count = 1,
    }
    M.index[key] = entry
    M.db.errors[#M.db.errors + 1] = entry
    return entry
end

-- =====================================================================
--  PROFILER UTILITIES
-- =====================================================================

local function CountTableKeys(t)
    if type(t) ~= "table" then return 0 end
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function FormatKB(kb)
    if kb >= 1024 then return string.format("%.2f MB", kb / 1024) end
    return string.format("%.1f KB", kb)
end

local function FormatBytes(bytes)
    if bytes >= 1048576 then return string.format("%.2f MB", bytes / 1048576) end
    if bytes >= 1024 then return string.format("%.1f KB", bytes / 1024) end
    return string.format("%d B", bytes)
end

local function IsMUIFrameName(cname)
    if type(cname) ~= "string" then return false end
    return cname:find("MidnightUI") or cname:find("MUI_") or cname:find("Midnight")
end

-- Estimate byte cost of a single Lua value (heuristic, not exact)
-- Lua internals: table header ~56B, each hash slot ~40B, string header ~40+len
local function EstimateValueBytes(v, vtype)
    vtype = vtype or type(v)
    if vtype == "number" then return 8
    elseif vtype == "boolean" then return 4
    elseif vtype == "string" then return 40 + #v
    elseif vtype == "nil" then return 0
    end
    return 16 -- function, userdata, etc
end

-- Deep table analysis: returns {keys, nestedTables, estimatedBytes, strings, numbers,
-- booleans, functions, maxDepth, stringBytes, duplicateStrings}
local function DeepTableAnalysis(t, visited, depth, stats)
    if type(t) ~= "table" then return stats end
    visited = visited or {}
    depth = depth or 0
    if not stats then
        stats = {
            keys = 0, nestedTables = 0, estimatedBytes = 0,
            strings = 0, numbers = 0, booleans = 0, functions = 0,
            maxDepth = 0, stringBytes = 0, stringIndex = {},
            duplicateStrings = 0, duplicateStringBytes = 0,
            arrayPortion = 0, hashPortion = 0,
        }
    end
    if visited[t] or depth > 12 then return stats end
    visited[t] = true
    if depth > stats.maxDepth then stats.maxDepth = depth end

    -- Table header overhead (~56 bytes)
    stats.estimatedBytes = stats.estimatedBytes + 56

    -- Count array vs hash portions
    local arrayLen = #t
    stats.arrayPortion = stats.arrayPortion + arrayLen

    for k, v in pairs(t) do
        stats.keys = stats.keys + 1
        -- Each slot costs ~40 bytes (key+value+next pointer)
        stats.estimatedBytes = stats.estimatedBytes + 40

        -- Analyze key
        local ktype = type(k)
        stats.estimatedBytes = stats.estimatedBytes + EstimateValueBytes(k, ktype)
        if ktype == "string" then
            stats.strings = stats.strings + 1
            local klen = 40 + #k
            stats.stringBytes = stats.stringBytes + klen
            if stats.stringIndex[k] then
                stats.duplicateStrings = stats.duplicateStrings + 1
                stats.duplicateStringBytes = stats.duplicateStringBytes + klen
            end
            stats.stringIndex[k] = true
        end

        -- Analyze value
        local vtype = type(v)
        if vtype == "table" then
            stats.nestedTables = stats.nestedTables + 1
            if not visited[v] then
                DeepTableAnalysis(v, visited, depth + 1, stats)
            end
        elseif vtype == "string" then
            stats.strings = stats.strings + 1
            local vlen = 40 + #v
            stats.stringBytes = stats.stringBytes + vlen
            stats.estimatedBytes = stats.estimatedBytes + vlen
            if stats.stringIndex[v] then
                stats.duplicateStrings = stats.duplicateStrings + 1
                stats.duplicateStringBytes = stats.duplicateStringBytes + vlen
            end
            stats.stringIndex[v] = true
        elseif vtype == "number" then
            stats.numbers = stats.numbers + 1
            stats.estimatedBytes = stats.estimatedBytes + 8
        elseif vtype == "boolean" then
            stats.booleans = stats.booleans + 1
            stats.estimatedBytes = stats.estimatedBytes + 4
        elseif vtype == "function" then
            stats.functions = stats.functions + 1
            stats.estimatedBytes = stats.estimatedBytes + 128 -- closure overhead
        else
            stats.estimatedBytes = stats.estimatedBytes + 16
        end
    end
    stats.hashPortion = stats.keys - stats.arrayPortion
    return stats
end

-- Scan top-level keys of a table and return per-key size breakdown
local function TableKeyBreakdown(t, maxEntries)
    maxEntries = maxEntries or 15
    if type(t) ~= "table" then return {} end
    local results = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            local okA, st = pcall(function()
                return DeepTableAnalysis(v)
            end)
            if okA and st then
                results[#results + 1] = {
                    name = tostring(k),
                    keys = st.keys,
                    nested = st.nestedTables,
                    bytes = st.estimatedBytes,
                    strings = st.strings,
                    maxDepth = st.maxDepth,
                }
            end
        end
    end
    table.sort(results, function(a, b) return a.bytes > b.bytes end)
    if #results > maxEntries then
        local trimmed = {}
        for i = 1, maxEntries do trimmed[i] = results[i] end
        return trimmed
    end
    return results
end

-- =====================================================================
--  PROFILER MAIN
-- =====================================================================

local function RunMemoryProfiler()
    local ok, err = pcall(function()
        -- Force GC before measuring so we get settled memory, not garbage-inflated numbers
        pcall(collectgarbage, "collect")
        pcall(collectgarbage, "collect") -- second pass catches weak-ref resurrection
        UpdateAddOnMemoryUsage()

        local muiMemPostGC = nil -- set later by GC section
        local L = {} -- lines accumulator
        local function W(s) L[#L + 1] = s end
        local function WF(...) L[#L + 1] = string.format(...) end
        local function WBlank() L[#L + 1] = "" end
        local function WHeader(title) WBlank(); W("=== " .. title .. " ===") end
        local function WSubHeader(title) WBlank(); W("--- " .. title .. " ---") end

        W("================================================================")
        W("  MIDNIGHTUI DEEP MEMORY PROFILER")
        W("  Snapshot: " .. (date and date("%Y-%m-%d %H:%M:%S") or "unknown"))
        W("================================================================")

        -- ==============================================================
        --  1. LUA HEAP
        -- ==============================================================
        WHeader("1. LUA HEAP OVERVIEW")
        local gcOk, gcKB = pcall(collectgarbage, "count")
        if gcOk and type(gcKB) == "number" then
            W("Total Lua Heap: " .. FormatKB(gcKB))
        else
            W("Total Lua Heap: (restricted)")
        end

        -- ==============================================================
        --  2. ALL ADDONS RANKED
        -- ==============================================================
        WHeader("2. ALL ADDONS BY MEMORY")

        local numAddons = C_AddOns and C_AddOns.GetNumAddOns and C_AddOns.GetNumAddOns() or 0
        local addonMemData = {}
        local totalAddonMem = 0
        local muiMem = 0

        for i = 1, numAddons do
            local nameOk, addonName = pcall(C_AddOns.GetAddOnInfo, i)
            if nameOk and addonName then
                local loadedOk, loaded = pcall(C_AddOns.IsAddOnLoaded, i)
                if loadedOk and loaded then
                    local memOk, mem = pcall(GetAddOnMemoryUsage, i)
                    mem = (memOk and type(mem) == "number") and mem or 0
                    totalAddonMem = totalAddonMem + mem
                    if addonName == "MidnightUI" then muiMem = mem end
                    addonMemData[#addonMemData + 1] = { name = addonName, mem = mem }
                end
            end
        end
        table.sort(addonMemData, function(a, b) return a.mem > b.mem end)

        W("Total Addon Memory: " .. FormatKB(totalAddonMem))
        W("Loaded Addons: " .. #addonMemData)
        WBlank()
        for i, d in ipairs(addonMemData) do
            local pct = totalAddonMem > 0 and (d.mem / totalAddonMem * 100) or 0
            local marker = (d.name == "MidnightUI") and " <<<" or ""
            WF("  %2d. %-30s %10s  (%5.1f%%)" .. marker, i, d.name, FormatKB(d.mem), pct)
        end

        -- ==============================================================
        --  3. SAVEDVARIABLES DEEP DIVE
        -- ==============================================================
        WHeader("3. SAVEDVARIABLES DEEP ANALYSIS")
        W("MidnightUI Total: " .. FormatKB(muiMem))

        local svTables = {
            { name = "MidnightUIAchCache",       ref = _G.MidnightUIAchCache },
            { name = "MessengerDB",              ref = _G.MessengerDB },
            { name = "MidnightUISettings",       ref = _G.MidnightUISettings },
            { name = "MidnightUIDiagnosticsDB",  ref = _G.MidnightUIDiagnosticsDB },
        }

        for _, sv in ipairs(svTables) do
            if sv.ref and type(sv.ref) == "table" then
                WSubHeader(sv.name)
                local aOk, stats = pcall(function() return DeepTableAnalysis(sv.ref) end)
                if aOk and stats then
                    WF("  Total Keys:          %d", stats.keys)
                    WF("  Nested Tables:       %d", stats.nestedTables)
                    WF("  Estimated Size:      %s", FormatBytes(stats.estimatedBytes))
                    WF("  Max Nesting Depth:   %d", stats.maxDepth)
                    WF("  Strings:             %d  (%s)", stats.strings, FormatBytes(stats.stringBytes))
                    WF("  Numbers:             %d", stats.numbers)
                    WF("  Booleans:            %d", stats.booleans)
                    WF("  Functions:           %d", stats.functions)
                    if stats.duplicateStrings > 0 then
                        WF("  Duplicate Strings:   %d  (%s wasted)", stats.duplicateStrings, FormatBytes(stats.duplicateStringBytes))
                    end

                    -- Top-level key breakdown
                    local breakdown = TableKeyBreakdown(sv.ref, 15)
                    if #breakdown > 0 then
                        WBlank()
                        W("  Top sub-tables by estimated size:")
                        for bi, b in ipairs(breakdown) do
                            WF("    %2d. %-26s %10s  %5d keys  depth=%d", bi, b.name, FormatBytes(b.bytes), b.keys, b.maxDepth)
                        end
                    end
                else
                    W("  (error scanning: " .. tostring(stats) .. ")")
                end
            else
                WSubHeader(sv.name)
                W("  (nil or not a table)")
            end
        end

        -- ==============================================================
        --  4. GLOBAL TABLES
        -- ==============================================================
        WHeader("4. GLOBAL MUI TABLES")
        local globalProbes = {
            "MidnightUI_Core", "MidnightUI_Diagnostics", "MidnightUI_DiagnosticsQueue",
            "MidnightUI_Market", "MidnightUI_AchievementsPanel",
        }
        for _, gName in ipairs(globalProbes) do
            local ref = _G[gName]
            if ref and type(ref) == "table" then
                local gOk, stats = pcall(function() return DeepTableAnalysis(ref) end)
                if gOk and stats then
                    WF("  %-36s %10s  %5d keys  %4d tables  depth=%d",
                        gName, FormatBytes(stats.estimatedBytes), stats.keys, stats.nestedTables, stats.maxDepth)
                end
            end
        end

        -- ==============================================================
        --  5. FRAME CENSUS (DEEP)
        -- ==============================================================
        WHeader("5. FRAME CENSUS")

        local muiFrameCount = 0
        local muiShown = 0
        local muiHidden = 0
        local muiWithOnUpdate = 0
        local strataCount = {}
        local totalTextures = 0
        local totalFontStrings = 0
        local totalRegions = 0
        local onUpdateFrames = {}
        local framesByPrefix = {}

        local function ScanChildren(parent, depth)
            if not parent or depth > 6 then return end
            local scanOk, children = pcall(function() return { parent:GetChildren() } end)
            if not scanOk or not children then return end
            for _, child in ipairs(children) do
                local childOk, forbidden = pcall(function() return child:IsForbidden() end)
                if childOk and not forbidden then
                    local nameOk2, cname = pcall(function() return child:GetName() end)
                    if nameOk2 and IsMUIFrameName(cname) then
                        muiFrameCount = muiFrameCount + 1
                        local shownOk, shown = pcall(function() return child:IsShown() end)
                        if shownOk and shown then muiShown = muiShown + 1 else muiHidden = muiHidden + 1 end

                        -- OnUpdate tracking
                        local ouOk, hasOU = pcall(function() return child:GetScript("OnUpdate") ~= nil end)
                        if ouOk and hasOU then
                            muiWithOnUpdate = muiWithOnUpdate + 1
                            onUpdateFrames[#onUpdateFrames + 1] = cname
                        end

                        -- Strata
                        local strOk, strata = pcall(function() return child:GetFrameStrata() end)
                        if strOk and strata then strataCount[strata] = (strataCount[strata] or 0) + 1 end

                        -- Region census (textures, fontstrings)
                        local regOk, regions = pcall(function() return { child:GetRegions() } end)
                        if regOk and regions then
                            for _, region in ipairs(regions) do
                                local rtOk, rtype = pcall(function() return region:GetObjectType() end)
                                if rtOk then
                                    totalRegions = totalRegions + 1
                                    if rtype == "Texture" then totalTextures = totalTextures + 1
                                    elseif rtype == "FontString" then totalFontStrings = totalFontStrings + 1
                                    end
                                end
                            end
                        end

                        -- Group by prefix for module attribution
                        local prefix = cname:match("^([%a_]+)")
                        if prefix then
                            framesByPrefix[prefix] = (framesByPrefix[prefix] or 0) + 1
                        end
                    end
                    ScanChildren(child, depth + 1)
                end
            end
        end
        ScanChildren(UIParent, 0)

        WF("Named MUI Frames:    %d", muiFrameCount)
        WF("  Currently Shown:   %d", muiShown)
        WF("  Currently Hidden:  %d", muiHidden)
        WF("  With OnUpdate:     %d", muiWithOnUpdate)
        WF("  Total Regions:     %d", totalRegions)
        WF("    Textures:        %d", totalTextures)
        WF("    FontStrings:     %d", totalFontStrings)

        if next(strataCount) then
            WBlank()
            W("  By Strata:")
            local strataOrder = {"BACKGROUND","LOW","MEDIUM","HIGH","DIALOG","FULLSCREEN","FULLSCREEN_DIALOG","TOOLTIP"}
            for _, s in ipairs(strataOrder) do
                if strataCount[s] then WF("    %-24s %d", s, strataCount[s]) end
            end
        end

        -- Frames by module prefix
        WBlank()
        W("  Frames by Module Prefix:")
        local prefixList = {}
        for prefix, count in pairs(framesByPrefix) do
            prefixList[#prefixList + 1] = { name = prefix, count = count }
        end
        table.sort(prefixList, function(a, b) return a.count > b.count end)
        for _, p in ipairs(prefixList) do
            WF("    %-30s %d", p.name, p.count)
        end

        -- OnUpdate frames listed
        if #onUpdateFrames > 0 then
            WBlank()
            W("  Frames with Active OnUpdate:")
            for _, fname in ipairs(onUpdateFrames) do
                WF("    - %s", fname)
            end
        end

        -- ==============================================================
        --  6. GARBAGE PRESSURE
        -- ==============================================================
        WHeader("6. GARBAGE PRESSURE TEST")
        W("(Note: GC was run at profiler start — this measures garbage generated DURING profiling)")
        local beforeOk, beforeKB = pcall(collectgarbage, "count")
        local collectOk2 = pcall(collectgarbage, "collect")
        local afterOk, afterKB = pcall(collectgarbage, "count")
        if beforeOk and collectOk2 and afterOk and type(beforeKB) == "number" and type(afterKB) == "number" then
            local freed = beforeKB - afterKB
            WF("Before GC:  %s", FormatKB(beforeKB))
            WF("After GC:   %s", FormatKB(afterKB))
            WF("Freed:      %s", FormatKB(freed))
            if freed > 1024 then
                W("VERDICT: SIGNIFICANT — profiler itself or concurrent addon activity generating >1MB garbage")
            elseif freed > 512 then
                W("VERDICT: Moderate. Some garbage from profiler scan itself.")
            else
                W("VERDICT: Low. Healthy.")
            end
            -- Re-measure addon memory after GC to get settled value
            UpdateAddOnMemoryUsage()
            local postGcOk, postGcMem = pcall(GetAddOnMemoryUsage, "MidnightUI")
            if postGcOk and type(postGcMem) == "number" then
                muiMemPostGC = postGcMem
                WF("MUI Memory (post-GC):  %s  (vs %s pre-GC)", FormatKB(postGcMem), FormatKB(muiMem))
                WF("GC reclaimed from MUI: %s", FormatKB(muiMem - postGcMem))
            end
        else
            W("(collectgarbage restricted - GC test skipped)")
        end

        -- ==============================================================
        --  7. SETTINGS BREAKDOWN
        -- ==============================================================
        if _G.MidnightUISettings and type(_G.MidnightUISettings) == "table" then
            WHeader("7. SETTINGS MODULE BREAKDOWN")
            local modules = {}
            for k, v in pairs(_G.MidnightUISettings) do
                if type(v) == "table" then
                    local mOk, st = pcall(function() return DeepTableAnalysis(v) end)
                    if mOk and st then
                        modules[#modules + 1] = { name = k, keys = st.keys, nested = st.nestedTables, bytes = st.estimatedBytes }
                    end
                end
            end
            table.sort(modules, function(a, b) return a.bytes > b.bytes end)
            for _, m in ipairs(modules) do
                WF("  %-28s %8s  %4d keys  %3d tables", m.name, FormatBytes(m.bytes), m.keys, m.nested)
            end
        end

        -- ==============================================================
        --  8. DIAGNOSTICS DB
        -- ==============================================================
        WHeader("8. DIAGNOSTICS DB")
        if M.db then
            local errorCount = M.db.errors and #M.db.errors or 0
            local indexCount = M.index and CountTableKeys(M.index) or 0
            local contextCount = M.db.context and CountTableKeys(M.db.context) or 0
            WF("  Captured entries:   %d", errorCount)
            WF("  Index keys:         %d", indexCount)
            WF("  Context snapshots:  %d", contextCount)
            WF("  Session counter:    %d", M.db.session or 0)
            if M.db.errors and #M.db.errors > 0 then
                local dbOk, dbStats = pcall(function() return DeepTableAnalysis(M.db) end)
                if dbOk and dbStats then
                    WF("  DB estimated size:  %s", FormatBytes(dbStats.estimatedBytes))
                end
            end
        else
            W("  (db not initialized)")
        end

        -- ==============================================================
        --  9. ACHCACHE STRUCTURE ANALYSIS
        -- ==============================================================
        if _G.MidnightUIAchCache and type(_G.MidnightUIAchCache) == "table" then
            WHeader("9. ACHCACHE STRUCTURE DEEP DIVE")
            local topKeys = {}
            local sampleEntries = 0
            local totalAchEntries = 0
            local entryFieldCounts = {}

            for k, v in pairs(_G.MidnightUIAchCache) do
                if type(v) == "table" then
                    local kOk, kSt = pcall(function() return DeepTableAnalysis(v) end)
                    if kOk and kSt then
                        topKeys[#topKeys + 1] = { name = tostring(k), keys = kSt.keys, nested = kSt.nestedTables, bytes = kSt.estimatedBytes, depth = kSt.maxDepth }
                    end
                    -- Sample first few entries to understand schema
                    if sampleEntries < 3 then
                        sampleEntries = sampleEntries + 1
                        local sampleLines = {}
                        local sCount = 0
                        local totalKeys = CountTableKeys(v)
                        for sk, sv in pairs(v) do
                            sCount = sCount + 1
                            if sCount > 10 then
                                sampleLines[#sampleLines + 1] = "      ... (" .. (totalKeys - 10) .. " more)"
                                break
                            end
                            local svType = type(sv)
                            if svType == "table" then
                                sampleLines[#sampleLines + 1] = string.format("      %s = table(%d keys)", tostring(sk), CountTableKeys(sv))
                            else
                                local val = tostring(sv)
                                if #val > 60 then val = val:sub(1, 57) .. "..." end
                                sampleLines[#sampleLines + 1] = string.format("      %s = [%s] %s", tostring(sk), svType, val)
                            end
                        end
                        if #sampleLines > 0 then
                            WF("  Sample entry [%s]:", tostring(k))
                            for _, sl in ipairs(sampleLines) do W(sl) end
                        end
                    end
                    totalAchEntries = totalAchEntries + 1
                else
                    topKeys[#topKeys + 1] = { name = tostring(k), keys = 0, nested = 0, bytes = EstimateValueBytes(v), depth = 0 }
                end
            end

            WBlank()
            WF("  Total top-level entries: %d", totalAchEntries)
            table.sort(topKeys, function(a, b) return a.bytes > b.bytes end)
            WBlank()
            W("  Largest sub-tables:")
            for i = 1, math.min(20, #topKeys) do
                local tk = topKeys[i]
                WF("    %2d. %-24s %10s  %5d keys  %4d tables  depth=%d", i, tk.name, FormatBytes(tk.bytes), tk.keys, tk.nested, tk.depth)
            end
        end

        -- ==============================================================
        --  10. MESSENGERDB STRUCTURE ANALYSIS
        -- ==============================================================
        if _G.MessengerDB and type(_G.MessengerDB) == "table" then
            WHeader("10. MESSENGERDB STRUCTURE DEEP DIVE")
            local topKeys = {}
            local sampleEntries = 0

            for k, v in pairs(_G.MessengerDB) do
                if type(v) == "table" then
                    local kOk, kSt = pcall(function() return DeepTableAnalysis(v) end)
                    if kOk and kSt then
                        topKeys[#topKeys + 1] = { name = tostring(k), keys = kSt.keys, nested = kSt.nestedTables, bytes = kSt.estimatedBytes, strings = kSt.strings, depth = kSt.maxDepth }
                    end
                    -- Sample structure
                    if sampleEntries < 2 then
                        sampleEntries = sampleEntries + 1
                        local sampleLines = {}
                        local sCount = 0
                        for sk, sv in pairs(v) do
                            sCount = sCount + 1
                            if sCount > 8 then
                                sampleLines[#sampleLines + 1] = "      ... (" .. (CountTableKeys(v) - 8) .. " more)"
                                break
                            end
                            local svType = type(sv)
                            if svType == "table" then
                                sampleLines[#sampleLines + 1] = string.format("      %s = table(%d keys)", tostring(sk), CountTableKeys(sv))
                            else
                                local val = tostring(sv)
                                if #val > 60 then val = val:sub(1, 57) .. "..." end
                                sampleLines[#sampleLines + 1] = string.format("      %s = [%s] %s", tostring(sk), svType, val)
                            end
                        end
                        if #sampleLines > 0 then
                            WF("  Sample entry [%s]:", tostring(k))
                            for _, sl in ipairs(sampleLines) do W(sl) end
                        end
                    end
                else
                    local val = tostring(v)
                    if #val > 50 then val = val:sub(1, 47) .. "..." end
                    topKeys[#topKeys + 1] = { name = tostring(k), keys = 0, nested = 0, bytes = EstimateValueBytes(v), strings = 0, depth = 0 }
                end
            end

            WBlank()
            table.sort(topKeys, function(a, b) return a.bytes > b.bytes end)
            W("  Sub-tables by estimated size:")
            for i, tk in ipairs(topKeys) do
                WF("    %2d. %-24s %10s  %5d keys  %4d tables  %5d strings  depth=%d",
                    i, tk.name, FormatBytes(tk.bytes), tk.keys, tk.nested, tk.strings or 0, tk.depth)
            end
        end

        -- ==============================================================
        --  11. FRAME OBJECT OVERHEAD ESTIMATION
        -- ==============================================================
        WHeader("11. FRAME OBJECT OVERHEAD")
        W("(C-side memory per UI object — not visible to Lua table scans)")
        WBlank()

        -- Known per-object costs in WoW's UI engine (empirical estimates)
        -- Frame: ~2KB base (C struct + Lua proxy table + event table + scripts hash)
        -- Texture: ~800B (C struct + texture ref + coords + vertex color)
        -- FontString: ~600B (C struct + font ref + text buffer + shadow/outline state)
        -- AnimationGroup: ~400B
        local FRAME_COST = 2048
        local TEXTURE_COST = 800
        local FONTSTRING_COST = 600

        local estFrameMem = muiFrameCount * FRAME_COST
        local estTextureMem = totalTextures * TEXTURE_COST
        local estFontStringMem = totalFontStrings * FONTSTRING_COST
        local estTotalFrameOverhead = estFrameMem + estTextureMem + estFontStringMem

        WF("  Named Frames:   %4d x ~%s = %s", muiFrameCount, FormatBytes(FRAME_COST), FormatBytes(estFrameMem))
        WF("  Direct Textures: %4d x ~%s = %s", totalTextures, FormatBytes(TEXTURE_COST), FormatBytes(estTextureMem))
        WF("  Direct FS:       %4d x ~%s = %s", totalFontStrings, FormatBytes(FONTSTRING_COST), FormatBytes(estFontStringMem))
        WF("  NAMED-ONLY OVERHEAD:       %s", FormatBytes(estTotalFrameOverhead))
        W("  (See section 13 for deep scan including unnamed children)")

        -- ==============================================================
        --  12. CLOSURE & BYTECODE ANALYSIS
        -- ==============================================================
        WHeader("12. CLOSURE & BYTECODE ANALYSIS")
        WBlank()

        local hasDebugLib = type(debug) == "table" and type(debug.getinfo) == "function"
        local muiFunctions = 0
        local muiAllFunctions = 0
        local muiUpvalues = 0
        local bytecodeBySrc = {}
        local functionVisited = {}

        local function AnalyzeFunction(fn)
            if type(fn) ~= "function" or functionVisited[fn] then return end
            functionVisited[fn] = true
            muiAllFunctions = muiAllFunctions + 1

            if not hasDebugLib then return end
            local infoOk, info = pcall(debug.getinfo, fn, "Su")
            if not infoOk or not info then return end
            local src = info.source or ""
            if not (src:find("MidnightUI") or src:find("Midnight")) then return end

            muiFunctions = muiFunctions + 1
            local nups = info.nups or 0
            muiUpvalues = muiUpvalues + nups

            local filename = src:match("([^/\\]+%.lua)$") or src
            if not bytecodeBySrc[filename] then
                bytecodeBySrc[filename] = { funcs = 0, lines = 0, upvalues = 0 }
            end
            bytecodeBySrc[filename].funcs = bytecodeBySrc[filename].funcs + 1
            bytecodeBySrc[filename].upvalues = bytecodeBySrc[filename].upvalues + nups
            local lineSpan = 0
            if info.lastlinedefined and info.linedefined and info.lastlinedefined > 0 then
                lineSpan = info.lastlinedefined - info.linedefined + 1
            end
            bytecodeBySrc[filename].lines = bytecodeBySrc[filename].lines + lineSpan
        end

        -- Scan all reachable functions from globals and tracked tables
        local closureScanVisited = {}
        local function ScanForFunctions(t, depth)
            if type(t) ~= "table" or depth > 6 then return end
            if closureScanVisited[t] then return end
            closureScanVisited[t] = true
            local iterOk, iter = pcall(pairs, t)
            if not iterOk then return end
            local stepOk, k, v = pcall(iter, t, nil)
            while stepOk and k ~= nil do
                if type(v) == "function" then
                    AnalyzeFunction(v)
                elseif type(v) == "table" then
                    ScanForFunctions(v, depth + 1)
                end
                if type(k) == "function" then
                    AnalyzeFunction(k)
                end
                stepOk, k, v = pcall(iter, t, k)
            end
            local mtOk, mt = pcall(getmetatable, t)
            if mtOk and mt and type(mt) == "table" then
                ScanForFunctions(mt, depth + 1)
            end
        end

        ScanForFunctions(_G, 0)
        for _, sv in ipairs(svTables) do
            if sv.ref then ScanForFunctions(sv.ref, 0) end
        end
        for _, gName in ipairs(globalProbes) do
            local ref = _G[gName]
            if ref and type(ref) == "table" then ScanForFunctions(ref, 0) end
        end

        local CLOSURE_BASE = 128
        local UPVALUE_COST = 16
        local BYTECODE_PER_LINE = 4
        local estClosureMem = 0
        local estBytecodeMem = 0

        -- Known MUI source line counts (from codebase analysis, ~98,600 total)
        -- Used as fallback when debug library is unavailable
        local KNOWN_MUI_SOURCE_LINES = 98600
        local KNOWN_MUI_FILE_SIZES = {
            { name = "Messenger.lua",        lines = 6400 },
            { name = "PartyFrames.lua",       lines = 6900 },
            { name = "AchievementsPanel.lua", lines = 5200 },
            { name = "BagBar.lua",            lines = 3600 },
            { name = "TargetFrame.lua",       lines = 4400 },
            { name = "Diagnostics.lua",       lines = 4900 },
            { name = "FocusFrame.lua",        lines = 4200 },
            { name = "RaidFrames.lua",        lines = 3900 },
            { name = "PlayerFrame.lua",       lines = 2400 },
            { name = "Map.lua",               lines = 3100 },
            { name = "QuestInterface.lua",    lines = 2800 },
            { name = "ActionBars.lua",        lines = 2100 },
            { name = "Minimap.lua",           lines = 2900 },
            { name = "Nameplates.lua",        lines = 2500 },
            { name = "MainTankFrames.lua",    lines = 3300 },
            { name = "Settings.lua",          lines = 1800 },
            { name = "Settings_UI.lua",       lines = 1600 },
            { name = "LootWindow.lua",        lines = 1900 },
            { name = "CastBar.lua",           lines = 1100 },
            { name = "ConsumableBars.lua",    lines = 1300 },
            { name = "PetFrame.lua",          lines = 1000 },
            { name = "Other (combined)",      lines = 31300 },
        }

        if hasDebugLib then
            W("  (debug library available — per-file analysis active)")
            estClosureMem = (muiFunctions * CLOSURE_BASE) + (muiUpvalues * UPVALUE_COST)
            local totalSourceLines = 0
            for _, data in pairs(bytecodeBySrc) do
                totalSourceLines = totalSourceLines + data.lines
            end
            estBytecodeMem = totalSourceLines * BYTECODE_PER_LINE

            WF("  MUI Functions Found:   %d", muiFunctions)
            WF("  Total Upvalues:        %d", muiUpvalues)
            WF("  Est. Closure Memory:   %s", FormatBytes(estClosureMem))
            WF("  Source Lines Spanned:  %d", totalSourceLines)
            WF("  Est. Bytecode Memory:  %s", FormatBytes(estBytecodeMem))
            WF("  TOTAL CODE OVERHEAD:   %s", FormatBytes(estClosureMem + estBytecodeMem))

            WBlank()
            W("  Top files by estimated code size:")
            local fileList = {}
            for filename, data in pairs(bytecodeBySrc) do
                local fb = (data.funcs * CLOSURE_BASE) + (data.upvalues * UPVALUE_COST) + (data.lines * BYTECODE_PER_LINE)
                fileList[#fileList + 1] = { name = filename, funcs = data.funcs, upvalues = data.upvalues, lines = data.lines, bytes = fb }
            end
            table.sort(fileList, function(a, b) return a.bytes > b.bytes end)
            for i = 1, math.min(15, #fileList) do
                local f = fileList[i]
                WF("    %-30s %8s  %4d funcs  %5d upvals  %5d lines",
                    f.name, FormatBytes(f.bytes), f.funcs, f.upvalues, f.lines)
            end
        else
            W("  (debug library not available — using static estimates)")
            WF("  Reachable Functions (all addons): %d", muiAllFunctions)
            WBlank()

            -- Estimate bytecode from known file sizes
            -- Each source line compiles to ~20-40 bytes of bytecode in Lua 5.1
            -- Plus each file has ~50 closures average with ~3 upvalues each
            local BYTECODE_PER_LINE_EST = 32
            estBytecodeMem = KNOWN_MUI_SOURCE_LINES * BYTECODE_PER_LINE_EST
            -- Estimate ~2500 closures across the addon (empirical for this codebase size)
            local EST_CLOSURES = 2500
            local EST_UPVALS_PER = 4
            estClosureMem = (EST_CLOSURES * CLOSURE_BASE) + (EST_CLOSURES * EST_UPVALS_PER * UPVALUE_COST)

            WF("  Known MUI Source Lines:  %d", KNOWN_MUI_SOURCE_LINES)
            WF("  Est. Bytecode Memory:    %s  (%d lines x %dB/line)",
                FormatBytes(estBytecodeMem), KNOWN_MUI_SOURCE_LINES, BYTECODE_PER_LINE_EST)
            WF("  Est. Closures:           ~%d  (~%d upvalues each)", EST_CLOSURES, EST_UPVALS_PER)
            WF("  Est. Closure Memory:     %s", FormatBytes(estClosureMem))
            WF("  TOTAL CODE ESTIMATE:     %s", FormatBytes(estClosureMem + estBytecodeMem))

            WBlank()
            W("  Estimated bytecode by file (from known line counts):")
            for i, f in ipairs(KNOWN_MUI_FILE_SIZES) do
                local fb = f.lines * BYTECODE_PER_LINE_EST
                WF("    %-30s %8s  (%d lines)", f.name, FormatBytes(fb), f.lines)
            end

        end

        -- ==============================================================
        --  13. MUI DEEP DESCENDANT SCAN
        -- ==============================================================
        WHeader("13. MUI DEEP DESCENDANT SCAN")
        W("(Counting ALL children under each named MUI frame — named + unnamed)")
        WBlank()

        local muiTotalDescendants = 0
        local muiTotalDescTextures = 0
        local muiTotalDescFontStrings = 0
        local muiTotalDescAnimGroups = 0
        local descendantsByPrefix = {}

        -- Count all descendants of a frame recursively (named AND unnamed)
        local function CountDescendants(frame, stats, depth)
            if not frame or depth > 10 then return end
            local chOk, children = pcall(function() return { frame:GetChildren() } end)
            if chOk and children then
                for _, child in ipairs(children) do
                    local fOk, forbidden = pcall(function() return child:IsForbidden() end)
                    if fOk and not forbidden then
                        stats.frames = stats.frames + 1
                        -- Count regions on this child
                        local rOk, regions = pcall(function() return { child:GetRegions() } end)
                        if rOk and regions then
                            for _, region in ipairs(regions) do
                                local rtOk, rtype = pcall(function() return region:GetObjectType() end)
                                if rtOk then
                                    if rtype == "Texture" then stats.textures = stats.textures + 1
                                    elseif rtype == "FontString" then stats.fontstrings = stats.fontstrings + 1
                                    end
                                    stats.regions = stats.regions + 1
                                end
                            end
                        end
                        -- Count animation groups
                        local agOk, animGroups = pcall(function()
                            if child.GetAnimationGroups then return { child:GetAnimationGroups() } end
                            return nil
                        end)
                        if agOk and animGroups then
                            stats.animGroups = stats.animGroups + #animGroups
                        end
                        -- Check scripts
                        local ouOk, hasOU = pcall(function() return child:GetScript("OnUpdate") ~= nil end)
                        if ouOk and hasOU then stats.onUpdate = stats.onUpdate + 1 end
                        -- Recurse into children
                        CountDescendants(child, stats, depth + 1)
                    end
                end
            end
        end

        -- Scan each named MUI frame's full descendant tree
        local muiRootFrames = {}
        local function CollectMUIRoots(parent, depth)
            if not parent or depth > 6 then return end
            local scanOk4, children4 = pcall(function() return { parent:GetChildren() } end)
            if not scanOk4 or not children4 then return end
            for _, child in ipairs(children4) do
                local fOk2, forbidden2 = pcall(function() return child:IsForbidden() end)
                if fOk2 and not forbidden2 then
                    local nOk3, cname3 = pcall(function() return child:GetName() end)
                    if nOk3 and IsMUIFrameName(cname3) then
                        muiRootFrames[#muiRootFrames + 1] = { frame = child, name = cname3 }
                    end
                    CollectMUIRoots(child, depth + 1)
                end
            end
        end
        CollectMUIRoots(UIParent, 0)

        local ANIMGROUP_COST = 400
        local descByModule = {}
        for _, root in ipairs(muiRootFrames) do
            local stats = { frames = 0, textures = 0, fontstrings = 0, regions = 0, animGroups = 0, onUpdate = 0 }
            CountDescendants(root.frame, stats, 0)
            -- Also count the root's own regions
            local rrOk, rootRegions = pcall(function() return { root.frame:GetRegions() } end)
            if rrOk and rootRegions then
                for _, rr in ipairs(rootRegions) do
                    local rtOk2, rtype2 = pcall(function() return rr:GetObjectType() end)
                    if rtOk2 then
                        if rtype2 == "Texture" then stats.textures = stats.textures + 1
                        elseif rtype2 == "FontString" then stats.fontstrings = stats.fontstrings + 1
                        end
                        stats.regions = stats.regions + 1
                    end
                end
            end
            local agOk2, rootAG = pcall(function()
                if root.frame.GetAnimationGroups then return { root.frame:GetAnimationGroups() } end
                return nil
            end)
            if agOk2 and rootAG then stats.animGroups = stats.animGroups + #rootAG end

            muiTotalDescendants = muiTotalDescendants + stats.frames
            muiTotalDescTextures = muiTotalDescTextures + stats.textures
            muiTotalDescFontStrings = muiTotalDescFontStrings + stats.fontstrings
            muiTotalDescAnimGroups = muiTotalDescAnimGroups + stats.animGroups

            -- Aggregate by prefix
            local prefix = root.name:match("^([%a_]+)")
            if prefix then
                if not descByModule[prefix] then
                    descByModule[prefix] = { frames = 0, textures = 0, fontstrings = 0, animGroups = 0, onUpdate = 0, roots = 0 }
                end
                descByModule[prefix].roots = descByModule[prefix].roots + 1
                descByModule[prefix].frames = descByModule[prefix].frames + stats.frames
                descByModule[prefix].textures = descByModule[prefix].textures + stats.textures
                descByModule[prefix].fontstrings = descByModule[prefix].fontstrings + stats.fontstrings
                descByModule[prefix].animGroups = descByModule[prefix].animGroups + stats.animGroups
                descByModule[prefix].onUpdate = descByModule[prefix].onUpdate + stats.onUpdate
            end
        end

        local estMUIDescFrameOverhead = (muiFrameCount + muiTotalDescendants) * FRAME_COST
            + muiTotalDescTextures * TEXTURE_COST
            + muiTotalDescFontStrings * FONTSTRING_COST
            + muiTotalDescAnimGroups * ANIMGROUP_COST

        WF("  Named MUI Root Frames:     %d", muiFrameCount)
        WF("  Unnamed Child Frames:      %d", muiTotalDescendants)
        WF("  TOTAL MUI Frames:          %d", muiFrameCount + muiTotalDescendants)
        WF("  Total Textures (deep):     %d", muiTotalDescTextures)
        WF("  Total FontStrings (deep):  %d", muiTotalDescFontStrings)
        WF("  Total AnimationGroups:     %d", muiTotalDescAnimGroups)
        WF("  TOTAL MUI FRAME MEMORY:    %s", FormatBytes(estMUIDescFrameOverhead))

        WBlank()
        W("  Deep overhead by module (including all unnamed children):")
        local descModList = {}
        for prefix, data in pairs(descByModule) do
            local bytes = (data.roots + data.frames) * FRAME_COST
                + data.textures * TEXTURE_COST
                + data.fontstrings * FONTSTRING_COST
                + data.animGroups * ANIMGROUP_COST
            descModList[#descModList + 1] = {
                name = prefix, roots = data.roots, children = data.frames,
                textures = data.textures, fontstrings = data.fontstrings,
                animGroups = data.animGroups, onUpdate = data.onUpdate, bytes = bytes,
            }
        end
        table.sort(descModList, function(a, b) return a.bytes > b.bytes end)
        for i, d in ipairs(descModList) do
            if d.bytes >= 2048 then
                WF("    %-32s %8s  %3d roots  %4d children  %4d tex  %3d fs  %3d anim",
                    d.name, FormatBytes(d.bytes), d.roots, d.children,
                    d.textures, d.fontstrings, d.animGroups)
            end
        end

        -- Frames with active OnUpdate in descendants
        local totalDescOnUpdate = 0
        for _, d in ipairs(descModList) do totalDescOnUpdate = totalDescOnUpdate + d.onUpdate end
        if totalDescOnUpdate > 0 then
            WBlank()
            WF("  Unnamed children with OnUpdate: %d", totalDescOnUpdate)
            for _, d in ipairs(descModList) do
                if d.onUpdate > 0 then
                    WF("    %-32s %d OnUpdate scripts", d.name, d.onUpdate)
                end
            end
        end

        -- ==============================================================
        --  14. MEMORY ATTRIBUTION SUMMARY
        -- ==============================================================
        WHeader("14. MEMORY ATTRIBUTION SUMMARY")
        W("(Combining all estimation methods — deep frame scan included)")
        WBlank()

        local attrItems = {}
        local attrTotal = 0

        -- SV tables
        for _, sv in ipairs(svTables) do
            if sv.ref and type(sv.ref) == "table" then
                local aOk, st = pcall(function() return DeepTableAnalysis(sv.ref) end)
                if aOk and st then
                    attrItems[#attrItems + 1] = { name = sv.name .. " (SV)", bytes = st.estimatedBytes, category = "data" }
                    attrTotal = attrTotal + st.estimatedBytes
                end
            end
        end

        -- Global tables
        for _, gName in ipairs(globalProbes) do
            local ref = _G[gName]
            if ref and type(ref) == "table" then
                local gOk, st = pcall(function() return DeepTableAnalysis(ref) end)
                if gOk and st then
                    attrItems[#attrItems + 1] = { name = gName, bytes = st.estimatedBytes, category = "data" }
                    attrTotal = attrTotal + st.estimatedBytes
                end
            end
        end

        -- Deep frame overhead (replaces old named-only estimate)
        attrItems[#attrItems + 1] = { name = "MUI Frames (deep scan, all children)", bytes = estMUIDescFrameOverhead, category = "frames" }
        attrTotal = attrTotal + estMUIDescFrameOverhead

        -- Code overhead
        attrItems[#attrItems + 1] = { name = "Closures + Upvalues", bytes = estClosureMem, category = "code" }
        attrTotal = attrTotal + estClosureMem
        attrItems[#attrItems + 1] = { name = "Bytecode (compiled Lua)", bytes = estBytecodeMem, category = "code" }
        attrTotal = attrTotal + estBytecodeMem

        table.sort(attrItems, function(a, b) return a.bytes > b.bytes end)

        local catTotals = { data = 0, frames = 0, code = 0 }
        for _, item in ipairs(attrItems) do
            local pct = attrTotal > 0 and (item.bytes / attrTotal * 100) or 0
            WF("  %-42s %10s  (%5.1f%%)  [%s]", item.name, FormatBytes(item.bytes), pct, item.category)
            catTotals[item.category] = (catTotals[item.category] or 0) + item.bytes
        end
        WBlank()
        WF("  %-42s %10s", "Category: Data (tables/strings)", FormatBytes(catTotals.data))
        WF("  %-42s %10s", "Category: Frames (deep, all children)", FormatBytes(catTotals.frames))
        WF("  %-42s %10s", "Category: Code (bytecode/closures)", FormatBytes(catTotals.code))
        WBlank()
        WF("  %-42s %10s", "TOTAL ATTRIBUTED", FormatBytes(attrTotal))
        local effectiveMem = muiMemPostGC or muiMem
        WF("  %-42s %10s", "Reported Addon Memory (pre-GC)", FormatKB(muiMem))
        if muiMemPostGC then
            WF("  %-42s %10s", "Reported Addon Memory (post-GC)", FormatKB(muiMemPostGC))
        end
        WF("  %-42s %10s", "Using for attribution", FormatKB(effectiveMem))
        local unaccounted = (effectiveMem * 1024) - attrTotal
        if unaccounted > 0 then
            WF("  %-42s %10s  (%.1f%%)", "Still Unaccounted", FormatBytes(unaccounted), (unaccounted / (muiMem * 1024)) * 100)
            W("")
            W("  Remaining unaccounted sources:")
            W("    - Local variables and upvalue contents (captured by closures)")
            W("    - Lua string pool entries (interned by runtime)")
            W("    - C_Timer callback closures and ticker objects")
            W("    - Metatables and weak-reference tables")
            W("    - WoW API overhead (event registration, secure state)")
        elseif unaccounted < 0 then
            WF("  %-42s %10s", "Over-estimated by", FormatBytes(-unaccounted))
            W("  (Estimates exceed reported memory — frame cost multipliers may be high)")
        else
            W("  Memory fully accounted for.")
        end

        -- ==============================================================
        --  DONE
        -- ==============================================================
        WBlank()
        W("================================================================")
        W("  END OF DEEP MEMORY PROFILE")
        W("================================================================")

        local fullReport = table.concat(L, "\n")
        InjectDiagEntry(fullReport, "MemoryProfiler")
    end)

    if not ok then
        InjectDiagEntry("muimemory: profiler error: " .. tostring(err), "MemProfiler_Error")
    end
end

SlashCmdList.MidnightUIMemory = function()
    -- Run the profiler (injects entry via InjectDiagEntry)
    RunMemoryProfiler()
    -- Open and refresh AFTER all entries are injected
    pcall(M.Open)
    pcall(M.Refresh)
end
SLASH_MidnightUIMemory1 = "/muimemory"

return M
