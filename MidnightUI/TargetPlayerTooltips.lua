-- =============================================================================
-- FILE PURPOSE:     World-mouseover tooltip hook. Intercepts any player unit tooltip
--                   shown by GameTooltip and replaces its content with the MidnightUI
--                   player info layout (via MidnightUI_PlayerTooltips.ReplaceMouseoverContent).
--                   Three hook layers are installed for robustness:
--                     1. TooltipDataProcessor.AddTooltipPostCall (primary — fires after Blizzard fills)
--                     2. hooksecurefunc(GameTooltip, "SetUnit") (fallback for older paths)
--                     3. UPDATE_MOUSEOVER_UNIT event + C_Timer.After(0) (belt-and-suspenders)
-- LOAD ORDER:       Loads after PlayerTooltips.lua, before ConditionBorder.lua. All three
--                   hooks install at file execution time. Guard _G.MidnightUI_TargetPlayerTooltipsHooked
--                   prevents double-install on /reload.
-- DEFINES:          _G.MidnightUI_TargetPlayerTooltipsHooked (boolean guard).
--                   mouseoverFrame (event frame for UPDATE_MOUSEOVER_UNIT).
-- READS:            MidnightUISettings.General.customTooltips — checked inside
--                   MidnightUI_PlayerTooltips.ReplaceMouseoverContent before replacing content.
-- WRITES:           Nothing persistent — only modifies live GameTooltip content.
-- DEPENDS ON:       MidnightUI_PlayerTooltips (_G.MidnightUI_PlayerTooltips set by PlayerTooltips.lua).
--                   TooltipDataProcessor.AddTooltipPostCall (Blizzard 9.x+ API).
--                   Enum.TooltipDataType.Unit (Blizzard enum, tested before use).
-- USED BY:          Nothing — pure hook; executes passively on any player unit mouseover.
-- GOTCHAS:
--   Unit token resolution has three fallback paths because data.unitToken is not always
--   populated (depends on tooltip trigger context): unitToken → tooltip:GetUnit() →
--   GUID match against "mouseover" → bare "mouseover" fallback.
--   The C_Timer.After(0) defer in UPDATE_MOUSEOVER_UNIT lets Blizzard finish populating
--   the tooltip before the content replacement runs.
--   All unit existence/player checks use SafeUnitExists/SafeUnitIsPlayer (pcall wrappers)
--   to handle tainted values in some action-bar mouseover contexts.
-- =============================================================================

local function SafeUnitExists(unit)
    local ok, result = pcall(UnitExists, unit)
    return ok and result == true
end

local function SafeUnitIsPlayer(unit)
    local ok, result = pcall(UnitIsPlayer, unit)
    return ok and result == true
end

local function ShouldHandleUnit(unit)
    if not unit or not SafeUnitExists(unit) then return false end
    if not SafeUnitIsPlayer(unit) then return false end
    return true
end

local function ReplaceTooltipContent(unit)
    if MidnightUISettings and MidnightUISettings.General
        and MidnightUISettings.General.customTooltips == false then
        return
    end
    if not ShouldHandleUnit(unit) then return end

    local PT = _G.MidnightUI_PlayerTooltips
    if not PT or not PT.ReplaceMouseoverContent then return end

    PT:ReplaceMouseoverContent(unit)
end

if not _G.MidnightUI_TargetPlayerTooltipsHooked then
    -- Primary: TooltipDataProcessor (fires after Blizzard populates the tooltip)
    if TooltipDataProcessor and Enum and Enum.TooltipDataType
        and Enum.TooltipDataType.Unit then
        TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit,
            function(tooltip, data)
                if tooltip ~= GameTooltip then return end

                local unit = data and data.unitToken
                if not unit then
                    local ok, _, hinted = pcall(tooltip.GetUnit, tooltip)
                    if ok then unit = hinted end
                end
                if not unit and data and data.guid and SafeUnitExists("mouseover") then
                    local ok, guid = pcall(UnitGUID, "mouseover")
                    if ok and guid == data.guid then
                        unit = "mouseover"
                    end
                end
                if not unit and SafeUnitExists("mouseover") then
                    unit = "mouseover"
                end
                ReplaceTooltipContent(unit)
            end)
    end

    -- Fallback: hook SetUnit directly
    if GameTooltip then
        hooksecurefunc(GameTooltip, "SetUnit", function(tooltip, unit)
            ReplaceTooltipContent(unit)
        end)
    end

    -- Belt-and-suspenders: UPDATE_MOUSEOVER_UNIT event
    local mouseoverFrame = CreateFrame("Frame")
    mouseoverFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
    mouseoverFrame:SetScript("OnEvent", function()
        if SafeUnitExists("mouseover") and SafeUnitIsPlayer("mouseover") then
            C_Timer.After(0, function()
                if SafeUnitExists("mouseover") and GameTooltip:IsShown() then
                    ReplaceTooltipContent("mouseover")
                end
            end)
        end
    end)

    _G.MidnightUI_TargetPlayerTooltipsHooked = true
end
