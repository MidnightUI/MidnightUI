-- =============================================================================
-- FILE PURPOSE:     M+ Performance Intelligence engine. Tracks Mythic+ run outcomes
--                   using C_DamageMeter (12.0+ API) and scores each player across five
--                   dimensions: Awareness, Survival, Output, Utility, Consistency.
--                   Role-specific weights (ROLE_WEIGHTS) adjust dimension importance.
--                   Aug Evoker detected separately (personal DPS is not their metric).
--                   Scores are tiered S/A/B/C/D, stored in MidnightUI_MPI SavedVariable,
--                   and surfaced in GroupFinder.lua applicant/listing rows.
-- LOAD ORDER:       Loads last — after all db/ files (db/mpi_sync.lua, db_mpi_*.lua).
--                   Standalone file. db/ files must be loaded first as they populate
--                   the reference database that MPI scoring normalizes against.
-- DEFINES:          MidnightUI_MPI (SavedVariable) — profiles[], runs[], version.
--                   SCORE_TIERS{} — {minScore, label, r, g, b} for S/A/B/C/D.
--                   ROLE_WEIGHTS{} — per-role dimension weight vectors (TANK/HEALER/DPS/AUG).
--                   KEY_BRACKETS{} — key level pressure tiers (+2-5, +6-9, +10-13, +14-17, +18+).
--                   MASTERY_LEVELS{} — MASTERED/COMFORTABLE/LEARNING thresholds per dungeon.
--                   BADGE_DEFS{} — earned badge types (ACTIVE_KICKER, CLEAN_RUN, TIMED_PLUS, etc.)
--                   MAX_RUNS = 100 — per-player run history cap.
--                   MAX_PROFILES = 500 — global player profile cap (LRU eviction).
--                   TREND_WINDOW = 5 — runs used for trend direction comparison.
--                   SCORE_WINDOW = 10 — runs used for Consistency dimension calculation.
-- READS:            C_DamageMeter.GetResults() — raw damage/heal/interrupt/death data per run.
--                   C_ChallengeMode.GetCompletionInfo() — key level, timed status, dungeon ID.
--                   UnitGUID, UnitName, UnitClass — player identity per group slot.
--                   db/db_mpi_us.lua, db/db_mpi_eu.lua, db/db_mpi_kr.lua, db/db_mpi_tw.lua —
--                   region score reference databases (loaded by db/ files before this).
--                   db/mpi_sync.lua — cross-session score sync helpers.
-- WRITES:           MidnightUI_MPI.profiles[guid] — per-player score history.
--                   MidnightUI_MPI.runs[] — completed run log (capped at MAX_RUNS).
-- DEPENDS ON:       C_DamageMeter (requires WoW 12.0+; absent on older clients — guarded).
--                   db/ files — must load before MidnightPI.lua to populate reference DB.
-- USED BY:          GroupFinder.lua — reads MidnightUI_MPI.profiles to overlay scores on
--                   premade group listing rows and applicant panels.
-- KEY FLOWS:
--   CHALLENGE_MODE_COMPLETED → CollectRunData() → C_DamageMeter.GetResults()
--   → ScoreRun(players, keyLevel, timed) → per-dimension scoring → ComputeWeightedScore()
--   → StoreProfile(guid, score) → MidnightUI_MPI.profiles[guid]
--   GroupFinder opens → ReadProfileScore(guid) → overlay tier badge on listing row
--   Tooltip hover → ShowMPIBreakdown(guid) — 5-dimension radar + trend + badge list
-- GOTCHAS:
--   C_DamageMeter is only available in WoW 12.0+ — all calls guarded with type() check.
--   On older clients, MPI silently skips scoring (no error, no data).
--   AUG_EVOKER_ICONS{} detected via specIconID from C_DamageMeter, not UnitClass.
--   MAX_PROFILES = 500: when exceeded, oldest-accessed profile is evicted (LRU).
--   TREND_WINDOW comparison uses last 5 vs previous 5 runs; needs at least 10 runs
--   for a meaningful trend — shown as "Insufficient data" below that threshold.
--   db/ reference databases are region-specific; mpi_sync.lua selects the active
--   region at startup via GetCurrentRegion().
-- NAVIGATION:
--   SCORE_TIERS{}          — S/A/B/C/D tier definitions (line ~37)
--   ROLE_WEIGHTS{}         — per-role dimension weights (line ~46)
--   KEY_BRACKETS{}         — key level pressure tiers (line ~60)
--   BADGE_DEFS{}           — earned badge definitions (line ~76)
--   CollectRunData()       — run outcome collector (search "function CollectRunData")
--   ComputeWeightedScore() — final score calculation (search "function ComputeWeightedScore")
-- =============================================================================

-- ============================================================================
-- §1  UPVALUES & CONSTANTS
-- ============================================================================
local ADDON_NAME = "MidnightUI"
local W8 = "Interface\\Buttons\\WHITE8X8"
local TITLE_FONT = "Fonts\\FRIZQT__.TTF"
local BODY_FONT  = "Fonts\\FRIZQT__.TTF"

local pcall, type, pairs, ipairs, math, string, table, select =
      pcall, type, pairs, ipairs, math, string, table, select
local tostring, tonumber, time, date, floor, ceil, min, max, abs, sqrt =
      tostring, tonumber, time, date, math.floor, math.ceil, math.min, math.max, math.abs, math.sqrt
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local GetTime, InCombatLockdown = GetTime, InCombatLockdown
local UnitGUID, UnitName, UnitClass, UnitLevel = UnitGUID, UnitName, UnitClass, UnitLevel
local UnitGroupRolesAssigned, GetNumGroupMembers = UnitGroupRolesAssigned, GetNumGroupMembers
local IsInGroup, IsInRaid, GetInstanceInfo = IsInGroup, IsInRaid, GetInstanceInfo
local GetSpecialization, GetSpecializationInfo = GetSpecialization, GetSpecializationInfo
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local strsplit = strsplit

local MPI_VERSION   = 1
local MAX_RUNS      = 100
local MAX_PROFILES  = 500
local TREND_WINDOW  = 5   -- compare last 5 to previous 5
local SCORE_WINDOW  = 10  -- last 10 scores for consistency calc

-- Score tier definitions: {minScore, label, r, g, b}
local SCORE_TIERS = {
    { 90, "S", 1.00, 0.84, 0.00 }, -- gold
    { 75, "A", 0.65, 0.55, 0.98 }, -- purple
    { 60, "B", 0.40, 0.70, 0.95 }, -- blue
    { 40, "C", 0.35, 0.88, 0.45 }, -- green
    {  0, "D", 1.00, 0.35, 0.35 }, -- red
}

-- Role weight tables: {awareness, survival, output, utility, consistency}
local ROLE_WEIGHTS = {
    TANK   = { 0.25, 0.20, 0.20, 0.20, 0.15 },
    HEALER = { 0.20, 0.15, 0.30, 0.20, 0.15 },
    DPS    = { 0.20, 0.15, 0.35, 0.15, 0.15 },
    -- Aug Evoker: Output reduced (personal DPS is not their primary contribution),
    -- freed weight distributed to dimensions they directly control.
    AUG    = { 0.25, 0.20, 0.15, 0.20, 0.20 },
}

-- Augmentation Evoker detection
local AUG_EVOKER_ICONS   = { [5198701] = true }  -- specIconID from C_DamageMeter
local AUG_EVOKER_SPEC_ID = 1473                   -- from GetSpecializationInfo

-- Key level brackets for pressure curve
local KEY_BRACKETS = {
    { 2,  5,  "+2-5"   },
    { 6,  9,  "+6-9"   },
    { 10, 13, "+10-13" },
    { 14, 17, "+14-17" },
    { 18, 99, "+18+"   },
}

-- Dungeon mastery thresholds
local MASTERY_LEVELS = {
    MASTERED    = { minTimedRuns = 5, minAvgScore = 70, label = "Mastered",    icon = "star_filled"  },
    COMFORTABLE = { minTimedRuns = 2, minAvgScore = 55, label = "Comfortable", icon = "star_half"    },
    LEARNING    = { minTimedRuns = 0, minAvgScore = 0,  label = "Learning",    icon = "star_empty"   },
}

-- Badge definitions
local BADGE_DEFS = {
    ACTIVE_KICKER  = { id = "AK", label = "Active Kicker",  desc = "12+ interrupts in a single run. Kicks save runs." },
    CLEAN_RUN      = { id = "CR", label = "Clean Run",      desc = "Zero deaths with under 5% avoidable damage taken." },
    TIMED_PLUS     = { id = "TP", label = "Timed+",         desc = "Timed the key with 2 or more stars." },
    IMPROVER       = { id = "IM", label = "Improver",        desc = "Recent scores trending upward. Growing as a player." },
    IRON_WILL      = { id = "IW", label = "Iron Will",      desc = "Finishes 95%+ of runs. This player sees it through." },
    DUNGEON_EXPERT = { id = "DE", label = "Dungeon Expert", desc = "Mastered 4 or more unique dungeons this season." },
}

local BADGE_ID_TO_KEY = {}
for k, v in pairs(BADGE_DEFS) do BADGE_ID_TO_KEY[v.id] = k end

-- ============================================================================
-- §2  MODULE TABLE & STATE
-- ============================================================================
local MPI = {}
MPI._ready        = false
MPI._apiAvailable = false
MPI._activeRun    = nil    -- set at CHALLENGE_MODE_START, cleared at completion
MPI._encounterLog = {}     -- per-boss tracking within a run
MPI._rosterSnapshot = {}   -- captured at run start for leaver detection
MPI._leavers      = {}     -- GUIDs that left mid-run
MPI._surrendered  = false  -- true if key was surrendered via vote (no penalties)
MPI._taggedThisSession = {} -- track tags set this session
MPI._heroPill     = nil    -- premade hero pill frame ref
MPI._dashboardBuilt = false
MPI._sidebarBuilt  = false

local db -- shorthand reference to _G.MidnightUI_MPI, set in EnsureDB

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2, r3, r4, r5, r6, r7, r8 = pcall(fn, ...)
    if not ok then return nil end
    return r1, r2, r3, r4, r5, r6, r7, r8
end

local function GetClassColor(classFile)
    if not classFile or classFile == "" or not RAID_CLASS_COLORS then return 0.8, 0.8, 0.8 end
    local cc = RAID_CLASS_COLORS[classFile]
    if cc then return cc.r, cc.g, cc.b end
    return 0.8, 0.8, 0.8
end

local function TrySetFont(fs, fontPath, size, flags)
    if not fs or not fs.SetFont then return end
    pcall(fs.SetFont, fs, fontPath or TITLE_FONT, size or 12, flags or "")
end

-- ============================================================================
-- §3  SAVED VARIABLE INITIALIZATION & DATA MANAGEMENT
-- ============================================================================

local DEFAULT_SETTINGS = {
    enabled       = true,
    showInHero    = true,
    showInRows    = true,
    showInSidebar = true,
    maxStoredRuns     = MAX_RUNS,
    maxStoredProfiles = MAX_PROFILES,
}

local DEFAULT_PERSONAL = {
    totalRuns      = 0,
    timedRuns      = 0,
    avgMPI         = 0,
    consistencyScore = 0,
    byDungeon      = {},
    weeklyRuns     = 0,
    weeklyTimedRuns = 0,
    weeklyAvgMPI   = 0,
    weekStart      = 0,
}

local function GetServerWeekStart()
    -- WoW weekly reset: Tuesday (US) / Wednesday (EU/KR/TW/CN)
    local now = time()
    local utc = date("!*t", now)
    -- Detect region: 1=US (Tuesday), everything else = Wednesday
    local resetDay = 3 -- Tuesday (wday: Sunday=1, Monday=2, Tuesday=3)
    if GetCurrentRegion then
        local ok, region = pcall(GetCurrentRegion)
        if ok and region and region ~= 1 then resetDay = 4 end -- Wednesday for non-US
    end
    local daysSinceReset = (utc.wday - resetDay) % 7
    local resetDate = now - (daysSinceReset * 86400)
    local t = date("!*t", resetDate)
    t.hour = 7; t.min = 0; t.sec = 0
    local resetTime = time(t)
    if resetTime > now then resetTime = resetTime - (7 * 86400) end
    return resetTime
end

function MPI.EnsureDB()
    if not _G.MidnightUI_MPI then
        _G.MidnightUI_MPI = {
            version    = MPI_VERSION,
            runs       = {},
            profiles   = {},
            personal   = {},
            settings   = {},
            _nameIndex = {},
        }
    end
    db = _G.MidnightUI_MPI

    -- Version migration
    db.version = db.version or MPI_VERSION

    -- Ensure subtables exist
    db.runs       = db.runs       or {}
    db.profiles   = db.profiles   or {}
    db.settings   = db.settings   or {}
    db._nameIndex = db._nameIndex or {}

    -- Fill default settings
    for k, v in pairs(DEFAULT_SETTINGS) do
        if db.settings[k] == nil then db.settings[k] = v end
    end

    -- Fill default personal stats
    if not db.personal or type(db.personal) ~= "table" then
        db.personal = {}
    end
    for k, v in pairs(DEFAULT_PERSONAL) do
        if db.personal[k] == nil then db.personal[k] = v end
    end
    db.personal.byDungeon = db.personal.byDungeon or {}

    -- Prune old runs
    while #db.runs > db.settings.maxStoredRuns do
        table.remove(db.runs) -- remove from end (oldest)
    end

    -- Prune old profiles (keep most recently seen)
    local profileCount = 0
    for _ in pairs(db.profiles) do profileCount = profileCount + 1 end
    if profileCount > db.settings.maxStoredProfiles then
        local sorted = {}
        for guid, prof in pairs(db.profiles) do
            sorted[#sorted + 1] = { guid = guid, lastSeen = prof.lastSeen or 0 }
        end
        table.sort(sorted, function(a, b) return a.lastSeen > b.lastSeen end)
        for i = db.settings.maxStoredProfiles + 1, #sorted do
            db.profiles[sorted[i].guid] = nil
        end
    end

    -- Reset weekly stats if stale
    local weekStart = GetServerWeekStart()
    if (db.personal.weekStart or 0) < weekStart then
        db.personal.weeklyRuns = 0
        db.personal.weeklyTimedRuns = 0
        db.personal.weeklyAvgMPI = 0
        db.personal.weekStart = weekStart
    end

    -- Rebuild name index
    MPI.RebuildNameIndex()
end

function MPI.RebuildNameIndex()
    if not db then return end
    db._nameIndex = {}
    for guid, prof in pairs(db.profiles) do
        if prof.name then
            db._nameIndex[prof.name] = guid
            -- Also index without realm if name contains a dash
            local shortName = prof.name:match("^([^%-]+)")
            if shortName and shortName ~= prof.name then
                -- Only set short name if not already taken (prefer exact match)
                if not db._nameIndex[shortName] then
                    db._nameIndex[shortName] = guid
                end
            end
        end
    end
end

-- Lookup a profile by name, trying local DB first, then community DB.
function MPI.LookupByName(name)
    if not db or not name then return nil, nil end
    -- Try local observations first (highest trust)
    local guid = db._nameIndex[name]
    if guid and db.profiles[guid] then return guid, db.profiles[guid] end
    -- Try without realm
    local shortName = name:match("^([^%-]+)")
    if shortName then
        guid = db._nameIndex[shortName]
        if guid and db.profiles[guid] then return guid, db.profiles[guid] end
    end
    -- Fall back to community database (companion app data)
    local communityProf = MPI.CommunityLookup(name)
    if communityProf then
        return "community-" .. name, communityProf
    end
    return nil, nil
end

-- ============================================================================
-- §4  SCORING ENGINE
-- ============================================================================
-- All functions in this section are pure computation — no WoW API calls.

--- Awareness: how well did they avoid mechanics?
-- @param avoidableDmg  number  Avoidable damage taken
-- @param totalDmgTaken number  Total damage taken
-- @return number 0-100
function MPI.ScoreAwareness(avoidableDmg, totalDmgTaken)
    avoidableDmg  = avoidableDmg  or 0
    totalDmgTaken = totalDmgTaken or 0
    if totalDmgTaken <= 0 then return 100 end
    local pct = avoidableDmg / totalDmgTaken
    return max(0, min(100, floor(100 * (1 - pct) + 0.5)))
end

--- Survival (simple fallback): raw death count with diminishing returns.
-- Used when detailed death context is not available.
-- @param deaths number  Death count
-- @return number 0-100
function MPI.ScoreSurvivalSimple(deaths)
    deaths = deaths or 0
    if deaths <= 0 then return 100 end
    return max(0, floor(100 * (0.85 ^ deaths) + 0.5))
end

--- Survival (smart): each death is weighted by how much blame the player deserves.
-- Cross-references death recap events against avoidable damage flags, overkill ratio,
-- and group wipe context to distinguish "stood in fire" from "healer was asleep."
--
-- Blame weight per death (0.0 = no fault, 1.0 = fully your fault):
--   1. Avoidable contribution: what % of damage in the death recap was avoidable?
--   2. Overkill ratio: one-shot deaths with high overkill = reduced blame
--   3. Group wipe: if the boss was a wipe and multiple people died, blame is shared
--   4. Tank death cascade: if the tank died first and you died after, reduced blame
--
-- @param deaths          number  Raw death count
-- @param deathRecaps     table   Array of death recap entries for this player
-- @param avoidableSpells table   Map of spellID → true for spells flagged as avoidable
-- @param groupDeaths     number  Total deaths across all players in the run
-- @param encounterWipes  number  Number of boss encounters that were wipes
-- @param tankDiedFirst   boolean Whether the tank died before this player in any encounter
-- @return number 0-100, table deathDetails (for dashboard display)
function MPI.ScoreSurvival(deaths, deathRecaps, avoidableSpells, groupDeaths, encounterWipes, tankDiedFirst)
    deaths = deaths or 0
    if deaths <= 0 then return 100, {} end

    -- If no detailed data available, fall back to simple scoring
    if not deathRecaps or #deathRecaps == 0 then
        return MPI.ScoreSurvivalSimple(deaths), {}
    end

    avoidableSpells = avoidableSpells or {}
    groupDeaths = groupDeaths or 0
    encounterWipes = encounterWipes or 0

    local totalBlame = 0
    local deathDetails = {}

    for _, recap in ipairs(deathRecaps) do
        local blame = 1.0  -- start at full blame, reduce based on context
        local reason = "unknown"
        local maxHp = recap.maxHealth or 1
        local events = recap.events or {}

        -- ── Factor 1: Avoidable contribution ─────────────────────────────
        -- What percentage of the damage in this death came from avoidable spells?
        local totalRecapDmg = 0
        local avoidableRecapDmg = 0
        for _, ev in ipairs(events) do
            local amt = ev.amount or 0
            if amt > 0 then
                totalRecapDmg = totalRecapDmg + amt
                if avoidableSpells[ev.spellID] then
                    avoidableRecapDmg = avoidableRecapDmg + amt
                end
            end
        end

        local avoidablePct = totalRecapDmg > 0 and (avoidableRecapDmg / totalRecapDmg) or 0

        if avoidablePct > 0.5 then
            -- More than half the damage was avoidable: your fault
            blame = 1.0
            reason = "avoidable"
        elseif avoidablePct > 0.2 then
            -- Some avoidable damage contributed, partial blame
            blame = 0.6 + (avoidablePct * 0.8)  -- 0.76 to 1.0
            reason = "partly_avoidable"
        else
            -- Little to no avoidable damage: likely not your fault
            blame = 0.3
            reason = "unavoidable"
        end

        -- ── Factor 2: Overkill ratio ─────────────────────────────────────
        -- If the killing blow had massive overkill, it was a one-shot
        -- that you probably couldn't have survived regardless.
        local lastEvent = nil
        for i = #events, 1, -1 do
            if (events[i].amount or 0) > 0 then lastEvent = events[i]; break end
        end

        if lastEvent and maxHp > 0 then
            local overkill = lastEvent.overkill or 0
            local overkillRatio = overkill / maxHp
            if overkillRatio > 0.4 then
                -- Massive one-shot: you were going to die no matter what
                blame = blame * 0.4
                reason = reason .. "+oneshot"
            elseif overkillRatio > 0.2 then
                -- Heavy hit: some reduction
                blame = blame * 0.7
                reason = reason .. "+heavy_hit"
            end
        end

        -- ── Factor 3: Group wipe context ─────────────────────────────────
        -- If this was during a boss wipe where multiple people died,
        -- it's a collective failure, not just yours.
        if encounterWipes > 0 and groupDeaths >= 3 then
            blame = blame * 0.5
            reason = reason .. "+wipe"
        end

        -- ── Factor 4: Tank death cascade ─────────────────────────────────
        -- If the tank died first, the group lost its damage sponge.
        -- Subsequent deaths are partly a consequence of that, not player error.
        if tankDiedFirst then
            blame = blame * 0.6
            reason = reason .. "+tank_down"
        end

        -- Clamp blame to 0.1 - 1.0 (always at least a small penalty for dying)
        blame = max(0.1, min(1.0, blame))
        totalBlame = totalBlame + blame

        deathDetails[#deathDetails + 1] = {
            blame = blame,
            reason = reason,
            avoidablePct = floor(avoidablePct * 100),
        }
    end

    -- For any deaths beyond what we have recaps for, use 0.5 blame (neutral)
    local unaccountedDeaths = deaths - #deathRecaps
    if unaccountedDeaths > 0 then
        totalBlame = totalBlame + (unaccountedDeaths * 0.5)
    end

    -- Same formula as before but using effective (weighted) deaths
    local score = max(0, floor(100 * (0.85 ^ totalBlame) + 0.5))
    return score, deathDetails
end

--- Output for DPS: normalized scoring against top DPS in the group.
-- @param playerDmg number     This player's damage done
-- @param allDpsAmounts table  Array of all DPS players' damage amounts
-- @return number 0-100
function MPI.ScoreDpsOutput(playerDmg, allDpsAmounts)
    playerDmg = playerDmg or 0
    if not allDpsAmounts or #allDpsAmounts == 0 then return 50 end

    -- Find the highest DPS in the group
    local topDmg = 0
    for _, dmg in ipairs(allDpsAmounts) do
        if dmg > topDmg then topDmg = dmg end
    end

    if topDmg <= 0 then return 50 end

    -- Normalized: percentage of top DPS, floor of 30
    -- 100% of top = 100, 90% = 90, 70% = 70, etc.
    -- Close DPS values produce close scores (no more 40-point swings for 2% gaps)
    local pct = playerDmg / topDmg
    return max(30, min(100, floor(pct * 100 + 0.5)))
end

--- Output for Tank: damage contribution as share of group total.
-- @param tankDmg    number  Tank's damage done
-- @param groupTotal number  Total group damage
-- @return number 0-100
function MPI.ScoreTankOutput(tankDmg, groupTotal)
    tankDmg    = tankDmg    or 0
    groupTotal = groupTotal or 0
    if groupTotal <= 0 then return 50 end
    -- Tank doing 20%+ of group damage = score 100
    return min(100, floor((tankDmg / groupTotal) * 500 + 0.5))
end

--- Output for Healer: blends damage contribution (60%) with healing coverage (40%).
-- Modern M+ healers are differentiated by DPS contribution; this rewards healers
-- who deal damage while still checking they heal when the group needs it.
-- @param healerDmg    number  Healer's damage done
-- @param groupTotal   number  Total group damage done
-- @param healerHPS    number  Healer's healing per second
-- @param groupDTPS    number  Group's damage taken per second
-- @return number 0-100
function MPI.ScoreHealerOutput(healerDmg, groupTotal, healerHPS, groupDTPS)
    healerDmg  = healerDmg  or 0
    groupTotal = groupTotal or 0
    healerHPS  = healerHPS  or 0
    groupDTPS  = groupDTPS  or 0

    -- Primary (60%): healer damage as % of group total.
    -- 15% of group damage = 100 (exceptional), 10% = 67 (solid), 5% = 33 (low).
    local dmgScore = 50
    if groupTotal > 0 then
        dmgScore = min(100, floor((healerDmg / groupTotal) * 667 + 0.5))
    end

    -- Secondary (40%): healing coverage (HPS vs group DTPS).
    -- Ensures pure-DPS healers who let people die don't score well.
    local coverageScore = 80
    if groupDTPS > 0 then
        coverageScore = min(100, floor((healerHPS / groupDTPS) * 100 + 0.5))
    end

    return max(0, min(100, floor(dmgScore * 0.6 + coverageScore * 0.4 + 0.5)))
end

--- Output for Augmentation Evoker: personal damage as % of group total.
-- Aug buffs allies instead of dealing personal damage, so compare against
-- Aug-appropriate expectations rather than against pure DPS specs.
-- 13% of group = 100 (exceptional), 10% = 77 (solid), 7% = 54 (mediocre).
-- @param augDmg       number  Aug's personal damage done
-- @param groupTotal   number  Total group damage done
-- @return number 0-100
function MPI.ScoreAugOutput(augDmg, groupTotal)
    augDmg     = augDmg     or 0
    groupTotal = groupTotal or 0
    if groupTotal <= 0 then return 50 end
    local pct = augDmg / groupTotal
    return max(20, min(100, floor(pct * 770 + 0.5)))
end

--- Utility: interrupts and dispels combined.
-- In low-interrupt dungeons (few kickable casts), normalizes player contributions
-- so they aren't penalized for lack of opportunity.
-- @param interrupts           number  This player's interrupt count
-- @param dispels              number  This player's dispel count
-- @param groupTotalInterrupts number  Sum of all players' interrupts in this run
-- @return number 0-100
function MPI.ScoreUtility(interrupts, dispels, groupTotalInterrupts)
    interrupts = interrupts or 0
    dispels = dispels or 0
    groupTotalInterrupts = groupTotalInterrupts or 0

    local kickScore
    if groupTotalInterrupts >= 15 then
        -- Normal caster-heavy dungeon: use absolute count with sqrt curve
        kickScore = min(80, floor(18 * sqrt(max(0, interrupts)) + 0.5))
    elseif groupTotalInterrupts > 0 then
        -- Low-interrupt dungeon: normalize player's share against expected baseline.
        -- Scores as if the group had 20 kicks total and the player did their share.
        local normalizedKicks = (interrupts / groupTotalInterrupts) * 20
        kickScore = min(80, floor(18 * sqrt(max(0, normalizedKicks)) + 0.5))
    else
        -- No kicks at all (purely physical dungeon or very short run) — neutral score
        kickScore = 50
    end

    -- Dispels: flat bonus capped at 20
    local dispelBonus = min(20, dispels * 4)
    return min(100, kickScore + dispelBonus)
end

--- Consistency: how stable are recent scores?
-- @param recentScores table  Array of recent MPI scores (up to 10)
-- @return number 0-100
function MPI.ScoreConsistency(recentScores)
    if not recentScores or #recentScores < 2 then return 75 end -- default for insufficient data
    local n = min(#recentScores, SCORE_WINDOW)
    local sum = 0
    for i = 1, n do sum = sum + (recentScores[i] or 0) end
    local mean = sum / n

    local variance = 0
    for i = 1, n do
        local diff = (recentScores[i] or 0) - mean
        variance = variance + diff * diff
    end
    variance = variance / n
    local stdDev = sqrt(variance)

    -- Low std dev = high consistency. stdDev of 33+ = score 0
    return max(0, floor(100 - (stdDev * 3) + 0.5))
end

--- Compute composite MPI score for a player in a single run.
-- @param role          string  "TANK", "HEALER", or "DAMAGER"
-- @param awareness     number  0-100 awareness score
-- @param survival      number  0-100 survival score
-- @param output        number  0-100 output score
-- @param utility       number  0-100 utility score (interrupts + dispels)
-- @param consistency   number  0-100 consistency score (from profile, not per-run)
-- @return number 0-100
function MPI.ComputeRunScore(role, awareness, survival, output, utility, consistency)
    local weights = ROLE_WEIGHTS[role] or ROLE_WEIGHTS.DPS
    local score = (awareness   or 0) * weights[1]
                + (survival    or 0) * weights[2]
                + (output      or 0) * weights[3]
                + (utility     or 0) * weights[4]
                + (consistency or 75) * weights[5] -- default consistency for new players
    return max(0, min(100, floor(score + 0.5)))
end

--- Key level weight: higher keys matter more in profile average.
-- @param keyLevel number
-- @return number 0.2-1.5
function MPI.ComputeKeyWeight(keyLevel)
    keyLevel = keyLevel or 1
    return max(0.2, min(1.5, keyLevel / 15))
end

--- Get tier info for a score.
-- @param score number 0-100
-- @return string tier label, number r, number g, number b
function MPI.GetScoreTier(score)
    score = score or 0
    for _, t in ipairs(SCORE_TIERS) do
        if score >= t[1] then
            return t[2], t[3], t[4], t[5]
        end
    end
    return "D", 1.00, 0.35, 0.35
end

--- Get bar fill color for a 0-100 value.
-- Returns gradient-friendly RGB based on score bracket:
--   0-24 = red, 25-49 = orange, 50-74 = yellow, 75-99 = green, 100 = gold
-- @param value number 0-100
-- @return number r, number g, number b
function MPI.GetBarColor(value)
    value = value or 0
    if value >= 100 then return 1.00, 0.84, 0.00 end -- gold
    if value >= 75  then return 0.35, 0.88, 0.45 end -- green
    if value >= 50  then return 0.95, 0.80, 0.20 end -- yellow
    if value >= 25  then return 1.00, 0.55, 0.26 end -- orange
    return 1.00, 0.35, 0.35                          -- red
end

--- Compute trend from recent vs previous scores.
-- @param recentScores   table  Last 5 scores
-- @param previousScores table  Previous 5 scores
-- @return string "up", "stable", or "down"
function MPI.ComputeTrend(recentScores, previousScores)
    if not recentScores or #recentScores == 0 then return "stable" end
    if not previousScores or #previousScores == 0 then return "stable" end

    local recentAvg, prevAvg = 0, 0
    for _, s in ipairs(recentScores) do recentAvg = recentAvg + s end
    for _, s in ipairs(previousScores) do prevAvg = prevAvg + s end
    recentAvg = recentAvg / #recentScores
    prevAvg = prevAvg / #previousScores

    local diff = recentAvg - prevAvg
    if diff > 5 then return "up"
    elseif diff < -5 then return "down"
    else return "stable" end
end

--- Determine badges for a run.
-- @param runResult    string  "timed", "depleted", "abandoned"
-- @param stars        number  0-3
-- @param playerData   table   Per-player run data
-- @return table array of badge ID strings
function MPI.DetermineRunBadges(runResult, stars, playerData)
    local badges = {}
    if not playerData then return badges end

    -- Active Kicker: 12+ interrupts (a meaningful contribution across a full run)
    if (playerData.interrupts or 0) >= 12 then
        badges[#badges + 1] = BADGE_DEFS.ACTIVE_KICKER.id
    end

    -- Clean Run: 0 deaths and avoidable damage under 5% of total damage taken
    local avoidPct = (playerData.damageTaken or 0) > 0
        and (playerData.avoidableDamage or 0) / playerData.damageTaken
        or 0
    if (playerData.deaths or 0) == 0 and avoidPct < 0.05 then
        badges[#badges + 1] = BADGE_DEFS.CLEAN_RUN.id
    end

    -- Timed+: timed with 2+ stars
    if runResult == "timed" and (stars or 0) >= 2 then
        badges[#badges + 1] = BADGE_DEFS.TIMED_PLUS.id
    end

    return badges
end

--- Determine profile-level badges (computed from aggregate data).
-- @param profile table  Player profile
-- @return table array of badge ID strings
function MPI.DetermineProfileBadges(profile)
    local badges = {}
    if not profile then return badges end

    -- Improver: upward trend
    if profile.trend == "up" then
        badges[#badges + 1] = BADGE_DEFS.IMPROVER.id
    end

    -- Iron Will: 95%+ completion rate
    local totalStarted = (profile.runsTracked or 0)
    local abandoned = (profile.abandonedRuns or 0)
    if totalStarted >= 5 then
        local completionRate = (totalStarted - abandoned) / totalStarted
        if completionRate >= 0.95 then
            badges[#badges + 1] = BADGE_DEFS.IRON_WILL.id
        end
    end

    -- Dungeon Expert: 4+ dungeons mastered
    local masteredCount = 0
    if profile.dungeonMastery then
        for _, mastery in pairs(profile.dungeonMastery) do
            if mastery.level == "MASTERED" then
                masteredCount = masteredCount + 1
            end
        end
    end
    if masteredCount >= 4 then
        badges[#badges + 1] = BADGE_DEFS.DUNGEON_EXPERT.id
    end

    return badges
end

--- Compute dungeon mastery level for a specific dungeon.
-- @param dungeonRuns table  Array of {score, timed} from runs in this dungeon
-- @return string mastery level key ("MASTERED", "COMFORTABLE", "LEARNING")
function MPI.ComputeDungeonMastery(dungeonRuns)
    if not dungeonRuns or #dungeonRuns == 0 then return "LEARNING" end

    local timedCount = 0
    local totalScore = 0
    for _, run in ipairs(dungeonRuns) do
        if run.timed then timedCount = timedCount + 1 end
        totalScore = totalScore + (run.score or 0)
    end
    local avgScore = totalScore / #dungeonRuns

    if timedCount >= MASTERY_LEVELS.MASTERED.minTimedRuns and avgScore >= MASTERY_LEVELS.MASTERED.minAvgScore then
        return "MASTERED"
    elseif timedCount >= MASTERY_LEVELS.COMFORTABLE.minTimedRuns and avgScore >= MASTERY_LEVELS.COMFORTABLE.minAvgScore then
        return "COMFORTABLE"
    end
    return "LEARNING"
end

--- Compute pressure curve: average MPI by key level bracket.
-- @param runs table  Array of {keyLevel, score} entries
-- @return table  {bracketLabel = avgScore, ...}, string peakBracket
function MPI.ComputePressureCurve(runs)
    local brackets = {}
    local counts = {}
    for _, b in ipairs(KEY_BRACKETS) do
        brackets[b[3]] = 0
        counts[b[3]] = 0
    end

    for _, run in ipairs(runs or {}) do
        local kl = run.keyLevel or 0
        for _, b in ipairs(KEY_BRACKETS) do
            if kl >= b[1] and kl <= b[2] then
                brackets[b[3]] = brackets[b[3]] + (run.score or 0)
                counts[b[3]] = counts[b[3]] + 1
                break
            end
        end
    end

    local curve = {}
    local peakLabel, peakAvg = "", 0
    for _, b in ipairs(KEY_BRACKETS) do
        local label = b[3]
        if counts[label] > 0 then
            local avg = floor(brackets[label] / counts[label] + 0.5)
            curve[label] = avg
            if avg > peakAvg then
                peakAvg = avg
                peakLabel = label
            end
        end
    end

    return curve, peakLabel
end

--- Generate smart alerts for a player profile.
-- @param profile table  Player profile
-- @param dungeonMapID number|nil  Current dungeon context (optional)
-- @return table array of {text, severity} where severity = "warning"|"positive"|"info"
function MPI.GenerateSmartAlerts(profile, dungeonMapID)
    local alerts = {}
    if not profile then return alerts end

    -- Reliability warning: left 3+ of last 10 runs
    local totalStarted = profile.runsTracked or 0
    local abandoned = profile.abandonedRuns or 0
    if totalStarted >= 5 and abandoned >= 3 then
        local pct = floor(abandoned / totalStarted * 100)
        alerts[#alerts + 1] = {
            text = "Left " .. abandoned .. " of " .. totalStarted .. " runs (" .. pct .. "%)",
            severity = "warning",
        }
    end

    -- Hot streak: check recentScores for consecutive good runs
    if profile.recentScores and #profile.recentScores >= 5 then
        local allTimed = true
        for i = 1, min(5, #profile.recentScores) do
            if (profile.recentScores[i] or 0) < 60 then allTimed = false; break end
        end
        if allTimed then
            alerts[#alerts + 1] = {
                text = "On a hot streak — last 5 runs all B+ or better",
                severity = "positive",
            }
        end
    end

    -- Rapid improvement
    if profile.trend == "up" and profile.recentScores and profile.previousScores then
        local recentAvg, prevAvg = 0, 0
        for _, s in ipairs(profile.recentScores) do recentAvg = recentAvg + s end
        for _, s in ipairs(profile.previousScores) do prevAvg = prevAvg + s end
        if #profile.recentScores > 0 then recentAvg = recentAvg / #profile.recentScores end
        if #profile.previousScores > 0 then prevAvg = prevAvg / #profile.previousScores end
        if recentAvg - prevAvg >= 15 then
            alerts[#alerts + 1] = {
                text = "Improving rapidly — scores up " .. floor(recentAvg - prevAvg) .. " points",
                severity = "positive",
            }
        end
    end

    -- Dungeon-specific insight
    if dungeonMapID and profile.dungeonMastery then
        local mastery = profile.dungeonMastery[dungeonMapID]
        if mastery then
            if mastery.level == "MASTERED" then
                alerts[#alerts + 1] = {
                    text = "Strong in this dungeon (Mastered)",
                    severity = "positive",
                }
            elseif mastery.level == "LEARNING" then
                alerts[#alerts + 1] = {
                    text = "Still learning this dungeon",
                    severity = "info",
                }
            end
        else
            alerts[#alerts + 1] = {
                text = "No data for this dungeon",
                severity = "info",
            }
        end
    end

    -- Role switch detection
    if profile.roleHistory and #profile.roleHistory >= 2 then
        local recent = profile.roleHistory[1]
        local prev = profile.roleHistory[2]
        if recent ~= prev then
            alerts[#alerts + 1] = {
                text = "Recently switched to " .. (recent == "TANK" and "Tank" or recent == "HEALER" and "Healer" or "DPS") .. " — limited data",
                severity = "info",
            }
        end
    end

    return alerts
end


-- ============================================================================
-- §5  EVENT HANDLER: RUN TRACKING & STAT HARVESTING
-- ============================================================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")

local function OnAddonLoaded(_, addonName)
    if addonName ~= ADDON_NAME then return end

    MPI.EnsureDB()

    -- Load community database (written by companion app)
    MPI.LoadCommunityDB()

    -- Register PLAYER_LOGOUT to export data for companion app
    eventFrame:RegisterEvent("PLAYER_LOGOUT")

    -- Check C_DamageMeter API availability
    if C_DamageMeter and C_DamageMeter.GetAvailableCombatSessions then
        local ok = pcall(C_DamageMeter.GetAvailableCombatSessions)
        MPI._apiAvailable = ok
    end

    -- Register M+ tracking events
    if MPI._apiAvailable then
        eventFrame:RegisterEvent("CHALLENGE_MODE_START")
        eventFrame:RegisterEvent("CHALLENGE_MODE_COMPLETED")
        eventFrame:RegisterEvent("ENCOUNTER_START")
        eventFrame:RegisterEvent("ENCOUNTER_END")
        eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    end

    MPI._ready = true
end

--- Snapshot the current group roster.
-- @return table  {[guid] = {name, class, role, specIcon}}
local function SnapshotRoster()
    local roster = {}
    local myGUID = UnitGUID("player")
    if myGUID then
        local myName = UnitName("player")
        -- Append realm so local player matches Name-Realm format used for others
        local _, myRealm = UnitFullName and UnitFullName("player")
        if myRealm and myRealm ~= "" then myName = myName .. "-" .. myRealm end
        local _, myClass = UnitClass("player")
        local myRole = UnitGroupRolesAssigned("player") or "DAMAGER"
        local mySpecIcon = 0
        local specIdx = GetSpecialization and GetSpecialization()
        if specIdx and GetSpecializationInfo then
            local _, _, _, icon = GetSpecializationInfo(specIdx)
            mySpecIcon = icon or 0
        end
        roster[myGUID] = { name = myName, class = myClass, role = myRole, specIcon = mySpecIcon }
    end

    local numGroup = GetNumGroupMembers() or 0
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and numGroup or (numGroup - 1)
    for i = 1, count do
        local unit = prefix .. i
        local guid = UnitGUID(unit)
        if guid and guid ~= myGUID then
            local name, realm = UnitName(unit)
            if realm and realm ~= "" then name = name .. "-" .. realm end
            local _, classFile = UnitClass(unit)
            local role = UnitGroupRolesAssigned(unit) or "DAMAGER"
            roster[guid] = { name = name, class = classFile or "", role = role, specIcon = 0 }
        end
    end
    return roster
end

--- Called at CHALLENGE_MODE_START
local function OnChallengeModeStart()
    if not MPI._apiAvailable then return end

    local mapID = C_ChallengeMode.GetActiveChallengeMapID and C_ChallengeMode.GetActiveChallengeMapID()
    if not mapID then return end

    local keyLevel, affixes
    if C_ChallengeMode.GetActiveKeystoneInfo then
        keyLevel, affixes = C_ChallengeMode.GetActiveKeystoneInfo()
    end

    local dungeonName, _, timeLimitMs
    if C_ChallengeMode.GetMapUIInfo then
        dungeonName, _, timeLimitMs = C_ChallengeMode.GetMapUIInfo(mapID)
    end

    MPI._activeRun = {
        startTime    = time(),
        startGetTime = GetTime(),  -- session-relative reference for encounter offsets
        mapID        = mapID,
        dungeonName  = dungeonName or "Unknown",
        keyLevel     = keyLevel or 0,
        timeLimitSec = (timeLimitMs or 0) / 1000,
        affixes      = affixes or {},
    }
    MPI._encounterLog = {}
    MPI._leavers = {}
    MPI._rosterSnapshot = SnapshotRoster()
end

--- Called at ENCOUNTER_START
local function OnEncounterStart(encounterID, encounterName)
    if not MPI._activeRun then return end
    MPI._encounterLog[#MPI._encounterLog + 1] = {
        id = encounterID,
        name = encounterName,
        startTime = GetTime(),
        endTime = nil,
        success = nil,
    }
end

--- Harvest per-encounter stats from C_DamageMeter using CurrentEncounter session.
-- Called at ENCOUNTER_END to capture boss-specific performance data.
-- @return table {players={[name]={damageDone,damageTaken,avoidableDamage,healingDone,interrupts,dispels,deaths}}, topSpells={[name]={damage={},healing={},avoidable={}}}}
local function HarvestEncounterData()
    local result = { players = {}, topSpells = {} }
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionFromType then return result end

    -- Discover the per-encounter session type — name may vary across WoW versions.
    -- Try known candidates and use the first one that exists.
    local sessionType = nil
    if Enum and Enum.DamageMeterSessionType then
        sessionType = Enum.DamageMeterSessionType.CurrentEncounter
                   or Enum.DamageMeterSessionType.CurrentBoss
                   or Enum.DamageMeterSessionType.LastEncounter
                   or Enum.DamageMeterSessionType.LastFight
    end
    if not sessionType then
        -- None of the known enum names exist — cannot harvest per-boss data.
        -- Runs will use run-wide fallback on the dashboard (labels show "(Run)").
        return result
    end

    -- Verify the session type actually returns data by probing it
    local probeOk, probeSession = pcall(C_DamageMeter.GetCombatSessionFromType,
        sessionType, Enum.DamageMeterType.DamageDone)
    if not probeOk or not probeSession then return result end

    local VALID = {
        WARRIOR=1, PALADIN=1, HUNTER=1, ROGUE=1, PRIEST=1, DEATHKNIGHT=1,
        SHAMAN=1, MAGE=1, WARLOCK=1, MONK=1, DRUID=1, DEMONHUNTER=1, EVOKER=1,
    }

    local meterTypes = {
        { enum = Enum.DamageMeterType.DamageDone,          field = "damageDone" },
        { enum = Enum.DamageMeterType.DamageTaken,          field = "damageTaken" },
        { enum = Enum.DamageMeterType.AvoidableDamageTaken, field = "avoidableDamage" },
        { enum = Enum.DamageMeterType.HealingDone,          field = "healingDone" },
        { enum = Enum.DamageMeterType.Interrupts,           field = "interrupts" },
        { enum = Enum.DamageMeterType.Dispels,              field = "dispels" },
        { enum = Enum.DamageMeterType.Deaths,               field = "deaths" },
    }

    -- Aggregate per-player stats for this encounter
    for _, mt in ipairs(meterTypes) do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType, sessionType, mt.enum)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID[source.classFilename] and source.name then
                    if not result.players[source.name] then
                        result.players[source.name] = {
                            name = source.name,
                            class = source.classFilename,
                            isLocal = source.isLocalPlayer or false,
                        }
                    end
                    result.players[source.name][mt.field] = source.totalAmount or 0
                end
            end
        end
    end

    -- Per-spell breakdowns for this encounter (damage done + avoidable damage taken)
    -- Build sourceGUID lookup from THIS encounter's session (not Overall)
    -- to ensure GUIDs are valid in the encounter session context.
    local encGuidLookup = {}
    do
        local lok, lsess = pcall(C_DamageMeter.GetCombatSessionFromType,
            sessionType, Enum.DamageMeterType.DamageDone)
        if lok and lsess and lsess.combatSources then
            for _, source in ipairs(lsess.combatSources) do
                if source.classFilename and VALID[source.classFilename] and source.name then
                    encGuidLookup[source.name] = source.sourceGUID
                end
            end
        end
    end

    -- Top damage spells per player (this encounter only)
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            sessionType, Enum.DamageMeterType.DamageDone)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID[source.classFilename] and source.name then
                    local spells = nil
                    if C_DamageMeter.GetCombatSessionSourceFromType then
                        local sok, sd = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
                            sessionType, Enum.DamageMeterType.DamageDone, source.sourceGUID)
                        if sok and sd and sd.combatSpells then spells = sd.combatSpells end
                    end
                    if spells then
                        local breakdown = {}
                        for _, sp in ipairs(spells) do
                            breakdown[#breakdown + 1] = {
                                spellID   = sp.spellID or 0,
                                spellName = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                total     = sp.totalAmount or 0,
                            }
                        end
                        table.sort(breakdown, function(a, b) return a.total > b.total end)
                        while #breakdown > 8 do table.remove(breakdown) end
                        if not result.topSpells[source.name] then result.topSpells[source.name] = {} end
                        result.topSpells[source.name].damage = breakdown
                    end
                end
            end
        end
    end

    -- Avoidable damage spells for this encounter
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            sessionType, Enum.DamageMeterType.DamageTaken)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID[source.classFilename] and source.name then
                    local spells = nil
                    if C_DamageMeter.GetCombatSessionSourceFromType then
                        local sok, sd = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
                            sessionType, Enum.DamageMeterType.DamageTaken, source.sourceGUID)
                        if sok and sd and sd.combatSpells then spells = sd.combatSpells end
                    end
                    if spells then
                        local avoidable = {}
                        for _, sp in ipairs(spells) do
                            if sp.isAvoidable then
                                avoidable[#avoidable + 1] = {
                                    spellID     = sp.spellID or 0,
                                    spellName   = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                    total       = sp.totalAmount or 0,
                                    isDeadly    = sp.isDeadly or false,
                                    sourceName  = sp.creatureName or "Unknown",
                                }
                            end
                        end
                        table.sort(avoidable, function(a, b) return a.total > b.total end)
                        if not result.topSpells[source.name] then result.topSpells[source.name] = {} end
                        result.topSpells[source.name].avoidable = avoidable
                    end
                end
            end
        end
    end

    -- Healing spells for this encounter
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            sessionType, Enum.DamageMeterType.HealingDone)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID[source.classFilename] and source.name then
                    local spells = nil
                    if C_DamageMeter.GetCombatSessionSourceFromType then
                        local sok, sd = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
                            sessionType, Enum.DamageMeterType.HealingDone, source.sourceGUID)
                        if sok and sd and sd.combatSpells then spells = sd.combatSpells end
                    end
                    if spells then
                        local breakdown = {}
                        for _, sp in ipairs(spells) do
                            breakdown[#breakdown + 1] = {
                                spellID   = sp.spellID or 0,
                                spellName = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                total     = sp.totalAmount or 0,
                            }
                        end
                        table.sort(breakdown, function(a, b) return a.total > b.total end)
                        while #breakdown > 8 do table.remove(breakdown) end
                        if not result.topSpells[source.name] then result.topSpells[source.name] = {} end
                        result.topSpells[source.name].healing = breakdown
                    end
                end
            end
        end
    end

    return result
end

--- Called at ENCOUNTER_END
local function OnEncounterEnd(encounterID, encounterName, difficultyID, groupSize, success)
    if not MPI._activeRun then return end

    -- Harvest per-encounter performance data BEFORE updating the log
    -- (CurrentEncounter session is only valid until the next encounter starts)
    local encounterStats = HarvestEncounterData()

    -- Find and update the matching encounter
    for i = #MPI._encounterLog, 1, -1 do
        local enc = MPI._encounterLog[i]
        if enc.id == encounterID and not enc.endTime then
            enc.endTime = GetTime()
            enc.success = (success == 1)
            enc.stats = encounterStats  -- attach per-boss data
            break
        end
    end
end

--- Called at GROUP_ROSTER_UPDATE (detect leavers)
-- Only the FIRST person to leave mid-key is the "abandoner."
-- Everyone who leaves after that is reacting to a bricked key and shouldn't be penalized.
-- If all 5 players leave within 5 seconds (surrender vote), nobody is penalized.
local function OnGroupRosterUpdate()
    if not MPI._activeRun or not MPI._rosterSnapshot then return end
    if C_ChallengeMode.IsChallengeModeActive and not C_ChallengeMode.IsChallengeModeActive() then return end

    local currentGUIDs = {}
    local myGUID = UnitGUID("player")
    if myGUID then currentGUIDs[myGUID] = true end

    local numGroup = GetNumGroupMembers() or 0
    local prefix = IsInRaid() and "raid" or "party"
    local count = IsInRaid() and numGroup or (numGroup - 1)
    for i = 1, count do
        local guid = UnitGUID(prefix .. i)
        if guid then currentGUIDs[guid] = true end
    end

    -- Reconnection grace: if a previously-marked leaver reappears, remove them.
    -- Genuine disconnects shouldn't be penalized if the player reconnects.
    for guid in pairs(MPI._leavers) do
        if currentGUIDs[guid] then
            MPI._leavers[guid] = nil
        end
    end

    -- Check for missing players
    local hasExistingLeaver = false
    for _ in pairs(MPI._leavers) do hasExistingLeaver = true; break end

    local now = time()
    for guid, info in pairs(MPI._rosterSnapshot) do
        if not currentGUIDs[guid] and guid ~= myGUID then
            if not MPI._leavers[guid] then
                MPI._leavers[guid] = {
                    name = info.name,
                    leftAt = now,
                    isInitiator = not hasExistingLeaver,
                }
                hasExistingLeaver = true
            end
        end
    end

    -- Surrender detection: if ALL roster members left within 5 seconds of each other,
    -- this was a coordinated surrender vote — clear all initiator flags so nobody is penalized.
    local rosterSize = 0
    for _ in pairs(MPI._rosterSnapshot) do rosterSize = rosterSize + 1 end
    local leaverCount = 0
    local earliestLeave, latestLeave = nil, nil
    for _, lInfo in pairs(MPI._leavers) do
        leaverCount = leaverCount + 1
        if not earliestLeave or lInfo.leftAt < earliestLeave then earliestLeave = lInfo.leftAt end
        if not latestLeave or lInfo.leftAt > latestLeave then latestLeave = lInfo.leftAt end
    end
    -- If everyone except you has left (leaverCount >= rosterSize - 1) within 5 seconds = surrender
    if leaverCount >= (rosterSize - 1) and earliestLeave and latestLeave and (latestLeave - earliestLeave) <= 5 then
        for _, lInfo in pairs(MPI._leavers) do
            lInfo.isInitiator = false  -- nobody penalized
        end
        MPI._surrendered = true
    end
end

--- Harvest C_DamageMeter data for all metric types.
-- @return table  {[guid] = {damageDone, damageTaken, avoidableDamage, healingDone, dispels, interrupts, deaths}}
local function HarvestDamageMeterData()
    local data = {}
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionFromType then return data end

    local meterTypes = {
        { enum = Enum.DamageMeterType.DamageDone,          field = "damageDone" },
        { enum = Enum.DamageMeterType.DamageTaken,          field = "damageTaken" },
        { enum = Enum.DamageMeterType.AvoidableDamageTaken, field = "avoidableDamage" },
        { enum = Enum.DamageMeterType.HealingDone,          field = "healingDone" },
        { enum = Enum.DamageMeterType.Dispels,              field = "dispels" },
        { enum = Enum.DamageMeterType.Interrupts,           field = "interrupts" },
        { enum = Enum.DamageMeterType.Deaths,               field = "deaths" },
    }

    -- 12.0.1 DISCOVERY: sourceGUID is a "secret value" — cannot use == or :sub() on it.
    -- Key data by source.name instead. classFilename identifies player sources (mobs don't have one).
    local VALID_CLASSES = {
        WARRIOR=1, PALADIN=1, HUNTER=1, ROGUE=1, PRIEST=1, DEATHKNIGHT=1,
        SHAMAN=1, MAGE=1, WARLOCK=1, MONK=1, DRUID=1, DEMONHUNTER=1, EVOKER=1,
    }

    for _, mt in ipairs(meterTypes) do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, mt.enum)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                local isPlayerSource = source.classFilename and VALID_CLASSES[source.classFilename]
                if isPlayerSource and source.name then
                    if not data[source.name] then
                        data[source.name] = {
                            name = source.name,
                            class = source.classFilename,
                            specIcon = source.specIconID or 0,
                            isLocal = source.isLocalPlayer or false,
                        }
                    end
                    data[source.name][mt.field] = source.totalAmount or 0
                end
            end
        end
    end

    -- Also grab DPS session for duration
    local ok, dpsSession = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.Dps)
    if ok and dpsSession then
        for name, d in pairs(data) do
            d._durationSec = dpsSession.durationSeconds or 0
        end
    end

    return data
end

-- ============================================================================
-- §7b  DETAILED COMBAT DATA HARVESTER
-- ============================================================================
-- Extracts granular per-spell breakdowns, death recaps, and interrupt/dispel
-- logs from C_DamageMeter + C_DeathRecap APIs. Called after aggregate harvest
-- to build the detailed run analysis that feeds the MPI dashboard.
-- All calls pcall()-guarded — degrades gracefully if any API is unavailable.

local VALID_CLASSES_DETAIL = {
    WARRIOR=1, PALADIN=1, HUNTER=1, ROGUE=1, PRIEST=1, DEATHKNIGHT=1,
    SHAMAN=1, MAGE=1, WARLOCK=1, MONK=1, DRUID=1, DEMONHUNTER=1, EVOKER=1,
}

--- Get per-spell breakdown for a specific player and meter type.
-- Uses C_DamageMeter.GetCombatSessionSourceFromType to fetch spell-level data.
-- @param meterType  Enum.DamageMeterType  Which metric (DamageTaken, Interrupts, etc.)
-- @param sourceGUID string                The player's opaque sourceGUID from combatSources
-- @return table|nil  Array of {spellID, totalAmount, isAvoidable, isDeadly, creatureName}
local function GetSpellsForSource(meterType, sourceGUID)
    if not C_DamageMeter.GetCombatSessionSourceFromType then return nil end
    local ok, sourceData = pcall(C_DamageMeter.GetCombatSessionSourceFromType,
        Enum.DamageMeterSessionType.Overall, meterType, sourceGUID)
    if not ok or not sourceData or not sourceData.combatSpells then return nil end
    return sourceData.combatSpells
end

--- Build a lookup of player name → sourceGUID from a session's combatSources.
-- Needed because sourceGUID is opaque in 12.0.1 — we can't construct it,
-- but we CAN pass it back to other C_DamageMeter functions.
local function BuildSourceGUIDLookup()
    local lookup = {} -- [playerName] = sourceGUID
    if not C_DamageMeter or not C_DamageMeter.GetCombatSessionFromType then return lookup end

    -- Use DamageDone session as it has all player sources
    local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
        Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageDone)
    if ok and session and session.combatSources then
        for _, source in ipairs(session.combatSources) do
            if source.classFilename and VALID_CLASSES_DETAIL[source.classFilename] and source.name then
                lookup[source.name] = source.sourceGUID
            end
        end
    end
    return lookup
end

--- Harvest detailed combat data for the entire group.
-- Returns a table with per-spell damage taken, death recaps, interrupt/dispel logs.
-- @return table  { damageTakenBySpell, deathRecaps, interruptLog, dispelLog, damageDoneBySpell }
local function HarvestDetailedCombatData()
    local detail = {
        damageTakenBySpell = {},   -- [playerName] = { {spellID, spellName, total, hits, isAvoidable, sourceName}, ... }
        damageDoneBySpell  = {},   -- [playerName] = { {spellID, spellName, total}, ... }
        healingDoneBySpell = {},   -- [playerName] = { {spellID, spellName, total}, ... }
        deathRecaps        = {},   -- { {playerName, maxHealth, events = { {source, spellID, spellName, amount, timestamp}, ... }}, ... }
        interruptLog       = {},   -- { {playerName, spellID, spellName, total}, ... }
        dispelLog          = {},   -- { {playerName, spellID, spellName, total}, ... }
    }

    if not C_DamageMeter then return detail end

    local guidLookup = BuildSourceGUIDLookup()

    -- ── Per-spell DAMAGE TAKEN per player (with avoidable flags) ────────
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageTaken)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID_CLASSES_DETAIL[source.classFilename] and source.name then
                    local spells = GetSpellsForSource(Enum.DamageMeterType.DamageTaken, source.sourceGUID)
                    if spells then
                        local breakdown = {}
                        for _, sp in ipairs(spells) do
                            breakdown[#breakdown + 1] = {
                                spellID     = sp.spellID or 0,
                                spellName   = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                total       = sp.totalAmount or 0,
                                isAvoidable = sp.isAvoidable or false,
                                isDeadly    = sp.isDeadly or false,
                                sourceName  = sp.creatureName or "Unknown",
                            }
                        end
                        -- Sort by total damage descending
                        table.sort(breakdown, function(a, b) return a.total > b.total end)
                        detail.damageTakenBySpell[source.name] = breakdown
                    end
                end
            end
        end
    end

    -- ── Per-spell DAMAGE DONE per player ────────────────────────────────
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.DamageDone)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID_CLASSES_DETAIL[source.classFilename] and source.name then
                    local spells = GetSpellsForSource(Enum.DamageMeterType.DamageDone, source.sourceGUID)
                    if spells then
                        local breakdown = {}
                        for _, sp in ipairs(spells) do
                            breakdown[#breakdown + 1] = {
                                spellID   = sp.spellID or 0,
                                spellName = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                total     = sp.totalAmount or 0,
                            }
                        end
                        table.sort(breakdown, function(a, b) return a.total > b.total end)
                        -- Keep top 15 spells to limit data size
                        while #breakdown > 15 do table.remove(breakdown) end
                        detail.damageDoneBySpell[source.name] = breakdown
                    end
                end
            end
        end
    end

    -- ── Per-spell HEALING DONE per player ─────────────────────────────
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.HealingDone)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID_CLASSES_DETAIL[source.classFilename] and source.name then
                    local spells = GetSpellsForSource(Enum.DamageMeterType.HealingDone, source.sourceGUID)
                    if spells then
                        local breakdown = {}
                        for _, sp in ipairs(spells) do
                            breakdown[#breakdown + 1] = {
                                spellID   = sp.spellID or 0,
                                spellName = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                total     = sp.totalAmount or 0,
                            }
                        end
                        table.sort(breakdown, function(a, b) return a.total > b.total end)
                        while #breakdown > 15 do table.remove(breakdown) end
                        detail.healingDoneBySpell[source.name] = breakdown
                    end
                end
            end
        end
    end

    -- ── Per-spell INTERRUPTS per player ─────────────────────────────────
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.Interrupts)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID_CLASSES_DETAIL[source.classFilename] and source.name then
                    local spells = GetSpellsForSource(Enum.DamageMeterType.Interrupts, source.sourceGUID)
                    if spells then
                        for _, sp in ipairs(spells) do
                            detail.interruptLog[#detail.interruptLog + 1] = {
                                playerName = source.name,
                                spellID    = sp.spellID or 0,
                                spellName  = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                total      = sp.totalAmount or 0,
                                target     = sp.creatureName or "",
                            }
                        end
                    end
                end
            end
        end
    end

    -- ── Per-spell DISPELS per player ────────────────────────────────────
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.Dispels)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID_CLASSES_DETAIL[source.classFilename] and source.name then
                    local spells = GetSpellsForSource(Enum.DamageMeterType.Dispels, source.sourceGUID)
                    if spells then
                        for _, sp in ipairs(spells) do
                            detail.dispelLog[#detail.dispelLog + 1] = {
                                playerName = source.name,
                                spellID    = sp.spellID or 0,
                                spellName  = GetSpellInfo and select(1, GetSpellInfo(sp.spellID)) or ("Spell " .. (sp.spellID or 0)),
                                total      = sp.totalAmount or 0,
                            }
                        end
                    end
                end
            end
        end
    end

    -- ── DEATH RECAPS via C_DeathRecap ───────────────────────────────────
    do
        local ok, session = pcall(C_DamageMeter.GetCombatSessionFromType,
            Enum.DamageMeterSessionType.Overall, Enum.DamageMeterType.Deaths)
        if ok and session and session.combatSources then
            for _, source in ipairs(session.combatSources) do
                if source.classFilename and VALID_CLASSES_DETAIL[source.classFilename]
                   and source.name and source.deathRecapID then
                    local recap = { playerName = source.name, events = {}, maxHealth = 0 }

                    if C_DeathRecap and C_DeathRecap.HasRecapEvents then
                        local hasRecap = SafeCall(C_DeathRecap.HasRecapEvents, source.deathRecapID)
                        if hasRecap then
                            local events = SafeCall(C_DeathRecap.GetRecapEvents, source.deathRecapID)
                            local mhp = SafeCall(C_DeathRecap.GetRecapMaxHealth, source.deathRecapID)
                            recap.maxHealth = mhp or 0

                            if events then
                                for _, ev in ipairs(events) do
                                    recap.events[#recap.events + 1] = {
                                        source    = ev.sourceName or ev.source or "Unknown",
                                        spellID   = ev.spellId or ev.spellID or 0,
                                        spellName = ev.spellName or (ev.spellId and GetSpellInfo and select(1, GetSpellInfo(ev.spellId))) or "Unknown",
                                        amount    = ev.amount or ev.damage or 0,
                                        timestamp = ev.timestamp or 0,
                                        overkill  = ev.overkill or 0,
                                        school    = ev.school or 0,
                                    }
                                end
                            end
                        end
                    end

                    if #recap.events > 0 then
                        detail.deathRecaps[#detail.deathRecaps + 1] = recap
                    end
                end
            end
        end
    end

    return detail
end

--- Main harvest: called at CHALLENGE_MODE_COMPLETED
local function OnChallengeModeCompleted()
    if not MPI._activeRun then return end
    if not db then return end

    -- Get completion info
    local completionInfo
    if C_ChallengeMode.GetChallengeCompletionInfo then
        local ok, info = pcall(C_ChallengeMode.GetChallengeCompletionInfo)
        if ok then completionInfo = info end
    end

    -- Determine result
    local result = "depleted"
    local stars = 0
    local durationSec = 0
    if completionInfo then
        if completionInfo.onTime then
            result = "timed"
            stars = completionInfo.keystoneUpgradeLevels or 1
        end
        durationSec = (completionInfo.time or 0) / 1000
    end

    -- Track leavers (but not if it was a coordinated surrender vote).
    -- Don't override result — the key completed, so result stays "timed" or "depleted".
    -- Leaver penalties are applied per-player in UpdateProfiles.
    local hasLeavers = false
    if not MPI._surrendered then
        for _ in pairs(MPI._leavers) do hasLeavers = true; break end
    end

    -- Harvest all C_DamageMeter data (aggregate + detailed)
    local meterData = HarvestDamageMeterData()
    local detailedData = HarvestDetailedCombatData()

    -- Build per-player stats with scores
    local players = {}
    local allDpsAmounts = {}
    local groupTotalDamage = 0
    local groupTotalDamageTaken = 0
    local groupTotalHealingDone = 0
    local groupTotalInterrupts = 0

    -- First pass: collect raw data and totals (match by name since sourceGUID is secret in 12.0.1)
    local myGUID = UnitGUID("player")
    for guid, info in pairs(MPI._rosterSnapshot) do
        -- Cross-realm fallback: C_DamageMeter may key by short name while
        -- roster uses Name-Realm. Try full name first, then short name.
        local md = meterData[info.name]
        if not md then
            local shortName = info.name and info.name:match("^([^%-]+)")
            if shortName then md = meterData[shortName] end
        end
        md = md or {}

        local p = {
            name            = info.name or md.name or "Unknown",
            class           = info.class or md.class or "",
            role            = info.role or "DAMAGER",
            specIcon        = md.specIcon or info.specIcon or 0,
            damageDone      = md.damageDone or 0,
            damageTaken     = md.damageTaken or 0,
            avoidableDamage = md.avoidableDamage or 0,
            healingDone     = md.healingDone or 0,
            dispels         = md.dispels or 0,
            interrupts      = md.interrupts or 0,
            deaths          = md.deaths or 0,
        }
        players[guid] = p
        groupTotalDamage = groupTotalDamage + p.damageDone
        groupTotalDamageTaken = groupTotalDamageTaken + p.damageTaken
        groupTotalHealingDone = groupTotalHealingDone + p.healingDone
        groupTotalInterrupts = groupTotalInterrupts + p.interrupts

        if p.role == "DAMAGER" then
            allDpsAmounts[#allDpsAmounts + 1] = p.damageDone
        end
    end

    -- Second pass: compute scores
    local effectiveDuration = max(1, durationSec)
    local groupDTPS = groupTotalDamageTaken / effectiveDuration

    -- Pre-compute group context for smart death scoring
    local groupDeathTotal = 0
    for _, pl in pairs(players) do groupDeathTotal = groupDeathTotal + (pl.deaths or 0) end
    local encounterWipeCount = 0
    for _, enc in ipairs(MPI._encounterLog) do
        if enc.success == false then encounterWipeCount = encounterWipeCount + 1 end
    end

    -- Build avoidable spell lookup from detailed data (spellID → true)
    local avoidableSpellLookup = {}
    if detailedData and detailedData.damageTakenBySpell then
        for _, spells in pairs(detailedData.damageTakenBySpell) do
            for _, sp in ipairs(spells) do
                if sp.isAvoidable and sp.spellID then
                    avoidableSpellLookup[sp.spellID] = true
                end
            end
        end
    end

    -- Detect if the tank died (for cascade detection)
    local tankName = nil
    local tankDeaths = 0
    for _, pl in pairs(players) do
        if pl.role == "TANK" then
            tankName = pl.name
            tankDeaths = pl.deaths or 0
            break
        end
    end

    for guid, p in pairs(players) do
        -- Get existing profile for consistency score
        local existingProfile = db.profiles[guid]
        local existingScores = existingProfile and existingProfile.recentScores or {}

        local awarenessScore = MPI.ScoreAwareness(p.avoidableDamage, p.damageTaken)

        -- Smart survival scoring: gather this player's death recaps and context
        local playerDeathRecaps = {}
        if detailedData and detailedData.deathRecaps then
            for _, recap in ipairs(detailedData.deathRecaps) do
                if recap.playerName == p.name then
                    playerDeathRecaps[#playerDeathRecaps + 1] = recap
                end
            end
        end
        local tankDiedFirst = (tankDeaths > 0 and p.role ~= "TANK" and tankName ~= p.name)
        local survivalScore, deathDetails = MPI.ScoreSurvival(
            p.deaths, playerDeathRecaps, avoidableSpellLookup,
            groupDeathTotal, encounterWipeCount, tankDiedFirst
        )
        p._deathDetails = deathDetails  -- per-death blame context for export
        local consistencyScore = MPI.ScoreConsistency(existingScores)

        local outputScore
        local role = p.role
        local weightRole

        if role == "TANK" then
            outputScore = MPI.ScoreTankOutput(p.damageDone, groupTotalDamage)
            weightRole = "TANK"
        elseif role == "HEALER" then
            local healerHPS = p.healingDone / effectiveDuration
            outputScore = MPI.ScoreHealerOutput(p.damageDone, groupTotalDamage, healerHPS, groupDTPS)
            weightRole = "HEALER"
        else
            -- DPS: check for Augmentation Evoker
            local isAug = false
            if p.class == "EVOKER" then
                -- Check specIconID from C_DamageMeter
                if AUG_EVOKER_ICONS[p.specIcon or 0] then
                    isAug = true
                end
                -- For local player, also verify via GetSpecializationInfo (most reliable)
                if guid == myGUID then
                    local specIdx = GetSpecialization and GetSpecialization()
                    if specIdx and GetSpecializationInfo then
                        local specID = GetSpecializationInfo(specIdx)
                        if specID == AUG_EVOKER_SPEC_ID then isAug = true end
                    end
                end
            end

            if isAug then
                outputScore = MPI.ScoreAugOutput(p.damageDone, groupTotalDamage)
                weightRole = "AUG"
            else
                outputScore = MPI.ScoreDpsOutput(p.damageDone, allDpsAmounts)
                weightRole = "DPS"
            end
        end

        local utilityScore = MPI.ScoreUtility(p.interrupts, p.dispels, groupTotalInterrupts)

        local mpiScore = MPI.ComputeRunScore(weightRole, awarenessScore, survivalScore, outputScore, utilityScore, consistencyScore)

        p.mpiScore       = mpiScore
        p.awarenessScore = awarenessScore
        p.survivalScore  = survivalScore
        p.outputScore    = outputScore
        p.utilityScore   = utilityScore
        p.consistencyScore = consistencyScore
        p.weightRole     = weightRole
        p.badges = MPI.DetermineRunBadges(result, stars, p)
    end

    -- Build encounter summary from encounter log (now includes per-boss stats)
    local encounters = {}
    local runGetTimeStart = MPI._activeRun.startGetTime or 0
    for _, enc in ipairs(MPI._encounterLog) do
        local relStart = (enc.startTime and runGetTimeStart > 0) and (enc.startTime - runGetTimeStart) or 0

        -- Build per-player stats for this encounter
        local bossPlayers = nil
        local bossSpells = nil
        if enc.stats then
            -- Convert players table to array for JSON
            if enc.stats.players then
                bossPlayers = {}
                for name, pData in pairs(enc.stats.players) do
                    bossPlayers[#bossPlayers + 1] = {
                        name            = name,
                        class           = pData.class or "",
                        isLocal         = pData.isLocal or false,
                        damageDone      = pData.damageDone or 0,
                        damageTaken     = pData.damageTaken or 0,
                        avoidableDamage = pData.avoidableDamage or 0,
                        healingDone     = pData.healingDone or 0,
                        interrupts      = pData.interrupts or 0,
                        dispels         = pData.dispels or 0,
                        deaths          = pData.deaths or 0,
                    }
                end
            end
            bossSpells = enc.stats.topSpells
        end

        encounters[#encounters + 1] = {
            id        = enc.id,
            name      = enc.name,
            startTime = max(0, floor(relStart)),
            duration  = (enc.endTime and enc.startTime) and floor(enc.endTime - enc.startTime) or 0,
            success   = enc.success or false,
            players   = bossPlayers,
            spells    = bossSpells,
        }
    end

    -- Build run record (now includes detailed combat data + encounter log)
    local runRecord = {
        timestamp    = time(),
        dungeonMapID = MPI._activeRun.mapID,
        dungeonName  = MPI._activeRun.dungeonName,
        keyLevel     = MPI._activeRun.keyLevel,
        affixes      = MPI._activeRun.affixes or {},
        result       = result,
        stars        = stars,
        durationSec  = durationSec,
        timeLimitSec = MPI._activeRun.timeLimitSec,
        players      = players,
        leavers      = hasLeavers and MPI._leavers or nil,
        encounters   = encounters,
        detail       = detailedData,
    }

    -- Attach per-player death blame details to the run detail for export
    -- Format: { [playerName] = { {blame, reason, avoidablePct}, ... } }
    if detailedData then
        local deathBlame = {}
        for guid, p in pairs(players) do
            if p._deathDetails and #p._deathDetails > 0 then
                deathBlame[p.name] = p._deathDetails
            end
            p._deathDetails = nil  -- clean up temp field
        end
        if next(deathBlame) then
            detailedData.deathBlame = deathBlame
        end
    end

    -- Insert at position 1 (newest first), trim to max
    table.insert(db.runs, 1, runRecord)
    while #db.runs > db.settings.maxStoredRuns do
        table.remove(db.runs)
    end

    -- Update profiles for all players
    MPI.UpdateProfiles(runRecord)

    -- Update personal stats
    MPI.UpdatePersonalStats()

    -- Rebuild name index
    MPI.RebuildNameIndex()

    -- Update export data for companion app
    MPI.BuildExportData()

    -- Clear active run state
    MPI._activeRun = nil
    MPI._encounterLog = {}
    MPI._leavers = {}
    MPI._rosterSnapshot = {}
    MPI._surrendered = false
end

--- Update/create profiles for all players in a run.
-- @param runRecord table  The completed run record
function MPI.UpdateProfiles(runRecord)
    if not runRecord or not runRecord.players then return end

    local myGUID = UnitGUID("player")

    for guid, pData in pairs(runRecord.players) do
        local prof = db.profiles[guid]
        if not prof then
            prof = {
                name           = pData.name,
                class          = pData.class,
                primaryRole    = pData.role,
                runsTracked    = 0,
                abandonedRuns  = 0,
                avgMPI         = 0,
                recentScores   = {},
                previousScores = {},
                trend          = "stable",
                bestMPI        = 0,
                bestDungeon    = "",
                badges         = {},
                dungeonMastery = {},
                pressureCurve  = {},
                peakLevel      = "",
                roleHistory    = {},
                byRole         = {},  -- per-role scores: {TANK={avg,runs,recent}, HEALER={...}, DPS={...}}
                tags           = {},  -- personal tags: {"great tank", "leaves often", etc.}
                note           = "",
                lastSeen       = 0,
                source         = "local",
            }
            db.profiles[guid] = prof
        end

        prof.name = pData.name or prof.name
        prof.class = pData.class or prof.class
        prof.lastSeen = time()
        prof.source = "local"

        -- Track role history (most recent first)
        local currentRole = pData.role or "DAMAGER"
        if not prof.roleHistory then prof.roleHistory = {} end
        if prof.roleHistory[1] ~= currentRole then
            table.insert(prof.roleHistory, 1, currentRole)
            if #prof.roleHistory > 5 then
                prof.roleHistory[#prof.roleHistory] = nil
            end
        end
        prof.primaryRole = currentRole

        -- Update run count
        prof.runsTracked = (prof.runsTracked or 0) + 1
        -- Penalize the player who INITIATED the abandon (left first), regardless
        -- of run result — the key may still have completed without them.
        if runRecord.leavers then
            for _, lInfo in pairs(runRecord.leavers) do
                if lInfo.isInitiator and lInfo.name == pData.name then
                    prof.abandonedRuns = (prof.abandonedRuns or 0) + 1
                    break
                end
            end
        end

        -- Rotate scores: push current to recent, shift old recent to previous
        if not prof.recentScores then prof.recentScores = {} end
        if not prof.previousScores then prof.previousScores = {} end

        table.insert(prof.recentScores, 1, pData.mpiScore)
        while #prof.recentScores > TREND_WINDOW do
            -- Move overflow to previousScores
            local overflow = table.remove(prof.recentScores)
            table.insert(prof.previousScores, 1, overflow)
        end
        while #prof.previousScores > TREND_WINDOW do
            table.remove(prof.previousScores)
        end

        -- Compute weighted averages for MPI and all dimension scores
        local wSums = { mpi = 0, awareness = 0, survival = 0, output = 0, utility = 0, consistency = 0 }
        local weightTotal = 0
        for i, run in ipairs(db.runs) do
            local pd = run.players and run.players[guid]
            if pd then
                local w = MPI.ComputeKeyWeight(run.keyLevel)
                wSums.mpi         = wSums.mpi         + (pd.mpiScore or 0) * w
                wSums.awareness   = wSums.awareness   + (pd.awarenessScore or 0) * w
                wSums.survival    = wSums.survival    + (pd.survivalScore or 0) * w
                wSums.output      = wSums.output      + (pd.outputScore or 0) * w
                wSums.utility     = wSums.utility     + (pd.utilityScore or 0) * w
                wSums.consistency = wSums.consistency  + (pd.consistencyScore or 0) * w
                weightTotal = weightTotal + w
            end
            if i >= 20 then break end -- only consider last 20 runs for average
        end
        if weightTotal > 0 then
            prof.avgMPI           = floor(wSums.mpi / weightTotal + 0.5)
            prof.awarenessScore   = floor(wSums.awareness / weightTotal + 0.5)
            prof.survivalScore    = floor(wSums.survival / weightTotal + 0.5)
            prof.outputScore      = floor(wSums.output / weightTotal + 0.5)
            prof.utilityScore     = floor(wSums.utility / weightTotal + 0.5)
            prof.consistencyScore = floor(wSums.consistency / weightTotal + 0.5)
        end

        -- Best MPI
        if (pData.mpiScore or 0) > (prof.bestMPI or 0) then
            prof.bestMPI = pData.mpiScore
            prof.bestDungeon = runRecord.dungeonName
        end

        -- Trend
        prof.trend = MPI.ComputeTrend(prof.recentScores, prof.previousScores)

        -- Per-role score tracking (prevents role-switching abuse)
        if not prof.byRole then prof.byRole = {} end
        local roleKey = (currentRole == "DAMAGER") and "DPS" or currentRole
        if not prof.byRole[roleKey] then
            prof.byRole[roleKey] = { avg = 0, runs = 0, recentScores = {} }
        end
        local roleData = prof.byRole[roleKey]
        roleData.runs = (roleData.runs or 0) + 1
        if not roleData.recentScores then roleData.recentScores = {} end
        table.insert(roleData.recentScores, 1, pData.mpiScore)
        while #roleData.recentScores > SCORE_WINDOW do
            table.remove(roleData.recentScores)
        end
        local roleSum = 0
        for _, s in ipairs(roleData.recentScores) do roleSum = roleSum + s end
        roleData.avg = floor(roleSum / #roleData.recentScores + 0.5)

        -- Update dungeon mastery for this dungeon
        if not prof.dungeonMastery then prof.dungeonMastery = {} end
        local mapID = runRecord.dungeonMapID
        if mapID then
            if not prof.dungeonMastery[mapID] then
                prof.dungeonMastery[mapID] = { runs = {}, level = "LEARNING" }
            end
            local dm = prof.dungeonMastery[mapID]
            table.insert(dm.runs, 1, {
                score = pData.mpiScore,
                timed = runRecord.result == "timed",
            })
            while #dm.runs > 10 do table.remove(dm.runs) end
            dm.level = MPI.ComputeDungeonMastery(dm.runs)
        end

        -- Pressure curve (only for local player — we have full run history)
        if guid == myGUID then
            local pressureRuns = {}
            for _, run in ipairs(db.runs) do
                if run.players and run.players[guid] then
                    pressureRuns[#pressureRuns + 1] = {
                        keyLevel = run.keyLevel,
                        score = run.players[guid].mpiScore,
                    }
                end
            end
            prof.pressureCurve, prof.peakLevel = MPI.ComputePressureCurve(pressureRuns)
        end

        -- Profile-level badges
        prof.badges = MPI.DetermineProfileBadges(prof)

        -- Merge run badges (keep unique set of recently earned)
        if pData.badges then
            if not prof.recentBadges then prof.recentBadges = {} end
            for _, bid in ipairs(pData.badges) do
                prof.recentBadges[bid] = time()
            end
        end
    end
end

--- Recompute personal aggregate stats from run history.
function MPI.UpdatePersonalStats()
    if not db then return end
    local myGUID = UnitGUID("player")
    if not myGUID then return end

    local totalRuns, timedRuns = 0, 0
    local totalScore, scoreCount = 0, 0
    local weeklyRuns, weeklyTimed, weeklyScore, weeklyCount = 0, 0, 0, 0
    local weekStart = db.personal.weekStart or 0
    local byDungeon = {}

    for _, run in ipairs(db.runs) do
        if run.players and run.players[myGUID] then
            local myScore = run.players[myGUID].mpiScore or 0
            totalRuns = totalRuns + 1
            totalScore = totalScore + myScore
            scoreCount = scoreCount + 1

            if run.result == "timed" then timedRuns = timedRuns + 1 end

            -- Weekly
            if (run.timestamp or 0) >= weekStart then
                weeklyRuns = weeklyRuns + 1
                weeklyScore = weeklyScore + myScore
                weeklyCount = weeklyCount + 1
                if run.result == "timed" then weeklyTimed = weeklyTimed + 1 end
            end

            -- Per-dungeon
            local mapID = run.dungeonMapID
            if mapID then
                if not byDungeon[mapID] then
                    byDungeon[mapID] = { runs = 0, timedRuns = 0, totalScore = 0, bestMPI = 0, bestLevel = 0, name = run.dungeonName }
                end
                local bd = byDungeon[mapID]
                bd.runs = bd.runs + 1
                bd.totalScore = bd.totalScore + myScore
                if run.result == "timed" then bd.timedRuns = bd.timedRuns + 1 end
                if myScore > bd.bestMPI then bd.bestMPI = myScore end
                if (run.keyLevel or 0) > bd.bestLevel then bd.bestLevel = run.keyLevel end
            end
        end
    end

    -- Compute averages
    for mapID, bd in pairs(byDungeon) do
        bd.avgMPI = bd.runs > 0 and floor(bd.totalScore / bd.runs + 0.5) or 0
    end

    -- Consistency from profile
    local myProfile = db.profiles[myGUID]
    local consistencyScore = 75
    if myProfile and myProfile.recentScores then
        consistencyScore = MPI.ScoreConsistency(myProfile.recentScores)
    end

    db.personal.totalRuns  = totalRuns
    db.personal.timedRuns  = timedRuns
    db.personal.avgMPI     = scoreCount > 0 and floor(totalScore / scoreCount + 0.5) or 0
    db.personal.consistencyScore = consistencyScore
    db.personal.byDungeon  = byDungeon
    db.personal.weeklyRuns = weeklyRuns
    db.personal.weeklyTimedRuns = weeklyTimed
    db.personal.weeklyAvgMPI = weeklyCount > 0 and floor(weeklyScore / weeklyCount + 0.5) or 0
end


-- ============================================================================
-- §6  PERSONAL DASHBOARD (Dungeon Finder Hero)
-- ============================================================================

local dashRefs = {} -- frame references for dashboard elements

function MPI.BuildDungeonDashboard(parentFrame)
    if MPI._dashboardBuilt or not parentFrame then return end

    -- Container frame anchored to bottom-left of hero, above the progress bar
    local container = CreateFrame("Frame", nil, parentFrame)
    container:SetSize(400, 40)
    container:SetPoint("BOTTOMLEFT", parentFrame, "BOTTOMLEFT", 16, 10)
    container:SetFrameLevel(parentFrame:GetFrameLevel() + 5)

    -- MPI Score (large)
    local scoreText = container:CreateFontString(nil, "OVERLAY")
    TrySetFont(scoreText, TITLE_FONT, 20, "OUTLINE")
    scoreText:SetPoint("LEFT", container, "LEFT", 0, 4)
    dashRefs.scoreText = scoreText

    -- "MPI" label above score
    local mpiLabel = container:CreateFontString(nil, "OVERLAY")
    TrySetFont(mpiLabel, BODY_FONT, 9, "")
    mpiLabel:SetPoint("BOTTOMLEFT", scoreText, "TOPLEFT", 1, 1)
    mpiLabel:SetText("MPI RATING")
    mpiLabel:SetTextColor(0.6, 0.6, 0.6)
    dashRefs.mpiLabel = mpiLabel

    -- Tier badge (S/A/B/C/D)
    local tierText = container:CreateFontString(nil, "OVERLAY")
    TrySetFont(tierText, TITLE_FONT, 14, "OUTLINE")
    tierText:SetPoint("LEFT", scoreText, "RIGHT", 6, 0)
    dashRefs.tierText = tierText

    -- Trend arrow
    local trendText = container:CreateFontString(nil, "OVERLAY")
    TrySetFont(trendText, TITLE_FONT, 14, "OUTLINE")
    trendText:SetPoint("LEFT", tierText, "RIGHT", 6, 0)
    dashRefs.trendText = trendText

    -- Weekly summary line
    local weeklyText = container:CreateFontString(nil, "OVERLAY")
    TrySetFont(weeklyText, BODY_FONT, 10, "")
    weeklyText:SetPoint("TOPLEFT", scoreText, "BOTTOMLEFT", 0, -2)
    weeklyText:SetTextColor(0.55, 0.55, 0.55)
    dashRefs.weeklyText = weeklyText

    dashRefs.container = container
    MPI._dashboardBuilt = true
end

function MPI.UpdateDungeonHeroDashboard(parentFrame)
    if not db or not db.settings.enabled or not db.settings.showInHero then return end
    if not MPI._apiAvailable then return end
    if db.personal.totalRuns == 0 then
        if dashRefs.container then dashRefs.container:Hide() end
        return
    end

    if not MPI._dashboardBuilt then
        MPI.BuildDungeonDashboard(parentFrame)
    end
    if not dashRefs.container then return end

    local p = db.personal
    local score = p.avgMPI or 0
    local tier, r, g, b = MPI.GetScoreTier(score)

    dashRefs.scoreText:SetText(tostring(score))
    dashRefs.scoreText:SetTextColor(r, g, b)

    dashRefs.tierText:SetText(tier)
    dashRefs.tierText:SetTextColor(r, g, b, 0.7)

    -- Trend arrow
    local myGUID = UnitGUID("player")
    local myProf = myGUID and db.profiles[myGUID]
    local trend = myProf and myProf.trend or "stable"
    if trend == "up" then
        dashRefs.trendText:SetText("+")
        dashRefs.trendText:SetTextColor(0.35, 0.88, 0.45)
    elseif trend == "down" then
        dashRefs.trendText:SetText("-")
        dashRefs.trendText:SetTextColor(1.00, 0.35, 0.35)
    else
        dashRefs.trendText:SetText("=")
        dashRefs.trendText:SetTextColor(0.95, 0.80, 0.20)
    end

    -- Weekly summary
    local weekLine = "This week: " .. (p.weeklyRuns or 0) .. " runs"
    if (p.weeklyTimedRuns or 0) > 0 then
        weekLine = weekLine .. " | " .. p.weeklyTimedRuns .. " timed"
    end
    if (p.weeklyRuns or 0) > 0 then
        weekLine = weekLine .. " | Avg: " .. (p.weeklyAvgMPI or 0)
    end
    dashRefs.weeklyText:SetText(weekLine)

    dashRefs.container:Show()
end


-- ============================================================================
-- §7  PREMADE HERO MPI PILL
-- ============================================================================

local function CreateMPIPill(parent)
    -- Matches the existing hero pill style: single line (dot | LABEL  Value)
    local pill = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    pill:SetSize(110, 28)
    pill:SetBackdrop({
        bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    pill:SetBackdropColor(0.06, 0.06, 0.08, 0.75)
    pill:SetBackdropBorderColor(0.20, 0.20, 0.25, 0.5)

    -- Accent dot (left edge)
    local dot = pill:CreateTexture(nil, "OVERLAY", nil, 2)
    dot:SetSize(3, 18)
    dot:SetPoint("LEFT", pill, "LEFT", 3, 0)
    dot:SetColorTexture(1, 1, 1)
    pill._dot = dot

    -- Label (left side, muted)
    local label = pill:CreateFontString(nil, "OVERLAY")
    TrySetFont(label, BODY_FONT, 9, "OUTLINE")
    label:SetPoint("LEFT", dot, "RIGHT", 6, 0)
    label:SetTextColor(0.55, 0.55, 0.55)
    label:SetText("MPI")
    pill._label = label

    -- Value (right side, bright)
    local value = pill:CreateFontString(nil, "OVERLAY")
    TrySetFont(value, TITLE_FONT, 11, "OUTLINE")
    value:SetPoint("LEFT", label, "RIGHT", 4, 0)
    value:SetPoint("RIGHT", pill, "RIGHT", -8, 0)
    value:SetJustifyH("RIGHT")
    pill._value = value

    return pill
end

function MPI.UpdatePremadeHeroPill(R)
    if not db or not db.settings.enabled or not db.settings.showInHero then return end
    if not R then return end

    -- Find anchor: the role pill
    local anchor = R.premadeHeroRolePill
    if not anchor then return end

    -- Create pill lazily
    if not MPI._heroPill then
        MPI._heroPill = CreateMPIPill(anchor:GetParent())
        MPI._heroPill:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
    end

    local pill = MPI._heroPill
    local myGUID = UnitGUID("player")
    local myProf = myGUID and db.profiles[myGUID]

    if myProf and myProf.avgMPI and myProf.avgMPI > 0 then
        local score = myProf.avgMPI
        local tier, r, g, b = MPI.GetScoreTier(score)
        pill._value:SetText(score .. " " .. tier)
        pill._value:SetTextColor(r, g, b)
        pill._dot:SetColorTexture(r, g, b)
    else
        pill._value:SetText("N/A")
        pill._value:SetTextColor(0.45, 0.45, 0.45)
        pill._dot:SetColorTexture(0.45, 0.45, 0.45)
    end

    pill:Show()
end


-- ============================================================================
-- §8  LISTING ROW MPI DOTS + TOOLTIPS
-- ============================================================================

local function ShowMPITooltip(frame, guid, prof, dungeonMapID)
    if not prof then return end
    GameTooltip:SetOwner(frame, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()

    -- Player name in class color
    local cr, cg, cb = GetClassColor(prof.class)
    GameTooltip:AddLine(prof.name or "Unknown", cr, cg, cb)

    -- MPI Rating + primary role
    local score = prof.avgMPI or 0
    local tier, r, g, b = MPI.GetScoreTier(score)
    local trendArrow = prof.trend == "up" and " +" or prof.trend == "down" and " -" or ""
    local roleLabel = prof.primaryRole == "TANK" and "Tank" or prof.primaryRole == "HEALER" and "Healer" or "DPS"
    GameTooltip:AddLine("MPI: " .. score .. " (" .. tier .. ")" .. trendArrow .. "  as " .. roleLabel, r, g, b)

    -- Education subtitle: what MPI measures
    GameTooltip:AddLine("Measures how they play, not just what keys they've completed.", 0.55, 0.55, 0.55)

    -- Trust source line
    local source = prof.source or "network"
    if source == "local" then
        local runCount = prof.runsTracked or 0
        GameTooltip:AddLine("Verified: you ran " .. runCount .. " key" .. (runCount ~= 1 and "s" or "") .. " together", 0.35, 0.88, 0.45)
    elseif source == "guild" then
        GameTooltip:AddLine("Verified: observed by your guild", 0.70, 0.85, 1.00)
    elseif source == "network-observed" then
        local obsCount = prof._observerCount or 1
        GameTooltip:AddLine("Verified: observed by " .. obsCount .. " MidnightUI player" .. (obsCount ~= 1 and "s" or ""), 0.80, 0.80, 0.80)
    else
        GameTooltip:AddLine("Unverified: self-reported by player", 0.50, 0.50, 0.50)
    end

    -- Dimension breakdown (compact colored line)
    local awr = prof.awarenessScore or 0
    local srv = prof.survivalScore or 0
    local out = prof.outputScore or 0
    local utl = prof.utilityScore or 0
    local con = prof.consistencyScore or 0
    if awr + srv + out + utl + con > 0 then
        local function dc(v)
            if v >= 75 then return "59e073"
            elseif v >= 50 then return "f2cc33"
            elseif v >= 25 then return "ff8c42"
            else return "ff5959" end
        end
        local dimLine = format(
            "|cff%sAWR %d|r  |cff%sSRV %d|r  |cff%sOUT %d|r  |cff%sUTL %d|r  |cff%sCON %d|r",
            dc(awr), awr, dc(srv), srv, dc(out), out, dc(utl), utl, dc(con), con
        )
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(dimLine)
    end

    -- Discrepancy warning
    if prof._discrepancy and prof._claimedScore then
        GameTooltip:AddLine("Score discrepancy: claims " .. prof._claimedScore .. ", observed avg " .. score, 1.0, 0.55, 0.20)
    end

    -- Per-role breakdown (if they play multiple roles)
    if prof.byRole then
        local roleCount = 0
        for _ in pairs(prof.byRole) do roleCount = roleCount + 1 end
        if roleCount > 1 then
            for roleName, roleData in pairs(prof.byRole) do
                if roleData.runs and roleData.runs > 0 then
                    local rTier, rr, rg, rb = MPI.GetScoreTier(roleData.avg or 0)
                    local rLabel = roleName == "TANK" and "Tank" or roleName == "HEALER" and "Healer" or "DPS"
                    GameTooltip:AddLine("  " .. rLabel .. ": " .. (roleData.avg or 0) .. " (" .. rTier .. ") — " .. roleData.runs .. " runs", rr, rg, rb)
                end
            end
        end
    end

    -- Dungeon mastery for the listed dungeon
    if dungeonMapID and prof.dungeonMastery and prof.dungeonMastery[dungeonMapID] then
        local dm = prof.dungeonMastery[dungeonMapID]
        local ml = MASTERY_LEVELS[dm.level]
        if ml then
            GameTooltip:AddLine("This dungeon: " .. ml.label, 0.7, 0.7, 0.7)
        end
    end

    -- Pressure curve
    if prof.peakLevel and prof.peakLevel ~= "" then
        GameTooltip:AddLine("Peaks at " .. prof.peakLevel, 0.7, 0.7, 0.7)
    end

    -- Badges
    local badgeTexts = {}
    if prof.badges then
        for _, bid in ipairs(prof.badges) do
            local key = BADGE_ID_TO_KEY[bid]
            if key and BADGE_DEFS[key] then
                badgeTexts[#badgeTexts + 1] = BADGE_DEFS[key].label
            end
        end
    end
    if #badgeTexts > 0 then
        GameTooltip:AddLine(table.concat(badgeTexts, " | "), 0.85, 0.75, 0.30)
    end

    -- Smart alerts
    local alerts = MPI.GenerateSmartAlerts(prof, dungeonMapID)
    for _, alert in ipairs(alerts) do
        local ar, ag, ab = 0.7, 0.7, 0.7
        if alert.severity == "warning" then ar, ag, ab = 1.0, 0.55, 0.20
        elseif alert.severity == "positive" then ar, ag, ab = 0.35, 0.88, 0.45 end
        GameTooltip:AddLine(alert.text, ar, ag, ab, true)
    end

    -- Completion rate
    local total = prof.runsTracked or 0
    local abandoned = prof.abandonedRuns or 0
    if total >= 3 then
        local completionPct = floor((total - abandoned) / total * 100)
        GameTooltip:AddLine(total .. " runs tracked | " .. completionPct .. "% completed", 0.5, 0.5, 0.5)
    end

    -- Personal tags (only your own labels — private, never shared)
    if prof.tags and #prof.tags > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Your tags: " .. table.concat(prof.tags, ", "), 0.70, 0.85, 1.00, true)
    end

    -- Personal note
    if prof.note and prof.note ~= "" then
        if not prof.tags or #prof.tags == 0 then GameTooltip:AddLine(" ") end
        GameTooltip:AddLine("Note: " .. prof.note, 0.85, 0.85, 0.60, true)
    end

    GameTooltip:Show()
end

--- Helper: apply trust visual to a dot frame.
local function ApplyTrustVisual(dot, source, r, g, b)
    if not dot then return end
    if source == "local" or source == "guild" or source == "network-observed" then
        -- Verified: solid dot
        dot._tex:SetColorTexture(r, g, b, 0.9)
        dot._tex:Show()
        dot._border:Hide()
        dot:SetAlpha(1.0)
    else
        -- Claimed: hollow ring (border only)
        dot._tex:SetColorTexture(r, g, b, 0.15) -- faint fill
        dot._tex:Show()
        dot._border:SetColorTexture(r, g, b, 0.6)
        dot._border:Show()
        dot:SetAlpha(0.5)
    end
end

function MPI.UpdateListingRowMPI(row, info)
    if not db or not db.settings.enabled or not db.settings.showInRows then return end
    if not row or not info then return end

    -- Lazily create MPI dot on this row
    if not row._mpiDot then
        local dot = CreateFrame("Frame", nil, row)
        dot:SetSize(10, 10)
        dot:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, -8)
        dot:SetFrameLevel(row:GetFrameLevel() + 3)

        local tex = dot:CreateTexture(nil, "OVERLAY")
        tex:SetAllPoints()
        tex:SetColorTexture(1, 1, 1)
        dot._tex = tex

        -- Border texture for hollow ring (claimed scores)
        local border = dot:CreateTexture(nil, "BORDER")
        border:SetAllPoints()
        border:SetColorTexture(1, 1, 1, 0.5)
        dot._border = border
        border:Hide()

        dot:EnableMouse(true)
        dot:SetScript("OnEnter", function(self)
            if self._guid and self._prof then
                ShowMPITooltip(self, self._guid, self._prof, self._dungeonMapID)
            end
        end)
        dot:SetScript("OnLeave", function() GameTooltip:Hide() end)

        row._mpiDot = dot
    end

    local dot = row._mpiDot

    -- Look up leader by name
    local leaderName = info.leaderName
    if not leaderName then
        dot:Hide()
        return
    end

    local guid, prof = MPI.LookupByName(leaderName)
    if not prof then
        dot:Hide()
        return
    end

    local score = prof.avgMPI or 0
    local _, r, g, b = MPI.GetScoreTier(score)
    dot._guid = guid
    dot._prof = prof
    dot._dungeonMapID = nil

    -- Apply trust visual: solid for verified, hollow ring for claimed
    ApplyTrustVisual(dot, prof.source or "network", r, g, b)
    dot:Show()
end


-- ============================================================================
-- §10  GROUP SYNERGY PANEL (Intel Sidebar)
-- ============================================================================

local sidebarRefs = {}

local function CreateGlassPanelMPI(parent, w, h)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetSize(w, h)
    panel:SetBackdrop({
        bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    panel:SetBackdropColor(0.06, 0.06, 0.08, 0.75)
    panel:SetBackdropBorderColor(0.20, 0.20, 0.25, 0.5)

    -- Top frost line
    local frost = panel:CreateTexture(nil, "ARTWORK")
    frost:SetHeight(1)
    frost:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
    frost:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
    frost:SetColorTexture(0.4, 0.4, 0.5, 0.15)

    return panel
end

function MPI.BuildSidebarSection(sidebarFrame)
    if MPI._sidebarBuilt or not sidebarFrame then return end

    local panel = CreateGlassPanelMPI(sidebarFrame, 228, 140)
    panel:SetPoint("BOTTOMLEFT", sidebarFrame, "BOTTOMLEFT", 16, 16)
    panel:SetPoint("BOTTOMRIGHT", sidebarFrame, "BOTTOMRIGHT", -16, 16)

    -- Header
    local header = panel:CreateFontString(nil, "OVERLAY")
    TrySetFont(header, BODY_FONT, 10, "")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    header:SetText("TEAM MPI")
    header:SetTextColor(0.55, 0.55, 0.55)
    sidebarRefs.header = header

    -- Team summary line
    local summary = panel:CreateFontString(nil, "OVERLAY")
    TrySetFont(summary, BODY_FONT, 9, "")
    summary:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -10, -8)
    summary:SetTextColor(0.5, 0.5, 0.5)
    sidebarRefs.summary = summary

    -- Player rows (up to 5)
    sidebarRefs.rows = {}
    for i = 1, 5 do
        local row = CreateFrame("Frame", nil, panel)
        row:SetSize(208, 18)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -22 - (i - 1) * 20)

        local nameFs = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFs, BODY_FONT, 10, "")
        nameFs:SetPoint("LEFT", row, "LEFT", 0, 0)
        nameFs:SetWidth(130)
        nameFs:SetJustifyH("LEFT")
        nameFs:SetWordWrap(false)
        row._name = nameFs

        local scoreFs = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(scoreFs, TITLE_FONT, 10, "")
        scoreFs:SetPoint("RIGHT", row, "RIGHT", -20, 0)
        row._score = scoreFs

        local trendFs = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(trendFs, TITLE_FONT, 10, "")
        trendFs:SetPoint("LEFT", scoreFs, "RIGHT", 4, 0)
        row._trend = trendFs

        sidebarRefs.rows[i] = row
    end

    -- Smart alerts area
    local alertFs = panel:CreateFontString(nil, "OVERLAY")
    TrySetFont(alertFs, BODY_FONT, 9, "")
    alertFs:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 6)
    alertFs:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 6)
    alertFs:SetTextColor(0.7, 0.6, 0.3)
    alertFs:SetWordWrap(true)
    alertFs:SetJustifyH("LEFT")
    sidebarRefs.alertText = alertFs

    sidebarRefs.panel = panel
    MPI._sidebarBuilt = true
end

function MPI.UpdateSidebarTeamMPI(sidebarFrame, selectedResultID)
    if not db or not db.settings.enabled or not db.settings.showInSidebar then return end

    if not MPI._sidebarBuilt then
        MPI.BuildSidebarSection(sidebarFrame)
    end
    if not sidebarRefs.panel then return end

    -- No selection — hide panel
    if not selectedResultID then
        sidebarRefs.panel:Hide()
        return
    end

    -- Get group members
    local ok, info = pcall(C_LFGList.GetSearchResultInfo, selectedResultID)
    if not ok or not info then
        sidebarRefs.panel:Hide()
        return
    end

    local numMembers = info.numMembers or 0
    local knownCount, totalScore, rowIdx = 0, 0, 0
    local hasKicker = false
    local groupAlerts = {}

    for mi = 1, min(numMembers, 5) do
        local mOk, mRole, mClass, mClassFile, mName = pcall(C_LFGList.GetSearchResultMemberInfo, selectedResultID, mi)
        if mOk and mName then
            rowIdx = rowIdx + 1
            local row = sidebarRefs.rows[rowIdx]
            if row then
                local guid, prof = MPI.LookupByName(mName)
                local cr, cg, cb = GetClassColor(mClassFile)

                row._name:SetText(mName)
                row._name:SetTextColor(cr, cg, cb)

                if prof then
                    knownCount = knownCount + 1
                    local score = prof.avgMPI or 0
                    totalScore = totalScore + score
                    local _, sr, sg, sb = MPI.GetScoreTier(score)
                    row._score:SetText(tostring(score))
                    row._score:SetTextColor(sr, sg, sb)

                    local trend = prof.trend or "stable"
                    if trend == "up" then
                        row._trend:SetText("+")
                        row._trend:SetTextColor(0.35, 0.88, 0.45)
                    elseif trend == "down" then
                        row._trend:SetText("-")
                        row._trend:SetTextColor(1.0, 0.35, 0.35)
                    else
                        row._trend:SetText("")
                    end

                    -- Check for kicker badge
                    if prof.badges then
                        for _, bid in ipairs(prof.badges) do
                            if bid == BADGE_DEFS.ACTIVE_KICKER.id then hasKicker = true end
                        end
                    end
                else
                    row._score:SetText("?")
                    row._score:SetTextColor(0.4, 0.4, 0.4)
                    row._trend:SetText("")
                end

                row:Show()
            end
        end
    end

    -- Hide unused rows
    for i = rowIdx + 1, 5 do
        if sidebarRefs.rows[i] then sidebarRefs.rows[i]:Hide() end
    end

    -- Team summary
    if knownCount > 0 then
        local avgTeam = floor(totalScore / knownCount + 0.5)
        local _, tr, tg, tb = MPI.GetScoreTier(avgTeam)
        local teamTier = MPI.GetScoreTier(avgTeam)
        sidebarRefs.summary:SetText(knownCount .. "/" .. numMembers .. " known — " .. teamTier .. " avg")
        sidebarRefs.summary:SetTextColor(tr, tg, tb)
    else
        sidebarRefs.summary:SetText(numMembers .. " members — no MPI data")
        sidebarRefs.summary:SetTextColor(0.45, 0.45, 0.45)
    end

    -- Group-level smart alerts
    if knownCount > 0 and not hasKicker then
        groupAlerts[#groupAlerts + 1] = "No known interrupter"
    end

    if #groupAlerts > 0 then
        sidebarRefs.alertText:SetText(table.concat(groupAlerts, " | "))
        sidebarRefs.alertText:Show()
    else
        sidebarRefs.alertText:SetText("")
    end

    -- Resize panel based on content
    local panelH = 28 + (rowIdx * 20) + (#groupAlerts > 0 and 18 or 0)
    sidebarRefs.panel:SetHeight(max(60, panelH))
    sidebarRefs.panel:Show()
end


-- ============================================================================
-- §11  SOCIAL FEATURES: TAGS, NOTES, SETTINGS, SLASH COMMAND
-- ============================================================================

--- Add a personal tag to a player (only you see these).
-- @param guid string  Player GUID
-- @param tag  string  Tag text (e.g. "great tank", "leaves keys", "friendly")
function MPI.AddTag(guid, tag)
    if not guid or not tag or tag == "" then return end
    if not db or not db.profiles[guid] then return end
    if not db.profiles[guid].tags then db.profiles[guid].tags = {} end
    -- Avoid duplicates
    for _, existing in ipairs(db.profiles[guid].tags) do
        if existing == tag then return end
    end
    table.insert(db.profiles[guid].tags, 1, tag)
    -- Cap at 5 tags per player
    while #db.profiles[guid].tags > 5 do
        table.remove(db.profiles[guid].tags)
    end
end

--- Remove a personal tag from a player.
-- @param guid string  Player GUID
-- @param tag  string  Tag text to remove
function MPI.RemoveTag(guid, tag)
    if not guid or not tag then return end
    if not db or not db.profiles[guid] or not db.profiles[guid].tags then return end
    for i = #db.profiles[guid].tags, 1, -1 do
        if db.profiles[guid].tags[i] == tag then
            table.remove(db.profiles[guid].tags, i)
            return
        end
    end
end

--- Set a personal note on a player (only you see this).
function MPI.SetNote(guid, text)
    if not guid or not db or not db.profiles[guid] then return end
    db.profiles[guid].note = text or ""
end

--- Slash command handler
local function OnSlashCommand(msg)
    if not db then
        print("|cff00ccffMPI:|r Not initialized yet.")
        return
    end

    msg = (msg or ""):lower():trim()

    if msg == "" then
        -- Print current stats
        local p = db.personal
        local myGUID = UnitGUID("player")
        local myProf = myGUID and db.profiles[myGUID]
        local score = p.avgMPI or 0
        local tier, r, g, b = MPI.GetScoreTier(score)

        print("|cff00ccffMPI Rating:|r " .. score .. " (" .. tier .. ")")
        print("|cff888888MPI scores how you play (mechanics, survival, output, kicks, consistency)|r")
        print("|cff888888not just what keys you've completed. Dimension breakdown:|r")
        -- Dimension breakdown
        local function dimStr(label, val)
            if val >= 75 then return "|cff59e073" .. label .. " " .. val .. "|r"
            elseif val >= 50 then return "|cfff2cc33" .. label .. " " .. val .. "|r"
            elseif val >= 25 then return "|cffff8c42" .. label .. " " .. val .. "|r"
            else return "|cffff5959" .. label .. " " .. val .. "|r" end
        end
        local myGUID0 = UnitGUID("player")
        local myProf0 = myGUID0 and db.profiles[myGUID0]
        if myProf0 then
            print("  " .. dimStr("AWR", myProf0.awarenessScore or 0) .. "  " .. dimStr("SRV", myProf0.survivalScore or 0) .. "  " .. dimStr("OUT", myProf0.outputScore or 0) .. "  " .. dimStr("UTL", myProf0.utilityScore or 0) .. "  " .. dimStr("CON", myProf0.consistencyScore or 0))
        end
        print("|cff00ccffRuns:|r " .. (p.totalRuns or 0) .. " total | " .. (p.timedRuns or 0) .. " timed")
        print("|cff00ccffThis week:|r " .. (p.weeklyRuns or 0) .. " runs | Avg " .. (p.weeklyAvgMPI or 0))
        if myProf then
            print("|cff00ccffTrend:|r " .. (myProf.trend or "stable") .. " | Best: " .. (myProf.bestMPI or 0))
            if myProf.peakLevel and myProf.peakLevel ~= "" then
                print("|cff00ccffPeak level:|r " .. myProf.peakLevel)
            end
            -- Per-role breakdown
            if myProf.byRole then
                for roleName, roleData in pairs(myProf.byRole) do
                    if roleData.runs and roleData.runs > 0 then
                        local rLabel = roleName == "TANK" and "Tank" or roleName == "HEALER" and "Healer" or "DPS"
                        print("|cff00ccff  " .. rLabel .. ":|r " .. (roleData.avg or 0) .. " avg (" .. roleData.runs .. " runs)")
                    end
                end
            end
        end
        local profCount = 0
        for _ in pairs(db.profiles) do profCount = profCount + 1 end
        print("|cff00ccffProfiles:|r " .. profCount .. " players tracked")

    elseif msg == "toggle" then
        db.settings.enabled = not db.settings.enabled
        print("|cff00ccffMPI:|r " .. (db.settings.enabled and "Enabled" or "Disabled"))

    elseif msg == "reset" then
        print("|cff00ccffMPI:|r Type |cffff8800/mpi reset confirm|r to delete all MPI data.")

    elseif msg == "reset confirm" then
        _G.MidnightUI_MPI = nil
        MPI.EnsureDB()
        print("|cff00ccffMPI:|r All data cleared.")

    elseif msg:sub(1, 4) == "tag " then
        -- /mpi tag PlayerName great tank
        local rest = msg:sub(5)
        local playerName, tag = rest:match("^(%S+)%s+(.+)$")
        if playerName and tag then
            local guid = db._nameIndex[playerName]
            -- Try case-insensitive match
            if not guid then
                for name, g in pairs(db._nameIndex) do
                    if name:lower() == playerName:lower() then guid = g; break end
                end
            end
            if guid then
                MPI.AddTag(guid, tag)
                print("|cff00ccffMPI:|r Tagged " .. playerName .. " with: " .. tag)
            else
                print("|cff00ccffMPI:|r Player '" .. playerName .. "' not found in your MPI data.")
            end
        else
            print("|cff00ccffUsage:|r /mpi tag PlayerName your tag text")
        end

    else
        print("|cff00ccffMPI Commands:|r")
        print("  /mpi : Show your MPI stats and dimension breakdown")
        print("  /mpi toggle : Enable or disable MPI")
        print("  /mpi reset : Clear all MPI data")
        print("  /mpi tag Name text : Add a personal tag to a player")
        print("|cff888888MPI measures how you play across 5 dimensions using combat data.|r")
        print("|cff888888It is not the same as IO score, which tracks key completion.|r")
    end
end

SLASH_MPI1 = "/mpi"
SlashCmdList["MPI"] = OnSlashCommand



-- (§13 removed — network exchange replaced by companion app sync)


--- Called when applicant list updates — refresh applicant panel UI.
-- Scores come from the community database synced by the companion app.
function MPI.OnApplicantListUpdated(sidebarFrame)
    if not db or not db.settings.enabled then return end

    -- Check if we have a listed group
    local hasListing = C_LFGList.HasActiveEntryInfo and SafeCall(C_LFGList.HasActiveEntryInfo)
    if not hasListing then
        if MPI._applicantPanel then MPI._applicantPanel:Hide() end
        return
    end

    -- Get applicants
    local applicants = SafeCall(C_LFGList.GetApplicants)
    if not applicants then return end

    -- Update applicant panel UI
    MPI.UpdateApplicantPanel(sidebarFrame, applicants)
end


-- ============================================================================
-- §14  APPLICANT REVIEW PANEL
-- ============================================================================

local applicantRefs = {}

function MPI.BuildApplicantPanel(sidebarFrame)
    if MPI._applicantPanel or not sidebarFrame then return end

    local panel = CreateFrame("Frame", nil, sidebarFrame, "BackdropTemplate")
    panel:SetHeight(40) -- will resize dynamically
    panel:SetPoint("TOPLEFT", sidebarFrame, "TOPLEFT", 16, -16)
    panel:SetPoint("TOPRIGHT", sidebarFrame, "TOPRIGHT", -16, -16)
    panel:SetBackdrop({
        bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    panel:SetBackdropColor(0.06, 0.06, 0.08, 0.75)
    panel:SetBackdropBorderColor(0.20, 0.20, 0.25, 0.5)

    local frost = panel:CreateTexture(nil, "ARTWORK")
    frost:SetHeight(1)
    frost:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
    frost:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
    frost:SetColorTexture(0.4, 0.4, 0.5, 0.15)

    local header = panel:CreateFontString(nil, "OVERLAY")
    TrySetFont(header, BODY_FONT, 10, "")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    header:SetText("APPLICANTS")
    header:SetTextColor(0.55, 0.55, 0.55)
    applicantRefs.header = header

    local countBadge = panel:CreateFontString(nil, "OVERLAY")
    TrySetFont(countBadge, BODY_FONT, 9, "")
    countBadge:SetPoint("LEFT", header, "RIGHT", 4, 0)
    countBadge:SetTextColor(0.7, 0.7, 0.7)
    applicantRefs.countBadge = countBadge

    -- Applicant rows (up to 8)
    applicantRefs.rows = {}
    for i = 1, 8 do
        local row = CreateFrame("Frame", nil, panel)
        row:SetSize(196, 24)
        row:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -24 - (i - 1) * 26)

        -- Role icon
        local roleIcon = row:CreateTexture(nil, "ARTWORK")
        roleIcon:SetSize(14, 14)
        roleIcon:SetPoint("LEFT", row, "LEFT", 0, 0)
        row._roleIcon = roleIcon

        -- Name
        local nameFs = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFs, BODY_FONT, 10, "")
        nameFs:SetPoint("LEFT", roleIcon, "RIGHT", 4, 0)
        nameFs:SetWidth(100)
        nameFs:SetJustifyH("LEFT")
        nameFs:SetWordWrap(false)
        row._name = nameFs

        -- MPI dot (trust visual)
        local mpiDot = CreateFrame("Frame", nil, row)
        mpiDot:SetSize(10, 10)
        mpiDot:SetPoint("LEFT", nameFs, "RIGHT", 4, 0)
        local dotTex = mpiDot:CreateTexture(nil, "OVERLAY")
        dotTex:SetAllPoints()
        dotTex:SetColorTexture(1, 1, 1)
        mpiDot._tex = dotTex

        -- For hollow ring (claimed), add a border texture
        local dotBorder = mpiDot:CreateTexture(nil, "BORDER")
        dotBorder:SetAllPoints()
        dotBorder:SetColorTexture(1, 1, 1, 0.5)
        mpiDot._border = dotBorder
        dotBorder:Hide()

        mpiDot:EnableMouse(true)
        mpiDot:SetScript("OnEnter", function(self)
            if self._guid and self._prof then
                ShowMPITooltip(self, self._guid, self._prof, self._dungeonMapID)
            end
        end)
        mpiDot:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row._mpiDot = mpiDot

        -- Score text
        local scoreFs = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(scoreFs, TITLE_FONT, 10, "")
        scoreFs:SetPoint("LEFT", mpiDot, "RIGHT", 4, 0)
        row._score = scoreFs

        -- Mastery indicator
        local masteryFs = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(masteryFs, BODY_FONT, 8, "")
        masteryFs:SetPoint("LEFT", scoreFs, "RIGHT", 4, 0)
        row._mastery = masteryFs

        applicantRefs.rows[i] = row
    end

    MPI._applicantPanel = panel
end

function MPI.UpdateApplicantPanel(sidebarFrame, applicants)
    if not sidebarFrame then return end

    if not MPI._applicantPanel then
        MPI.BuildApplicantPanel(sidebarFrame)
    end
    if not MPI._applicantPanel then return end

    if not applicants or #applicants == 0 then
        MPI._applicantPanel:Hide()
        return
    end

    -- Get the listed dungeon mapID for mastery display
    local listedMapID = nil
    if C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
        listedMapID = SafeCall(C_ChallengeMode.GetActiveChallengeMapID)
    end

    local rowIdx = 0
    for _, applicantID in ipairs(applicants) do
        local appOk, appInfo = pcall(C_LFGList.GetApplicantInfo, applicantID)
        if appOk and appInfo and appInfo.applicationStatus == "applied" then
            local numMembers = appInfo.numMembers or 1
            for mi = 1, numMembers do
                if rowIdx >= 8 then break end
                local mOk, mName, mClass, mClassLocal, mLocSpec
                    = pcall(C_LFGList.GetApplicantMemberInfo, applicantID, mi)
                if mOk and mName then
                    rowIdx = rowIdx + 1
                    local row = applicantRefs.rows[rowIdx]
                    if row then
                        -- Name
                        local cr, cg, cb = GetClassColor(mClass)
                        row._name:SetText(mName)
                        row._name:SetTextColor(cr, cg, cb)

                        -- Role icon
                        local isTank = appInfo.assignedRole == "TANK"
                        local isHealer = appInfo.assignedRole == "HEALER"
                        if row._roleIcon.SetAtlas then
                            row._roleIcon:SetAtlas(isTank and "roleicon-tank" or isHealer and "roleicon-healer" or "roleicon-dps")
                        end

                        -- MPI lookup
                        local guid, prof = MPI.LookupByName(mName)
                        local dot = row._mpiDot
                        if prof then
                            local score = prof.avgMPI or 0
                            local _, sr, sg, sb = MPI.GetScoreTier(score)
                            ApplyTrustVisual(dot, prof.source or "network", sr, sg, sb)
                            dot._guid = guid
                            dot._prof = prof
                            dot._dungeonMapID = listedMapID
                            dot:Show()

                            row._score:SetText(tostring(score))
                            row._score:SetTextColor(sr, sg, sb)

                            -- Mastery for listed dungeon
                            if listedMapID and prof.dungeonMastery and prof.dungeonMastery[listedMapID] then
                                local ml = MASTERY_LEVELS[prof.dungeonMastery[listedMapID].level]
                                if ml then
                                    row._mastery:SetText(ml.label)
                                    row._mastery:SetTextColor(0.6, 0.6, 0.6)
                                    row._mastery:Show()
                                else
                                    row._mastery:Hide()
                                end
                            else
                                row._mastery:Hide()
                            end
                        else
                            dot:Hide()
                            row._score:SetText("")
                            row._mastery:Hide()
                        end

                        row:Show()
                    end
                end
            end
        end
        if rowIdx >= 8 then break end
    end

    -- Hide unused rows
    for i = rowIdx + 1, 8 do
        if applicantRefs.rows[i] then applicantRefs.rows[i]:Hide() end
    end

    -- Update header count
    applicantRefs.countBadge:SetText("(" .. rowIdx .. ")")

    -- Resize panel
    local panelH = 28 + (rowIdx * 26)
    MPI._applicantPanel:SetHeight(max(40, panelH))
    MPI._applicantPanel:Show()
end


-- ============================================================================
-- §15  COMPANION APP DETECTION & BANNER
-- ============================================================================

local COMPANION_DOWNLOAD_URL = "https://mpi.atyzi.com"
local COMPANION_STALE_SEC    = 172800  -- 48 hours

--- Check if the companion app is installed and syncing.
-- The companion writes db/mpi_sync.lua which sets _G.MidnightUI_MPI_Sync.
-- @return string "active", "stale", or "missing"
function MPI.GetCompanionStatus()
    local sync = _G.MidnightUI_MPI_Sync
    if not sync or not sync.lastSync then return "missing" end
    local age = time() - (sync.lastSync or 0)
    if age > COMPANION_STALE_SEC then return "stale" end
    return "active"
end

--- Show a copyable URL dialog using the custom MidnightUI prompt.
local function ShowCompanionURLDialog()
    if type(_G.MidnightUI_OpenURL) == "function" then
        _G.MidnightUI_OpenURL(COMPANION_DOWNLOAD_URL)
    end
end

local companionBannerRef = nil

function MPI.BuildCompanionBanner(parentFrame)
    if companionBannerRef or not parentFrame then return end

    local banner = CreateFrame("Frame", nil, parentFrame, "BackdropTemplate")
    banner:SetHeight(42)
    banner:SetPoint("BOTTOMLEFT", parentFrame, "BOTTOMLEFT", 0, 0)
    banner:SetPoint("BOTTOMRIGHT", parentFrame, "BOTTOMRIGHT", 0, 0)
    banner:SetFrameLevel(parentFrame:GetFrameLevel() + 10)
    banner:SetBackdrop({
        bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    banner:SetBackdropColor(0.35, 0.08, 0.08, 0.90)
    banner:SetBackdropBorderColor(0.60, 0.15, 0.15, 0.70)

    -- Accent line (top)
    local accent = banner:CreateTexture(nil, "ARTWORK")
    accent:SetHeight(1)
    accent:SetPoint("TOPLEFT", banner, "TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", banner, "TOPRIGHT", -1, -1)
    accent:SetColorTexture(0.80, 0.25, 0.25, 0.40)

    -- Close / dismiss button (red X)
    local closeBtn = CreateFrame("Button", nil, banner)
    closeBtn:SetSize(16, 16)
    closeBtn:SetPoint("LEFT", banner, "LEFT", 10, 0)

    local closeText = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeText, TITLE_FONT, 14, "OUTLINE")
    closeText:SetPoint("CENTER")
    closeText:SetText("x")
    closeText:SetTextColor(1.0, 0.35, 0.35)

    closeBtn:SetScript("OnClick", function()
        if db and db.settings then
            db.settings.companionBannerDismissed = true
        end
        banner:Hide()
    end)
    closeBtn:SetScript("OnEnter", function() closeText:SetTextColor(1.0, 0.60, 0.60) end)
    closeBtn:SetScript("OnLeave", function() closeText:SetTextColor(1.0, 0.35, 0.35) end)

    -- Message
    local msg = banner:CreateFontString(nil, "OVERLAY")
    TrySetFont(msg, BODY_FONT, 10, "")
    msg:SetPoint("LEFT", closeBtn, "RIGHT", 8, 0)
    msg:SetPoint("RIGHT", banner, "RIGHT", -105, 0)
    msg:SetTextColor(0.90, 0.75, 0.75)
    msg:SetWordWrap(true)
    banner._msg = msg

    -- "Get It" button
    local btn = CreateFrame("Button", nil, banner, "BackdropTemplate")
    btn:SetSize(90, 20)
    btn:SetPoint("RIGHT", banner, "RIGHT", -8, 0)
    btn:SetBackdrop({
        bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    btn:SetBackdropColor(0.15, 0.15, 0.17, 0.90)
    btn:SetBackdropBorderColor(0.35, 0.88, 0.45, 0.50)

    local btnText = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(btnText, BODY_FONT, 9, "")
    btnText:SetPoint("CENTER")
    btnText:SetText("Get Companion")
    btnText:SetTextColor(0.35, 0.88, 0.45)

    btn:SetScript("OnClick", function() ShowCompanionURLDialog() end)
    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.25, 0.25, 0.28, 0.90)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("MPI Companion App")
        GameTooltip:AddLine("Syncs community scores so you can see how", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("players actually play before you invite them.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.15, 0.15, 0.17, 0.90)
        GameTooltip:Hide()
    end)

    companionBannerRef = banner
end

function MPI.UpdateCompanionBanner(parentFrame)
    if not db or not db.settings.enabled then return end

    local status = MPI.GetCompanionStatus()
    if status == "active" then
        if companionBannerRef then companionBannerRef:Hide() end
        return
    end

    -- Don't show if user already dismissed it
    if db.settings.companionBannerDismissed then
        if companionBannerRef then companionBannerRef:Hide() end
        return
    end

    if not companionBannerRef then
        MPI.BuildCompanionBanner(parentFrame)
    end
    if not companionBannerRef then return end

    if status == "missing" then
        companionBannerRef._msg:SetText("See how every applicant plays before you invite. Get the MPI Companion from mpi.atyzi.com to unlock community scores in Group Finder.")
    else
        companionBannerRef._msg:SetText("MPI Companion has not synced recently. Community scores may be outdated.")
        companionBannerRef:SetBackdropColor(0.30, 0.20, 0.05, 0.90)
        companionBannerRef:SetBackdropBorderColor(0.55, 0.40, 0.10, 0.70)
    end

    companionBannerRef:Show()
end

--- Build a small companion link button next to the settings gear.
function MPI.BuildCompanionSettingsButton(gearBtn)
    if not gearBtn or MPI._companionBtn then return end

    local btn = CreateFrame("Button", nil, gearBtn:GetParent())
    btn:SetSize(24, 24)
    btn:SetPoint("RIGHT", gearBtn, "LEFT", -4, 0)

    local icon = btn:CreateTexture(nil, "OVERLAY")
    icon:SetAllPoints()
    icon:SetTexture("Interface\\Icons\\INV_Misc_EngGizmos_swissArmy")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:SetVertexColor(0.5, 0.5, 0.5, 0.70)

    local status = MPI.GetCompanionStatus()
    if status == "missing" then
        icon:SetVertexColor(1.0, 0.40, 0.40, 0.80)
    elseif status == "stale" then
        icon:SetVertexColor(0.95, 0.75, 0.20, 0.80)
    else
        icon:SetVertexColor(0.35, 0.88, 0.45, 0.80)
    end

    btn:SetScript("OnClick", function() ShowCompanionURLDialog() end)
    btn:SetScript("OnEnter", function(self)
        icon:SetVertexColor(1, 1, 1, 1)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("MPI Companion App")
        if status == "missing" then
            GameTooltip:AddLine("Not installed. Click to get the download link.", 1.0, 0.40, 0.40)
        elseif status == "stale" then
            GameTooltip:AddLine("Has not synced recently. Click for details.", 0.95, 0.75, 0.20)
        else
            local sync = _G.MidnightUI_MPI_Sync
            local profiles = sync and sync.profileCount or 0
            GameTooltip:AddLine("Active — " .. profiles .. " community profiles synced", 0.35, 0.88, 0.45)
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        local s = MPI.GetCompanionStatus()
        if s == "missing" then icon:SetVertexColor(1.0, 0.40, 0.40, 0.80)
        elseif s == "stale" then icon:SetVertexColor(0.95, 0.75, 0.20, 0.80)
        else icon:SetVertexColor(0.35, 0.88, 0.45, 0.80) end
        GameTooltip:Hide()
    end)

    MPI._companionBtn = btn
end


-- ============================================================================
-- §16  EXPORT FORMAT (for Companion App)
-- ============================================================================
-- Structures observation data in SavedVariables so the companion app can
-- read it, convert to JSON, and upload to mpi.atyzi.com.

local EXPORT_VERSION = 3
local EXPORT_MAX_RUNS = 50

--- Build the export table from locally observed profiles.
-- Called after each completed run and on PLAYER_LOGOUT.
function MPI.BuildExportData()
    if not db then return end
    local myGUID = UnitGUID("player")
    if not myGUID then return end

    -- Detect region
    local regionID = 1
    if GetCurrentRegion then
        local ok, r = pcall(GetCurrentRegion)
        if ok and r then regionID = r end
    end
    local regionMap = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw", [5] = "cn" }
    local region = regionMap[regionID] or "us"

    -- Get observer name
    local myName = UnitName("player")
    local _, myRealm = UnitFullName("player")
    local observerName = myName and myRealm and (myName .. "-" .. myRealm) or myName or "Unknown"

    -- Build observations from locally observed profiles only
    local observations = {}
    local count = 0
    for guid, prof in pairs(db.profiles) do
        if prof.source == "local" and guid ~= myGUID and prof.name then
            observations[prof.name] = {
                class           = prof.class or "",
                role            = prof.primaryRole or "DAMAGER",
                avgMPI          = prof.avgMPI or 0,
                awareness       = prof.awarenessScore or 0,
                survival        = prof.survivalScore or 0,
                output          = prof.outputScore or 0,
                utility         = prof.utilityScore or 0,
                consistency     = prof.consistencyScore or 0,
                trend           = prof.trend or "stable",
                badges          = prof.badges or {},
                runsTracked     = prof.runsTracked or 0,
                abandonedRuns   = prof.abandonedRuns or 0,
                lastSeen        = prof.lastSeen or 0,
            }
            count = count + 1
        end
    end

    -- Build run history for the local player (last 20 runs with full breakdown)
    local runHistory = {}
    local myName = observerName
    if db.runs then
        for i = 1, min(#db.runs, EXPORT_MAX_RUNS) do
            local run = db.runs[i]
            if not run then break end

            -- Find the local player's data in this run
            local myData = nil
            for guid, pData in pairs(run.players or {}) do
                if guid == myGUID then
                    myData = pData
                    break
                end
            end

            -- Build group context for this run (all players' raw metrics)
            local groupPlayers = {}
            for guid, pData in pairs(run.players or {}) do
                groupPlayers[#groupPlayers + 1] = {
                    name            = pData.name or "Unknown",
                    class           = pData.class or "",
                    role            = pData.role or "DAMAGER",
                    weightRole      = pData.weightRole or pData.role or "DAMAGER",
                    specIcon        = pData.specIcon or 0,
                    damageDone      = pData.damageDone or 0,
                    damageTaken     = pData.damageTaken or 0,
                    avoidableDamage = pData.avoidableDamage or 0,
                    healingDone     = pData.healingDone or 0,
                    dispels         = pData.dispels or 0,
                    interrupts      = pData.interrupts or 0,
                    deaths          = pData.deaths or 0,
                    mpiScore        = pData.mpiScore or 0,
                    awarenessScore  = pData.awarenessScore or 0,
                    survivalScore   = pData.survivalScore or 0,
                    outputScore     = pData.outputScore or 0,
                    utilityScore    = pData.utilityScore or 0,
                    consistencyScore = pData.consistencyScore or 0,
                    badges          = pData.badges or {},
                    isLocalPlayer   = (guid == myGUID),
                }
            end

            runHistory[#runHistory + 1] = {
                timestamp    = run.timestamp or 0,
                dungeonMapID = run.dungeonMapID or 0,
                dungeonName  = run.dungeonName or "Unknown",
                keyLevel     = run.keyLevel or 0,
                affixes      = run.affixes or {},
                result       = run.result or "depleted",
                stars        = run.stars or 0,
                durationSec  = run.durationSec or 0,
                timeLimitSec = run.timeLimitSec or 0,
                players      = groupPlayers,
                myScore      = myData and myData.mpiScore or 0,
                myAwareness  = myData and myData.awarenessScore or 0,
                mySurvival   = myData and myData.survivalScore or 0,
                myOutput     = myData and myData.outputScore or 0,
                myUtility    = myData and myData.utilityScore or 0,
                myConsistency = myData and myData.consistencyScore or 0,
                myBadges     = myData and myData.badges or {},
                myRole       = myData and (myData.weightRole or myData.role) or "DAMAGER",
                myDeaths     = myData and myData.deaths or 0,
                myInterrupts = myData and myData.interrupts or 0,
                myDispels    = myData and myData.dispels or 0,
                myDamageDone = myData and myData.damageDone or 0,
                myDamageTaken = myData and myData.damageTaken or 0,
                myAvoidableDamage = myData and myData.avoidableDamage or 0,
                myHealingDone = myData and myData.healingDone or 0,
                encounters   = run.encounters or {},
                detail       = run.detail or {},
            }
        end
    end

    db.export = {
        version      = EXPORT_VERSION,
        region       = region,
        observerName = observerName,
        exportedAt   = time(),
        profileCount = count,
        observations = observations,
        runHistory   = runHistory,
    }
end


-- ============================================================================
-- §17  COMMUNITY DB LOADER (Binary Search)
-- ============================================================================
-- Loads static database files written by the companion app (synced from mpi.atyzi.com).
-- Uses binary search on sorted name arrays and bit-level decoding of packed
-- 8-byte records — same architectural pattern as Raider.IO.

local MPI_DB_FORMAT   = 1
local RECORD_BYTES    = 8
local communityDB     = nil  -- reference to _G.MidnightUI_MPI_DB
local communityMeta   = nil  -- reference to _G.MidnightUI_MPI_DBMeta

-- Class index mapping (must match aggregation script exactly)
local CLASS_BY_INDEX = {
    [1]  = "WARRIOR",     [2]  = "PALADIN",    [3]  = "HUNTER",
    [4]  = "ROGUE",       [5]  = "PRIEST",     [6]  = "DEATHKNIGHT",
    [7]  = "SHAMAN",      [8]  = "MAGE",       [9]  = "WARLOCK",
    [10] = "MONK",        [11] = "DRUID",      [12] = "DEMONHUNTER",
    [13] = "EVOKER",
}

-- Role index mapping
local ROLE_BY_INDEX = { [0] = "DAMAGER", [1] = "TANK", [2] = "HEALER" }

-- Badge bit positions (must match aggregation script)
local BADGE_BITS = { "AK", "CR", "TP", "IM", "IW", "DE" }

--- Read N bits from a binary string at a given bit offset.
-- @param data    string  Binary data string
-- @param bitOff  number  Bit offset (0-based)
-- @param bitLen  number  Number of bits to read (max 8)
-- @return number  Decoded unsigned integer
local function ReadBits(data, bitOff, bitLen)
    local byteIdx = floor(bitOff / 8) + 1
    local bitShift = bitOff % 8
    -- Read up to 2 bytes to cover the bit span
    local b0 = data:byte(byteIdx) or 0
    local b1 = data:byte(byteIdx + 1) or 0
    local raw = b0 + b1 * 256
    return floor(raw / (2 ^ bitShift)) % (2 ^ bitLen)
end

--- Decode an 8-byte record at the given byte offset.
-- @param data   string  Binary data string
-- @param offset number  1-based byte offset
-- @return table  Profile-like table, or nil
local function DecodeRecord(data, offset)
    if not data or #data < offset + RECORD_BYTES - 1 then return nil end

    local chunk = data:sub(offset, offset + RECORD_BYTES - 1)
    local bit = 0

    local compositeMPI  = ReadBits(chunk, bit, 7);  bit = bit + 7
    local awareness     = ReadBits(chunk, bit, 7);  bit = bit + 7
    local survival      = ReadBits(chunk, bit, 7);  bit = bit + 7
    local output        = ReadBits(chunk, bit, 7);  bit = bit + 7
    local utility       = ReadBits(chunk, bit, 7);  bit = bit + 7
    local consistency   = ReadBits(chunk, bit, 7);  bit = bit + 7
    local trendIdx      = ReadBits(chunk, bit, 2);  bit = bit + 2
    local classIdx      = ReadBits(chunk, bit, 4);  bit = bit + 4
    local roleIdx       = ReadBits(chunk, bit, 2);  bit = bit + 2
    local observerCount = ReadBits(chunk, bit, 6);  bit = bit + 6
    local badgeBits     = ReadBits(chunk, bit, 6);  -- bit = bit + 6

    local trend = trendIdx == 1 and "up" or trendIdx == 2 and "down" or "stable"

    local badges = {}
    for i = 1, #BADGE_BITS do
        if floor(badgeBits / (2 ^ (i - 1))) % 2 == 1 then
            badges[#badges + 1] = BADGE_BITS[i]
        end
    end

    return {
        avgMPI          = min(100, compositeMPI),
        awarenessScore  = min(100, awareness),
        survivalScore   = min(100, survival),
        outputScore     = min(100, output),
        utilityScore    = min(100, utility),
        consistencyScore = min(100, consistency),
        trend           = trend,
        class           = CLASS_BY_INDEX[classIdx] or "",
        primaryRole     = ROLE_BY_INDEX[roleIdx] or "DAMAGER",
        _observerCount  = observerCount,
        badges          = badges,
        runsTracked     = 0,
        abandonedRuns   = 0,
        source          = "community",
    }
end

--- Case-insensitive binary search on a sorted name array.
-- @param names table  Sorted array of character names (1-indexed)
-- @param target string  Name to find
-- @return number|nil  1-based index into the names array, or nil
local function BinarySearchName(names, target)
    if not names or #names == 0 or not target then return nil end
    local low, high = 1, #names
    local targetLower = target:lower()
    while low <= high do
        local mid = floor((low + high) / 2)
        local cmp = names[mid]:lower()
        if cmp == targetLower then
            return mid
        elseif cmp < targetLower then
            low = mid + 1
        else
            high = mid - 1
        end
    end
    return nil
end

--- Initialize the community DB references.
-- Called once at ADDON_LOADED after db files are loaded.
function MPI.LoadCommunityDB()
    communityDB = _G.MidnightUI_MPI_DB
    communityMeta = _G.MidnightUI_MPI_DBMeta
end

--- Look up a player in the community database.
-- @param name  string  "Name-Realm" or "Name"
-- @param realm string|nil  Realm name (if known separately)
-- @return table|nil  Profile-like table with community data
function MPI.CommunityLookup(name, realm)
    if not communityDB or not name then return nil end

    -- Parse name and realm from "Name-Realm" format
    local playerName, playerRealm = name:match("^([^%-]+)%-(.+)$")
    if not playerName then
        playerName = name
        playerRealm = realm
    end
    if not playerName or not playerRealm then return nil end

    -- Detect current region
    local regionID = 1
    if GetCurrentRegion then
        local ok, r = pcall(GetCurrentRegion)
        if ok and r then regionID = r end
    end
    local regionMap = { [1] = "us", [2] = "kr", [3] = "eu", [4] = "tw", [5] = "cn" }
    local regionKey = regionMap[regionID] or "us"

    local regionData = communityDB[regionKey]
    if not regionData or not regionData.realms or not regionData.data then return nil end
    if regionData.data == "" then return nil end

    local realmData = regionData.realms[playerRealm]
    if not realmData or not realmData.names or #realmData.names == 0 then return nil end

    local nameIdx = BinarySearchName(realmData.names, playerName)
    if not nameIdx then return nil end

    -- Calculate byte offset: realm offset + (nameIdx - 1) * RECORD_BYTES + 1 (Lua 1-based)
    local byteOffset = (realmData.offset or 0) + (nameIdx - 1) * RECORD_BYTES + 1
    local profile = DecodeRecord(regionData.data, byteOffset)

    if profile then
        profile.name = name
        profile.lastSeen = communityMeta and communityMeta.generated or 0
    end

    return profile
end


-- ============================================================================
-- §12  EVENT DISPATCHER & GLOBAL EXPORTS
-- ============================================================================

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        OnAddonLoaded(_, ...)
    elseif event == "CHALLENGE_MODE_START" then
        OnChallengeModeStart()
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        -- Small delay to ensure C_DamageMeter has finalized data
        C_Timer.After(2, function()
            OnChallengeModeCompleted()
        end)
    elseif event == "ENCOUNTER_START" then
        OnEncounterStart(...)
    elseif event == "ENCOUNTER_END" then
        OnEncounterEnd(...)
    elseif event == "GROUP_ROSTER_UPDATE" then
        OnGroupRosterUpdate()
    elseif event == "PLAYER_LOGOUT" then
        MPI.BuildExportData()
        -- _nameIndex is rebuilt on every load; don't waste SavedVariables space
        if db then db._nameIndex = nil end
    end
end)

-- Global API table for GroupFinder.lua hooks
_G.MidnightPI = {
    -- Display hooks (called by GroupFinder.lua)
    UpdateDungeonHeroDashboard = function(parent)
        MPI.UpdateDungeonHeroDashboard(parent)
    end,
    UpdatePremadeHeroPill = function(R)
        MPI.UpdatePremadeHeroPill(R)
    end,
    UpdateListingRowMPI = function(row, info)
        MPI.UpdateListingRowMPI(row, info)
    end,
    UpdateSidebarTeamMPI = function(sidebar, resultID)
        MPI.UpdateSidebarTeamMPI(sidebar, resultID)
    end,

    -- Utility API
    GetPlayerScore = function()
        if not db then return 0 end
        return db.personal.avgMPI or 0
    end,
    GetProfileByGUID = function(guid)
        if not db or not guid then return nil end
        return db.profiles[guid]
    end,
    GetProfileByName = function(name)
        if not db or not name then return nil end
        local _, prof = MPI.LookupByName(name)
        return prof
    end,
    IsReady = function()
        return MPI._ready
    end,
    AddTag = function(guid, tag) MPI.AddTag(guid, tag) end,
    RemoveTag = function(guid, tag) MPI.RemoveTag(guid, tag) end,
    SetNote = function(guid, text) MPI.SetNote(guid, text) end,

    -- Applicant panel hook (called by GroupFinder.lua)
    OnApplicantListUpdated = function(sidebar)
        MPI.OnApplicantListUpdated(sidebar)
    end,

    -- Score tier API (used by GroupFinder for MPI badge coloring)
    GetScoreTier = function(score)
        return MPI.GetScoreTier(score)
    end,
    GetBarColor = function(value)
        return MPI.GetBarColor(value)
    end,

    -- Community DB API
    CommunityLookup = function(name, realm)
        return MPI.CommunityLookup(name, realm)
    end,

    -- Companion app hooks (called by GroupFinder.lua)
    UpdateCompanionBanner = function(parent)
        MPI.UpdateCompanionBanner(parent)
    end,
    BuildCompanionSettingsButton = function(gearBtn)
        MPI.BuildCompanionSettingsButton(gearBtn)
    end,
    GetCompanionStatus = function()
        return MPI.GetCompanionStatus()
    end,
}
