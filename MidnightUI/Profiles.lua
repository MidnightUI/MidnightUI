--------------------------------------------------------------------------------
-- Profiles.lua | MidnightUI
-- PURPOSE: Profile import/export system — serializes, encodes, saves, and
--          restores the full MidnightUISettings table per character.
-- DEPENDS ON: MidnightUI_Diagnostics (optional, for debug logging),
--             MidnightUI_Settings (optional, for InitializeSettings on import),
--             MidnightUI_Core (optional, for InitModules on import)
-- EXPORTS: _G.MidnightUI_Profiles (module table with all public methods)
-- ARCHITECTURE: Standalone utility module. Called by Settings_UI for the
--   import/export panel and by Core on login/logout to auto-save snapshots.
--   Uses Base64-over-Lua-table serialization for the wire format ("MUI1:...").
--------------------------------------------------------------------------------
local _G = _G
local CreateFrame = CreateFrame
local date = date
local time = time
local type = type
local tostring = tostring
local pairs = pairs
local ipairs = ipairs
local table = table
local strfind = string.find
local strsub = string.sub
local strgsub = string.gsub
local tconcat = table.concat

-- ============================================================================
-- MODULE INITIALIZATION
-- ============================================================================
local M = _G.MidnightUI_Profiles or {}
_G.MidnightUI_Profiles = M

-- ============================================================================
-- INTERNAL HELPERS
-- ============================================================================

--- Log: Routes a debug message to the Diagnostics system if available,
--  otherwise falls back to the global debug print.
-- @param msg (string) - Message to log
-- @calls MidnightUI_Diagnostics.LogDebugSource
local function Log(msg)
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
        _G.MidnightUI_Diagnostics.LogDebugSource("Profiles", msg)
        return
    end
    if _G.MidnightUI_Debug then
        _G.MidnightUI_Debug("[Profiles] " .. tostring(msg))
    end
end

--- SafeToString: Protected tostring that handles tainted/restricted WoW values.
-- @param value (any) - Value to stringify
-- @return (string) - Safe string representation, or "[Restricted]" on failure
local function SafeToString(value)
    if value == nil then return "nil" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[Restricted]" end
    local ok2 = pcall(function() return s .. "" end)
    if not ok2 then return "[Restricted]" end
    return s
end

-- ============================================================================
-- SETTINGS STORE
-- Ensures _G.MidnightUISettings exists with required sub-tables.
-- Shape: { Profiles = { [charKey] = ProfileEntry }, WelcomeSeen = { [charKey] = bool }, ... }
-- ============================================================================

--- EnsureStore: Guarantees the global settings table and its Profiles/WelcomeSeen
--  sub-tables exist. Called before any profile read/write operation.
-- @return (table) - Reference to _G.MidnightUISettings
local function EnsureStore()
    _G.MidnightUISettings = _G.MidnightUISettings or {}
    local s = _G.MidnightUISettings
    if not s.Profiles then s.Profiles = {} end
    if not s.WelcomeSeen then s.WelcomeSeen = {} end
    if not s.WhatsNewSeen then s.WhatsNewSeen = {} end
    return s
end

-- ============================================================================
-- CHARACTER IDENTITY
-- ============================================================================

--- M.GetCharacterKey: Returns a unique "Name-Realm" key for the current player.
-- @return (string) - e.g. "Aaronbusch-Stormrage"
-- @calledby SaveCurrentProfile, MarkWelcomeSeen, HasSeenWelcome, Settings_UI
function M.GetCharacterKey()
    local name = (UnitName and UnitName("player")) or "Unknown"
    local realm = (GetRealmName and GetRealmName()) or "UnknownRealm"
    return name .. "-" .. realm
end

-- ============================================================================
-- SERIALIZATION / ENCODING
-- Converts Lua tables to portable strings and back.
-- Wire format: "MUI1:" prefix + Base64-encoded Lua table literal.
-- ============================================================================

--- DeepCopy: Recursively clones a table, skipping "Profiles" and "WelcomeSeen"
--  keys so that saved profiles do not nest the profile store itself.
-- @param src (any) - Value to copy
-- @param seen (table|nil) - Cycle-detection set (internal recursion state)
-- @return (any) - Deep-copied value
local function DeepCopy(src, seen)
    if type(src) ~= "table" then return src end
    if not seen then seen = {} end
    if seen[src] then return seen[src] end
    local dst = {}
    seen[src] = dst
    for k, v in pairs(src) do
        if k ~= "Profiles" and k ~= "WelcomeSeen" and k ~= "WhatsNewSeen" then
            dst[DeepCopy(k, seen)] = DeepCopy(v, seen)
        end
    end
    return dst
end

--- Serialize: Converts a Lua value into a Lua-syntax string that can be
--  loaded back with loadstring("return " .. serialized).
-- @param value (any) - Value to serialize
-- @param stack (table|nil) - Circular reference detection (internal)
-- @return (string) - Lua expression string
-- @note Handles NaN, +/-Inf, circular tables, arrays vs hashes.
local function Serialize(value, stack)
    local t = type(value)
    if t == "number" then
        if value ~= value then return "0" end
        if value == math.huge then return "1/0" end
        if value == -math.huge then return "-1/0" end
        return tostring(value)
    elseif t == "boolean" then
        return value and "true" or "false"
    elseif t == "string" then
        return string.format("%q", value)
    elseif t == "table" then
        stack = stack or {}
        if stack[value] then return "\"[Circular]\"" end
        stack[value] = true
        local isArray = (#value > 0)
        local parts = {}
        local index = 1
        for k, v in pairs(value) do
            local keyPart = ""
            if isArray and type(k) == "number" and k == index then
                index = index + 1
            else
                keyPart = "[" .. Serialize(k, stack) .. "]="
            end
            parts[#parts + 1] = keyPart .. Serialize(v, stack)
        end
        stack[value] = nil
        return "{" .. tconcat(parts, ",") .. "}"
    end
    return "nil"
end

--- B64: The Base64 alphabet used for profile encoding.
local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

--- Base64Encode: Encodes a binary/text string to Base64.
-- @param data (string) - Raw input
-- @return (string) - Base64-encoded output with trailing padding
local function Base64Encode(data)
    if not data or data == "" then return "" end
    return ((data:gsub(".", function(x)
        local r, b = "", x:byte()
        for i = 8, 1, -1 do
            r = r .. (b % 2^i - b % 2^(i-1) > 0 and "1" or "0")
        end
        return r
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
        if #x < 6 then return "" end
        local c = 0
        for i = 1, 6 do
            c = c + (x:sub(i,i) == "1" and 2^(6-i) or 0)
        end
        return B64:sub(c+1, c+1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

--- Base64Decode: Decodes a Base64 string back to its original form.
-- @param data (string) - Base64-encoded input (padding and whitespace tolerant)
-- @return (string) - Decoded output
local function Base64Decode(data)
    if not data or data == "" then return "" end
    data = data:gsub("[^" .. B64 .. "=]", "")
    return (data:gsub(".", function(x)
        if x == "=" then return "" end
        local r, f = "", (B64:find(x, 1, true) - 1)
        for i = 6, 1, -1 do
            r = r .. (f % 2^i - f % 2^(i-1) > 0 and "1" or "0")
        end
        return r
    end):gsub("%d%d%d?%d?%d?%d?%d?%d?", function(x)
        if #x ~= 8 then return "" end
        local c = 0
        for i = 1, 8 do
            c = c + (x:sub(i,i) == "1" and 2^(8-i) or 0)
        end
        return string.char(c)
    end))
end

-- ============================================================================
-- EXPORT / IMPORT
-- ============================================================================

--- BuildExportTable: Snapshots current settings (minus Profiles/WelcomeSeen).
-- @return (table) - Deep copy of MidnightUISettings for serialization
local function BuildExportTable()
    local s = EnsureStore()
    return DeepCopy(s)
end

--- M.ExportProfileString: Produces the full export string for the current settings.
-- @return (string) - Wire-format string prefixed with "MUI1:"
-- @calledby SaveCurrentProfile, Settings_UI export button
function M.ExportProfileString()
    local export = BuildExportTable()
    local serialized = Serialize(export)
    local encoded = Base64Encode(serialized)
    return "MUI1:" .. encoded
end

--- DecodeProfileString: Parses an import string back into a Lua table.
--  Accepts both "MUI1:"-prefixed Base64 and raw Lua table literals.
-- @param text (string) - The import payload
-- @return (table|nil) - Decoded settings table on success, nil on failure
-- @return (string|nil) - Error reason on failure
local function DecodeProfileString(text)
    if not text or text == "" then return nil, "empty" end
    local trimmed = strgsub(text, "%s+", "")
    if strsub(trimmed, 1, 5) == "MUI1:" then
        local payload = strsub(trimmed, 6)
        local decoded = Base64Decode(payload)
        if not decoded or decoded == "" then return nil, "decode_failed" end
        trimmed = decoded
    end
    local chunk, err = loadstring("return " .. trimmed)
    if not chunk then return nil, err or "load_failed" end
    local ok, res = pcall(chunk)
    if not ok then return nil, res or "parse_failed" end
    if type(res) ~= "table" then return nil, "invalid_table" end
    return res
end

--- WipeTable: Clears all keys from a table (uses Blizzard wipe() if available).
-- @param t (table|nil) - Table to wipe
local function WipeTable(t)
    if not t then return end
    if wipe then wipe(t); return end
    for k in pairs(t) do t[k] = nil end
end

--- ApplyProfileTable: Overwrites _G.MidnightUISettings with the imported data,
--  preserving the existing Profiles and WelcomeSeen sub-tables, then triggers
--  a full settings + module re-initialization.
-- @param profileTable (table) - The decoded profile data
-- @return (boolean) - true on success
-- @return (string|nil) - Error reason on failure
-- @calls MidnightUI_Settings.InitializeSettings, MidnightUI_Core.InitModules
local function ApplyProfileTable(profileTable)
    if type(profileTable) ~= "table" then return false, "invalid_table" end
    local s = EnsureStore()
    local preservedProfiles = s.Profiles
    local preservedWelcome = s.WelcomeSeen
    local preservedWhatsNew = s.WhatsNewSeen
    WipeTable(s)
    for k, v in pairs(profileTable) do
        s[k] = DeepCopy(v)
    end
    s.Profiles = preservedProfiles or {}
    s.WelcomeSeen = preservedWelcome or {}
    s.WhatsNewSeen = preservedWhatsNew or {}
    if _G.MidnightUI_Settings and _G.MidnightUI_Settings.InitializeSettings then
        _G.MidnightUI_Settings.InitializeSettings()
    end
    if _G.MidnightUI_Core and _G.MidnightUI_Core.InitModules then
        _G.MidnightUI_Core.InitModules("PROFILE_IMPORT")
    end
    return true
end

--- M.ImportProfileString: Decodes, validates, and applies an import string,
--  then auto-saves the result as the current character's profile.
-- @param text (string) - The "MUI1:..." import string or raw Lua table
-- @return (boolean) - true on success
-- @return (string|nil) - Error reason on failure
-- @calls DecodeProfileString, ApplyProfileTable, M.SaveCurrentProfile
-- @calledby ImportProfileFromKey, Settings_UI import button
function M.ImportProfileString(text)
    local tbl, err = DecodeProfileString(text)
    if not tbl then
        Log("Import failed: " .. SafeToString(err))
        return false, err
    end
    local ok, applyErr = ApplyProfileTable(tbl)
    if not ok then
        Log("Import apply failed: " .. SafeToString(applyErr))
        return false, applyErr
    end
    M.SaveCurrentProfile("import")
    Log("Import successful")
    return true
end

--- M.ImportProfileFromKey: Loads a previously saved profile by its character key.
-- @param key (string) - Character key, e.g. "Aaronbusch-Stormrage"
-- @return (boolean) - true on success
-- @return (string|nil) - Error reason on failure
-- @calls M.ImportProfileString
-- @calledby Settings_UI profile picker
function M.ImportProfileFromKey(key)
    local s = EnsureStore()
    local entry = s.Profiles and s.Profiles[key]
    if not entry or not entry.data then
        Log("Import missing entry for key=" .. SafeToString(key))
        return false, "missing_entry"
    end
    local ok, err = M.ImportProfileString(entry.data)
    if not ok then
        Log("Import from key failed: " .. SafeToString(err))
    end
    return ok, err
end

-- ============================================================================
-- PROFILE STORAGE
-- Saved profiles live in MidnightUISettings.Profiles[charKey].
-- ProfileEntry shape:
--   { data = "MUI1:...", name = "Aaronbusch", realm = "Stormrage",
--     classTag = "WARRIOR", level = 80, reason = "login"|"logout"|"import",
--     createdAt = timestamp, updatedAt = timestamp }
-- ============================================================================

--- M.SaveCurrentProfile: Snapshots the current settings into the Profiles store.
-- @param reason (string) - Why the save happened: "login", "logout", or "import"
-- @calledby ImportProfileString, OnProfileEvent (PLAYER_LOGIN/LOGOUT)
function M.SaveCurrentProfile(reason)
    local s = EnsureStore()
    local key = M.GetCharacterKey()
    local name = (UnitName and UnitName("player")) or "Unknown"
    local realm = (GetRealmName and GetRealmName()) or "UnknownRealm"
    local classTag = (select(2, UnitClass and UnitClass("player"))) or nil
    local level = (UnitLevel and UnitLevel("player")) or nil
    local now = time()
    local entry = s.Profiles[key] or {}
    if not entry.createdAt then entry.createdAt = now end
    entry.updatedAt = now
    entry.name = name
    entry.realm = realm
    entry.classTag = classTag
    entry.level = level
    entry.reason = reason
    entry.data = M.ExportProfileString()
    s.Profiles[key] = entry
end

--- M.GetProfileOptions: Returns a sorted list of available profiles for display
--  in the Settings UI dropdown, excluding the specified key.
-- @param excludeKey (string|nil) - Character key to omit (typically current char)
-- @return (table) - Array of { key = string, label = string, createdAt = number }
-- @calledby Settings_UI profile picker
function M.GetProfileOptions(excludeKey)
    local s = EnsureStore()
    local list = {}
    for key, entry in pairs(s.Profiles or {}) do
        if key ~= excludeKey and entry and entry.data then
            local label = SafeToString(entry.name or key)
            if entry.realm then label = label .. " - " .. SafeToString(entry.realm) end
            local created = entry.createdAt and date("%b %d, %Y", entry.createdAt) or "Unknown"
            label = label .. "  Created " .. created
            list[#list + 1] = { key = key, label = label, createdAt = entry.createdAt or 0 }
        end
    end
    table.sort(list, function(a, b) return (a.createdAt or 0) > (b.createdAt or 0) end)
    return list
end

-- ============================================================================
-- WELCOME FLAG
-- Tracks whether the first-run welcome dialog has been shown per character.
-- ============================================================================

--- M.MarkWelcomeSeen: Records that the current character has dismissed the welcome.
-- @calledby Settings_UI welcome dialog
function M.MarkWelcomeSeen()
    local s = EnsureStore()
    local key = M.GetCharacterKey()
    s.WelcomeSeen[key] = true
end

--- M.HasSeenWelcome: Checks whether the current character has seen the welcome.
-- @return (boolean)
-- @calledby Settings_UI, Core on login
function M.HasSeenWelcome()
    local s = EnsureStore()
    local key = M.GetCharacterKey()
    return s.WelcomeSeen[key] == true
end

--- M.MarkWhatsNewSeen: Records the addon version the player last saw What's New for.
-- @param version (string) - The addon version string (e.g., "1.8.2")
function M.MarkWhatsNewSeen(version)
    local s = EnsureStore()
    local key = M.GetCharacterKey()
    s.WhatsNewSeen[key] = version
end

--- M.HasSeenWhatsNew: Checks whether the player has already seen What's New for this version.
-- @param version (string) - The current addon version
-- @return (boolean)
function M.HasSeenWhatsNew(version)
    local s = EnsureStore()
    local key = M.GetCharacterKey()
    return s.WhatsNewSeen[key] == version
end

-- ============================================================================
-- EVENT FRAME
-- Auto-saves the profile on login and logout so there is always a recent
-- snapshot available for cross-character import.
-- ============================================================================

--- OnProfileEvent: Event handler for the profile auto-save frame.
-- @param event (string) - "PLAYER_LOGIN" or "PLAYER_LOGOUT"
-- @calls M.SaveCurrentProfile
local function OnProfileEvent(_, event)
    if event == "PLAYER_LOGIN" then
        M.SaveCurrentProfile("login")
    elseif event == "PLAYER_LOGOUT" then
        M.SaveCurrentProfile("logout")
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", OnProfileEvent)
