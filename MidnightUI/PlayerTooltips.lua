-- =============================================================================
-- FILE PURPOSE:     Player-unit tooltip content builder. Populates GameTooltip with
--                   MidnightUI-styled player info: name (class-colored), guild + rank,
--                   level (difficulty-colored), race, spec (self only), class, faction.
--                   Works alongside the Core.lua sigil system which handles visual chrome
--                   (dark background, accent stripe, corner brackets). This file handles
--                   the text content layer only.
-- LOAD ORDER:       Loads after ActionBars.lua, before TargetPlayerTooltips.lua. Note:
--                   ConditionBorder loads two positions after this file, not before it.
--                   PlayerTooltips is registered as _G.MidnightUI_PlayerTooltips at file end.
-- DEFINES:          _G.MidnightUI_PlayerTooltips (table with BuildContent, Show, Hide,
--                   ReplaceMouseoverContent methods).
-- READS:            MidnightUISettings.General.customTooltips — global enable gate.
--                   MidnightUI_Core.GetClassColor (preferred class color source).
--                   RAID_CLASS_COLORS (fallback when Core is not yet loaded).
-- WRITES:           GameTooltip._mui_unit — stores unit token on the tooltip frame so
--                   Core.lua's sigil system can resolve the accent color.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (optional; falls back to RAID_CLASS_COLORS).
--                   TargetPlayerTooltips.lua calls MidnightUI_PlayerTooltips.ReplaceMouseoverContent.
-- USED BY:          TargetPlayerTooltips.lua — world mouseover hook delegates content here.
--                   PlayerFrame.lua OnEnter — calls PlayerTooltips:Show(owner, "player").
-- KEY FLOWS:
--   PlayerFrame OnEnter → PlayerTooltips:Show(owner, unit) → BuildContent → GameTooltip:Show()
--   TargetPlayerTooltips hook fires → ReplaceMouseoverContent(unit) → BuildContent in-place
-- GOTCHAS:
--   BuildContent uses pcall on UnitExists and UnitIsPlayer because these can taint in
--   some protected frame contexts (e.g., during a secure action template callback).
--   Spec is only shown for "player" (self) — UnitGroupRolesAssigned doesn't expose
--   other players' specs through the API without an inspect first.
--   ReplaceMouseoverContent checks customTooltips setting before calling BuildContent,
--   so disabling custom tooltips in settings reverts all unit tooltips to Blizzard default.
-- =============================================================================

local PlayerTooltips = {}

local COLORS = {
    guild = {0.35, 0.85, 0.45},
    race = {0.85, 0.85, 0.85},
    classFallback = {0.5, 0.5, 0.5},
    label = {0.6, 0.6, 0.6},
    header = {0.35, 0.35, 0.35},
    faction = {
        Horde = {0.8, 0.2, 0.2},
        Alliance = {0.2, 0.4, 0.8},
        Neutral = {0.7, 0.7, 0.7},
    },
    levelFallback = {1, 1, 1},
}

local function GetClassColor(unit)
    if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
        return _G.MidnightUI_Core.GetClassColor(unit)
    end
    local _, classFile = UnitClass(unit)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        local c = RAID_CLASS_COLORS[classFile]
        return c.r, c.g, c.b
    end
    return COLORS.classFallback[1], COLORS.classFallback[2], COLORS.classFallback[3]
end

local function GetLevelColor(level)
    if not level or level <= 0 then
        return COLORS.levelFallback[1], COLORS.levelFallback[2], COLORS.levelFallback[3]
    end
    local c = GetQuestDifficultyColor(level)
    if c then return c.r, c.g, c.b end
    return COLORS.levelFallback[1], COLORS.levelFallback[2], COLORS.levelFallback[3]
end

local function GetFactionColor(unit)
    local faction = UnitFactionGroup(unit)
    if faction and COLORS.faction[faction] then
        local c = COLORS.faction[faction]
        return faction, c[1], c[2], c[3]
    end
    local c = COLORS.faction.Neutral
    return faction, c[1], c[2], c[3]
end

-- =========================================================================
--  TOOLTIP CONTENT BUILDER
--  Populates any GameTooltip-compatible frame with player unit information.
--  Returns true if content was built, false if the unit is invalid.
-- =========================================================================

function PlayerTooltips:BuildContent(tt, unit)
    if not tt or not unit then return false end
    local okExists, exists = pcall(UnitExists, unit)
    if not okExists or not exists then return false end
    local okPlayer, isPlayer = pcall(UnitIsPlayer, unit)
    if not okPlayer or not isPlayer then return false end

    tt:ClearLines()

    local name, realm = UnitName(unit)
    local fullName = name or UNKNOWN
    if realm and realm ~= "" then
        fullName = fullName .. "-" .. realm
    end

    local cr, cg, cb = GetClassColor(unit)
    tt:AddLine(fullName, cr, cg, cb)
    tt:AddLine(" ")

    local guildName, guildRank = GetGuildInfo(unit)
    if guildName and guildName ~= "" then
        local guildValue = guildName
        if guildRank and guildRank ~= "" then
            guildValue = guildName .. " (" .. guildRank .. ")"
        end
        tt:AddDoubleLine("Guild", guildValue,
            COLORS.label[1], COLORS.label[2], COLORS.label[3],
            COLORS.guild[1], COLORS.guild[2], COLORS.guild[3])
    end

    local level = UnitLevel(unit)
    local lr, lg, lb = GetLevelColor(level)
    if level and level > 0 then
        tt:AddDoubleLine("Level", tostring(level),
            COLORS.label[1], COLORS.label[2], COLORS.label[3], lr, lg, lb)
    else
        tt:AddDoubleLine("Level", UNKNOWN or "??",
            COLORS.label[1], COLORS.label[2], COLORS.label[3],
            COLORS.levelFallback[1], COLORS.levelFallback[2], COLORS.levelFallback[3])
    end

    local race = UnitRace(unit) or ""
    if race ~= "" then
        tt:AddDoubleLine("Race", race,
            COLORS.label[1], COLORS.label[2], COLORS.label[3],
            COLORS.race[1], COLORS.race[2], COLORS.race[3])
    end

    tt:AddLine(" ")

    -- Spec (self only — other players' specs aren't available via API)
    local okIsSelf, isSelf = pcall(UnitIsUnit, unit, "player")
    if okIsSelf and isSelf then
        if GetSpecialization and GetSpecializationInfo then
            local specIndex = GetSpecialization()
            if specIndex then
                local specName = select(2, GetSpecializationInfo(specIndex))
                if specName then
                    tt:AddDoubleLine("Spec", specName,
                        COLORS.label[1], COLORS.label[2], COLORS.label[3], cr, cg, cb)
                end
            end
        end
    end

    local className = select(1, UnitClass(unit))
    if className then
        tt:AddDoubleLine("Class", className,
            COLORS.label[1], COLORS.label[2], COLORS.label[3], cr, cg, cb)
    end

    local faction, fr, fg, fb = GetFactionColor(unit)
    if faction and faction ~= "" then
        tt:AddDoubleLine("Faction", faction,
            COLORS.label[1], COLORS.label[2], COLORS.label[3], fr, fg, fb)
    end

    -- Store unit for the sigil system's accent color detection
    tt._mui_unit = unit


    return true
end

-- =========================================================================
--  PUBLIC API
-- =========================================================================

--- Show the custom player tooltip anchored to an owner frame.
-- Used by PlayerFrame OnEnter and any explicit call sites.
function PlayerTooltips:Show(owner, unit, anchor)
    if not owner or not unit then return end
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_BOTTOMLEFT")
    if self:BuildContent(GameTooltip, unit) then
        GameTooltip:Show()
    else
        -- BuildContent failed (not a player unit) — fall back to Blizzard default
        GameTooltip:SetUnit(unit)
        GameTooltip:Show()
    end
end

--- Replace GameTooltip content for a world mouseover player unit.
-- Called from the TooltipDataProcessor hook and ApplySigil. Works WITH
-- GameTooltip instead of fighting it — just swaps the content in-place.
-- Uses GUID debounce so only the first call per target actually rebuilds;
-- subsequent hook calls for the same unit are no-ops.
function PlayerTooltips:ReplaceMouseoverContent(unit)
    if not unit then return end
    if MidnightUISettings and MidnightUISettings.General
        and MidnightUISettings.General.customTooltips == false then
        return
    end
    -- Debounce: skip if content was already built for this exact unit
    local guid = UnitGUID(unit)
    if guid and guid == GameTooltip._mui_custom_guid then return end
    if self:BuildContent(GameTooltip, unit) then
        GameTooltip._mui_custom_guid = guid
        GameTooltip:Show()
    end
end

--- Hide the tooltip.
function PlayerTooltips:Hide()
    GameTooltip:Hide()
end

_G.MidnightUI_PlayerTooltips = PlayerTooltips
