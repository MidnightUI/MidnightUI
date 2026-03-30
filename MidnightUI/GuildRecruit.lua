-- =============================================================================
-- FILE PURPOSE:     Guild recruitment system. Officers configure open roles/specs
--                   and set recruitment status. Non-officer members submit applications
--                   with class/role/spec/message. Applications are delivered via
--                   C_ChatInfo addon messages (COMM_PREFIX="MUI_RECRUIT") with a
--                   direct-whisper fallback. Officers review a sorted applicant list
--                   with accept/decline actions (GuildInvite + decline whisper).
-- LOAD ORDER:       Loads after GuildPanel.lua, before GroupFinder.lua.
--                   Standalone file — no Addon vararg namespace, no early-exit guard.
-- DEFINES:          "MidnightRecruitPanel" frame (slide-in overlay on GuildPanel).
--                   ALL_CLASSES{} — all 13 WoW class files with icons.
--                   ROLE_DEFS{} — Tank/Healer/DPS role keys with icons and colors.
--                   ROLE_SPECS{} — per-role spec list with spec IDs and icon IDs.
--                   CLASS_LOOKUP{} — classFile → ALL_CLASSES entry lookup table.
--                   SafeCall() / GetClassColor() / TrySetFont() — local safe wrappers.
-- READS:            MidnightUIGuildRecruit (SavedVariable) — recruitment config, applicant
--                   data, officer status, open-roles bitmap.
--                   IsInGuild, GetGuildRosterInfo — guild context checks.
--                   UnitIsGroupLeader / C_GuildInfo — officer permission gate.
-- WRITES:           MidnightUIGuildRecruit.config — role/spec toggles, recruitment message.
--                   MidnightUIGuildRecruit.applications[] — applicant records.
--                   MidnightUIGuildRecruit.status — "open"/"closed"/"paused".
-- DEPENDS ON:       C_ChatInfo.SendAddonMessage (COMM_PREFIX="MUI_RECRUIT") — primary
--                   application delivery channel.
--                   SendChatMessage / WhisperPlayer — fallback delivery when addon
--                   message fails or recipient is offline.
--                   GuildInvite(name) — officer accept action.
-- USED BY:          GuildPanel.lua — adds a "Recruit" tab button that opens this panel.
-- KEY FLOWS:
--   Recruit tab click → open config panel (officers) or application panel (members)
--   Officer config: toggle role/spec checkboxes → save to MidnightUIGuildRecruit.config
--   Member apply: fill class/role/spec/message → SendAddonMessage MUI_RECRUIT/APP
--   CHAT_MSG_ADDON MUI_RECRUIT/APP → officer receives → adds to applications[] → refresh list
--   Officer review: Accept → GuildInvite(name) + remove from list
--   Officer review: Decline → whisper decline message + remove from list
-- GOTCHAS:
--   C_ChatInfo.SendAddonMessage requires both sender and recipient to have the addon loaded.
--   The whisper fallback fires automatically when the primary channel fails.
--   ROLE_SPECS uses numeric texture IDs from GetSpecializationInfoByID — these are
--   guaranteed to resolve even when spec icon string paths may not be available.
--   MidnightUIGuildRecruit is a SavedVariable (persists across sessions); applications[]
--   must be pruned on session start to remove stale/expired entries.
-- NAVIGATION:
--   ALL_CLASSES{}          — all 13 class definitions (line ~45)
--   ROLE_SPECS{}           — per-role spec table (line ~74)
--   MUI_RECRUIT protocol   — message format for application/response (search "MUI_RECRUIT")
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local W8 = "Interface\\Buttons\\WHITE8X8"
local TITLE_FONT = "Fonts\\FRIZQT__.TTF"
local BODY_FONT  = "Fonts\\FRIZQT__.TTF"

-- ============================================================================
-- §1  CONSTANTS & UPVALUES
-- ============================================================================
local pcall, type, pairs, ipairs, math, string, table, select, tostring, tonumber, time, date =
      pcall, type, pairs, ipairs, math, string, table, select, tostring, tonumber, time, date
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local IsInGuild, GetGuildInfo, GetNumGuildMembers = IsInGuild, GetGuildInfo, GetNumGuildMembers
local GetGuildRosterInfo, GuildRoster = GetGuildRosterInfo, GuildRoster
local SendChatMessage, GuildInvite = SendChatMessage, GuildInvite
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local strsplit = strsplit

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2, r3, r4, r5, r6, r7, r8 = pcall(fn, ...)
    if not ok then return nil end
    return r1, r2, r3, r4, r5, r6, r7, r8
end

local function TrySetFont(fs, fontPath, size, flags)
    if not fs or not fs.SetFont then return end
    pcall(fs.SetFont, fs, fontPath or TITLE_FONT, size or 12, flags or "")
end

local function GetClassColor(classFile)
    if not classFile or classFile == "" or not RAID_CLASS_COLORS then return 0.8, 0.8, 0.8 end
    local cc = RAID_CLASS_COLORS[classFile]
    if cc then return cc.r, cc.g, cc.b end
    return 0.8, 0.8, 0.8
end

-- All WoW class files for the class selector
local ALL_CLASSES = {
    { file = "WARRIOR",     name = "Warrior",     icon = "Interface\\Icons\\ClassIcon_Warrior" },
    { file = "PALADIN",     name = "Paladin",     icon = "Interface\\Icons\\ClassIcon_Paladin" },
    { file = "HUNTER",      name = "Hunter",      icon = "Interface\\Icons\\ClassIcon_Hunter" },
    { file = "ROGUE",       name = "Rogue",       icon = "Interface\\Icons\\ClassIcon_Rogue" },
    { file = "PRIEST",      name = "Priest",      icon = "Interface\\Icons\\ClassIcon_Priest" },
    { file = "DEATHKNIGHT", name = "Death Knight", icon = "Interface\\Icons\\ClassIcon_DeathKnight" },
    { file = "SHAMAN",      name = "Shaman",      icon = "Interface\\Icons\\ClassIcon_Shaman" },
    { file = "MAGE",        name = "Mage",        icon = "Interface\\Icons\\ClassIcon_Mage" },
    { file = "WARLOCK",     name = "Warlock",     icon = "Interface\\Icons\\ClassIcon_Warlock" },
    { file = "MONK",        name = "Monk",        icon = "Interface\\Icons\\ClassIcon_Monk" },
    { file = "DRUID",       name = "Druid",       icon = "Interface\\Icons\\ClassIcon_Druid" },
    { file = "DEMONHUNTER", name = "Demon Hunter", icon = "Interface\\Icons\\ClassIcon_DemonHunter" },
    { file = "EVOKER",      name = "Evoker",      icon = "Interface\\Icons\\ClassIcon_Evoker" },
}

local ROLE_DEFS = {
    { key = "TANK",   label = "Tank",   icon = "Interface\\Icons\\Ability_Defend",   color = { 0.30, 0.60, 1.00 } },
    { key = "HEALER", label = "Healer", icon = "Interface\\Icons\\Spell_Holy_FlashHeal", color = { 0.30, 0.90, 0.30 } },
    { key = "DPS",    label = "DPS",    icon = "Interface\\Icons\\Ability_SteelMelee", color = { 0.90, 0.30, 0.30 } },
}

-- Build a lookup: classFile → entry from ALL_CLASSES
local CLASS_LOOKUP = {}
for _, cls in ipairs(ALL_CLASSES) do CLASS_LOOKUP[cls.file] = cls end

-- Specs per role (accurate to TWW / Midnight)
-- Icon paths use class icons as reliable fallbacks where spec icons may not exist
-- Spec icons use numeric texture IDs from GetSpecializationInfoByID() which are guaranteed to resolve
local ROLE_SPECS = {
    TANK = {
        { id = "WARRIOR_PROT",     class = "WARRIOR",     name = "Protection",   short = "Prot War",   icon = 134952, specID = 73  },  -- INV_Shield_06
        { id = "PALADIN_PROT",     class = "PALADIN",     name = "Protection",   short = "Prot Pal",   icon = 236264, specID = 66  },  -- Spell_Holy_DevotionAura
        { id = "DEATHKNIGHT_BLOOD",class = "DEATHKNIGHT", name = "Blood",        short = "Blood DK",   icon = 135770, specID = 250 },  -- Spell_Deathknight_BloodPresence
        { id = "MONK_BREW",        class = "MONK",        name = "Brewmaster",   short = "Brew Monk",  icon = 608951, specID = 268 },  -- spec_monk_brewmaster
        { id = "DRUID_GUARD",      class = "DRUID",       name = "Guardian",     short = "Guardian",   icon = 132276, specID = 104 },  -- Ability_Racial_BearForm
        { id = "DEMONHUNTER_VENG", class = "DEMONHUNTER", name = "Vengeance",    short = "Veng DH",    icon = 1247265, specID = 581 }, -- Ability_DemonHunter_Metamorphosis_Tank
    },
    HEALER = {
        { id = "PALADIN_HOLY",     class = "PALADIN",     name = "Holy",         short = "Holy Pal",   icon = 135920, specID = 65  },  -- Spell_Holy_HolyBolt
        { id = "PRIEST_DISC",      class = "PRIEST",      name = "Discipline",   short = "Disc",       icon = 135940, specID = 256 },  -- Spell_Holy_PowerWordShield
        { id = "PRIEST_HOLY",      class = "PRIEST",      name = "Holy",         short = "Holy Priest", icon = 237542, specID = 257 }, -- Spell_Holy_GuardianSpirit
        { id = "SHAMAN_RESTO",     class = "SHAMAN",      name = "Restoration",  short = "Resto Sham",  icon = 136052, specID = 264 }, -- Spell_Nature_MagicImmunity
        { id = "MONK_MW",          class = "MONK",        name = "Mistweaver",   short = "MW Monk",    icon = 608952, specID = 270 },  -- spec_monk_mistweaver
        { id = "DRUID_RESTO",      class = "DRUID",       name = "Restoration",  short = "Resto Druid", icon = 136041, specID = 105 }, -- Spell_Nature_HealingTouch
        { id = "EVOKER_PRES",      class = "EVOKER",      name = "Preservation", short = "Pres Evoker", icon = 4511811, specID = 1468 }, -- Evoker Preservation
    },
    DPS = {
        { id = "WARRIOR_ARMS",     class = "WARRIOR",     name = "Arms",         short = "Arms",       icon = 132355, specID = 71  },  -- Ability_Warrior_SavageBlow
        { id = "WARRIOR_FURY",     class = "WARRIOR",     name = "Fury",         short = "Fury",       icon = 132347, specID = 72  },  -- Ability_Warrior_InnerRage
        { id = "PALADIN_RET",      class = "PALADIN",     name = "Retribution",  short = "Ret Pal",    icon = 135873, specID = 70  },  -- Spell_Holy_AuraOfLight
        { id = "HUNTER_BM",        class = "HUNTER",      name = "Beast Mastery",short = "BM Hunt",    icon = 461112, specID = 253 },  -- Ability_Hunter_BeastTaming
        { id = "HUNTER_MM",        class = "HUNTER",      name = "Marksmanship", short = "MM Hunt",    icon = 236179, specID = 254 },  -- Ability_Hunter_FocusedAim
        { id = "HUNTER_SV",        class = "HUNTER",      name = "Survival",     short = "SV Hunt",    icon = 461113, specID = 255 },  -- Ability_Hunter_Camouflage
        { id = "ROGUE_SIN",        class = "ROGUE",       name = "Assassination",short = "Sin Rogue",  icon = 236270, specID = 259 },  -- Ability_Rogue_DeadlyBrew
        { id = "ROGUE_OUT",        class = "ROGUE",       name = "Outlaw",       short = "Outlaw",     icon = 236286, specID = 260 },  -- Ability_Rogue_Waylay / INV_Sword_30
        { id = "ROGUE_SUB",        class = "ROGUE",       name = "Subtlety",     short = "Sub Rogue",  icon = 132320, specID = 261 },  -- Ability_Stealth
        { id = "PRIEST_SHADOW",    class = "PRIEST",      name = "Shadow",       short = "Shadow",     icon = 136207, specID = 258 },  -- Spell_Shadow_ShadowWordPain
        { id = "DEATHKNIGHT_FROST",class = "DEATHKNIGHT", name = "Frost",        short = "Frost DK",   icon = 135773, specID = 251 },  -- Spell_DeathKnight_FrostPresence
        { id = "DEATHKNIGHT_UH",   class = "DEATHKNIGHT", name = "Unholy",       short = "UH DK",      icon = 135775, specID = 252 },  -- Spell_DeathKnight_UnholyPresence
        { id = "SHAMAN_ELE",       class = "SHAMAN",      name = "Elemental",    short = "Ele Sham",   icon = 136048, specID = 262 },  -- Spell_Nature_Lightning
        { id = "SHAMAN_ENH",       class = "SHAMAN",      name = "Enhancement",  short = "Enh Sham",   icon = 237581, specID = 263 },  -- Spell_Shaman_ImprovedStormstrike
        { id = "MAGE_ARCANE",      class = "MAGE",        name = "Arcane",       short = "Arcane",     icon = 135932, specID = 62  },  -- Spell_Holy_MagicSentry
        { id = "MAGE_FIRE",        class = "MAGE",        name = "Fire",         short = "Fire Mage",  icon = 135810, specID = 63  },  -- Spell_Fire_FireBolt02
        { id = "MAGE_FROST",       class = "MAGE",        name = "Frost",        short = "Frost Mage", icon = 135846, specID = 64  },  -- Spell_Frost_FrostBolt02
        { id = "WARLOCK_AFF",      class = "WARLOCK",     name = "Affliction",   short = "Aff Lock",   icon = 136145, specID = 265 },  -- Spell_Shadow_DeathCoil
        { id = "WARLOCK_DEMO",     class = "WARLOCK",     name = "Demonology",   short = "Demo Lock",  icon = 136172, specID = 266 },  -- Spell_Shadow_Metamorphosis
        { id = "WARLOCK_DEST",     class = "WARLOCK",     name = "Destruction",  short = "Destro Lock", icon = 136186, specID = 267 }, -- Spell_Shadow_RainOfFire
        { id = "MONK_WW",          class = "MONK",        name = "Windwalker",   short = "WW Monk",    icon = 608953, specID = 269 },  -- spec_monk_windwalker
        { id = "DRUID_BALANCE",    class = "DRUID",       name = "Balance",      short = "Boomkin",    icon = 136096, specID = 102 },  -- Spell_Nature_StarFall
        { id = "DRUID_FERAL",      class = "DRUID",       name = "Feral",        short = "Feral",      icon = 132115, specID = 103 },  -- Ability_Druid_CatForm
        { id = "DEMONHUNTER_HAVOC",class = "DEMONHUNTER", name = "Havoc",        short = "Havoc DH",   icon = 1247264, specID = 577 }, -- Ability_DemonHunter_SpecDPS
        { id = "DEMONHUNTER_DEV",  class = "DEMONHUNTER", name = "Devourer",     short = "Devourer",   icon = 1247264, specID = 0 },   -- Placeholder (new spec)
        { id = "EVOKER_DEV",       class = "EVOKER",      name = "Devastation",  short = "Dev Evoker", icon = 4511812, specID = 1467 }, -- Evoker Devastation
        { id = "EVOKER_AUG",       class = "EVOKER",      name = "Augmentation", short = "Aug Evoker", icon = 5198700, specID = 1473 }, -- Evoker Augmentation
    },
}

-- At runtime, resolve icons dynamically from WoW API for maximum accuracy
local function ResolveSpecIcons()
    for _, role in pairs(ROLE_SPECS) do
        for _, spec in ipairs(role) do
            if spec.specID and spec.specID > 0 then
                local _, _, _, resolvedIcon = GetSpecializationInfoByID(spec.specID)
                if resolvedIcon and resolvedIcon > 0 then
                    spec.icon = resolvedIcon
                end
            end
        end
    end
end

-- Races organized by category (accurate to TWW / Midnight)
local RACE_CATEGORIES = {
    { header = "ALLIANCE", races = {
        { key = "Human",       name = "Human" },
        { key = "Dwarf",       name = "Dwarf" },
        { key = "NightElf",    name = "Night Elf" },
        { key = "Gnome",       name = "Gnome" },
        { key = "Draenei",     name = "Draenei" },
        { key = "Worgen",      name = "Worgen" },
    }},
    { header = "HORDE", races = {
        { key = "Orc",         name = "Orc" },
        { key = "Undead",      name = "Undead" },
        { key = "Tauren",      name = "Tauren" },
        { key = "Troll",       name = "Troll" },
        { key = "BloodElf",    name = "Blood Elf" },
        { key = "Goblin",      name = "Goblin" },
    }},
    { header = "ALLIED (ALLIANCE)", races = {
        { key = "VoidElf",     name = "Void Elf" },
        { key = "LFDraenei",   name = "Lightforged" },
        { key = "DarkIron",    name = "Dark Iron" },
        { key = "KulTiran",    name = "Kul Tiran" },
        { key = "Mechagnome",  name = "Mechagnome" },
    }},
    { header = "ALLIED (HORDE)", races = {
        { key = "Nightborne",  name = "Nightborne" },
        { key = "HighmountainTauren", name = "Highmountain" },
        { key = "MagharOrc",   name = "Mag'har" },
        { key = "ZandalariTroll", name = "Zandalari" },
        { key = "Vulpera",     name = "Vulpera" },
    }},
    { header = "ALLIED (NEUTRAL)", races = {
        { key = "Earthen",     name = "Earthen" },
    }},
    { header = "NEUTRAL", races = {
        { key = "Pandaren",    name = "Pandaren" },
        { key = "Dracthyr",    name = "Dracthyr" },
    }},
}

local PRIORITY_LABELS = {
    NONE = "Closed",
    LOW  = "Low Need",
    HIGH = "High Need",
}

local PRIORITY_COLORS = {
    NONE = { 0.50, 0.50, 0.50 },
    LOW  = { 0.85, 0.75, 0.20 },
    HIGH = { 0.30, 0.90, 0.30 },
}

-- Application statuses
local STATUS = {
    PENDING   = "PENDING",
    REVIEWING = "REVIEWING",
    TRIAL     = "TRIAL",
    ACCEPTED  = "ACCEPTED",
    REJECTED  = "REJECTED",
    WITHDRAWN = "WITHDRAWN",
}

local STATUS_COLORS = {
    PENDING   = { 0.85, 0.75, 0.20 },
    REVIEWING = { 0.00, 0.78, 1.00 },
    TRIAL     = { 0.60, 0.40, 1.00 },
    ACCEPTED  = { 0.30, 0.90, 0.30 },
    REJECTED  = { 0.90, 0.30, 0.30 },
    WITHDRAWN = { 0.50, 0.50, 0.50 },
}

-- Guild type tags
local GUILD_TYPES = {
    { key = "RAID",      label = "Raiding",   icon = "Interface\\Icons\\Achievement_Boss_Ragnaros" },
    { key = "MYTHICPLUS", label = "Mythic+",  icon = "Interface\\Icons\\INV_Relics_Hourglass" },
    { key = "PVP",       label = "PvP",       icon = "Interface\\Icons\\Achievement_Arena_2v2_7" },
    { key = "SOCIAL",    label = "Social",    icon = "Interface\\Icons\\Achievement_GuildPerk_HaveGroupWillTravel" },
    { key = "RP",        label = "Roleplay",  icon = "Interface\\Icons\\INV_Misc_Book_09" },
    { key = "HARDCORE",  label = "Hardcore",  icon = "Interface\\Icons\\Achievement_Boss_KilJaeden" },
}

local RAID_DAYS = {
    { key = "MON", label = "Mon" }, { key = "TUE", label = "Tue" },
    { key = "WED", label = "Wed" }, { key = "THU", label = "Thu" },
    { key = "FRI", label = "Fri" }, { key = "SAT", label = "Sat" },
    { key = "SUN", label = "Sun" },
}

local TIMEZONES = { "EST", "CST", "MST", "PST", "GMT", "CET", "AEST", "Server" }

-- 30-minute time slots (12-hour format)
local TIME_SLOTS = {
    "12:00 AM", "12:30 AM",
    "1:00 AM",  "1:30 AM",  "2:00 AM",  "2:30 AM",  "3:00 AM",  "3:30 AM",
    "4:00 AM",  "4:30 AM",  "5:00 AM",  "5:30 AM",  "6:00 AM",  "6:30 AM",
    "7:00 AM",  "7:30 AM",  "8:00 AM",  "8:30 AM",  "9:00 AM",  "9:30 AM",
    "10:00 AM", "10:30 AM", "11:00 AM", "11:30 AM",
    "12:00 PM", "12:30 PM",
    "1:00 PM",  "1:30 PM",  "2:00 PM",  "2:30 PM",  "3:00 PM",  "3:30 PM",
    "4:00 PM",  "4:30 PM",  "5:00 PM",  "5:30 PM",  "6:00 PM",  "6:30 PM",
    "7:00 PM",  "7:30 PM",  "8:00 PM",  "8:30 PM",  "9:00 PM",  "9:30 PM",
    "10:00 PM", "10:30 PM", "11:00 PM", "11:30 PM",
}

-- ============================================================================
-- §2  PREFIX REGISTRATION & CHUNKING PROTOCOL
-- ============================================================================
local RCRT_PREFIX = "MUI_RCRT"
pcall(C_ChatInfo.RegisterAddonMessagePrefix, RCRT_PREFIX)

-- Channel for cross-guild discovery (addon messages only, invisible to players)
local RECRUIT_CHANNEL = "MidnightUIRecruit"
local recruitChannelId = nil
local lastChannelBroadcast = 0
local CHANNEL_BROADCAST_INTERVAL = 300  -- 5 minutes between officer broadcasts
local RELAY_INTERVAL = 600              -- 10 minutes between relay broadcasts
local LISTING_TTL = 86400               -- listings live for 24 hours (enables cross-realm seeding via account-wide SavedVariables)
local RELAY_MAX_PER_CYCLE = 5           -- max listings to relay per cycle
local lastRelayTime = 0

-- Chunk buffer: { [sender..msgId] = { parts = {}, total = N, received = 0 } }
local chunkBuffer = {}
local chunkCounter = 0

local function SendChunked(message, channel, target)
    local maxLen = 240  -- leave room for envelope overhead
    if #message <= maxLen then
        if target then
            pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, message, channel, target)
        else
            pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, message, channel)
        end
        return
    end

    chunkCounter = chunkCounter + 1
    local msgId = tostring(chunkCounter)
    local totalParts = math.ceil(#message / maxLen)

    for i = 1, totalParts do
        local startIdx = (i - 1) * maxLen + 1
        local endIdx = math.min(i * maxLen, #message)
        local payload = message:sub(startIdx, endIdx)
        local envelope = "CHUNK|" .. msgId .. "|" .. i .. "|" .. totalParts .. "|" .. payload

        -- Stagger to avoid throttle
        C_Timer.After(0.25 * (i - 1), function()
            if target then
                pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, envelope, channel, target)
            else
                pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, envelope, channel)
            end
        end)
    end
end

local function ProcessChunk(sender, message)
    -- Check if it's a chunk envelope
    if not message:match("^CHUNK|") then return message end

    local _, msgId, partN, totalParts, payload = strsplit("|", message, 5)
    partN = tonumber(partN)
    totalParts = tonumber(totalParts)
    if not msgId or not partN or not totalParts or not payload then return nil end

    local bufKey = sender .. "|" .. msgId
    if not chunkBuffer[bufKey] then
        chunkBuffer[bufKey] = { parts = {}, total = totalParts, received = 0, created = time() }
    end

    local buf = chunkBuffer[bufKey]
    if not buf.parts[partN] then
        buf.parts[partN] = payload
        buf.received = buf.received + 1
    end

    if buf.received >= buf.total then
        -- Reassemble
        local full = ""
        for i = 1, buf.total do
            full = full .. (buf.parts[i] or "")
        end
        chunkBuffer[bufKey] = nil
        return full
    end

    return nil  -- not yet complete
end

-- Periodically clean stale chunks (older than 60s)
C_Timer.NewTicker(30, function()
    local now = time()
    for key, buf in pairs(chunkBuffer) do
        if now - (buf.created or 0) > 60 then
            chunkBuffer[key] = nil
        end
    end
end)

-- ============================================================================
-- §3  DATA MODEL (load/save/migrate SavedVariables)
-- ============================================================================
local Recruit = {}
local DB = nil  -- reference to MidnightUIGuildRecruit after ADDON_LOADED

local DEFAULT_DB = {
    config = {
        version = 0,
        enabled = false,
        lastUpdated = 0,
        updatedBy = "",
        description = "",
        -- Guild identity (auto-detected where possible, officer-editable)
        guildType = {},          -- multi-select: "RAID", "MYTHICPLUS", "PVP", "SOCIAL", "RP", "HARDCORE"
        faction = "",            -- "Alliance", "Horde" (auto-detected)
        realm = "",              -- auto-detected
        region = "",             -- "US", "EU", "KR", "TW" (auto-detected)
        raidProgress = "",       -- formatted display: "5/8M" (auto-generated)
        raidProgBosses = 0,      -- bosses killed (0-14)
        raidProgTotal = 8,       -- total bosses in tier (1-14)
        raidProgDiff = "H",      -- "N", "H", "M"
        raidProgAOTC = false,    -- has AOTC
        raidProgCE = false,      -- has CE
        -- Schedule
        raidDays = {},           -- multi-select: "MON","TUE","WED","THU","FRI","SAT","SUN"
        raidTime = "",           -- formatted display: "8:00 PM - 11:00 PM" (auto-generated)
        raidStartTime = "",      -- e.g. "8:00 PM" (from TIME_SLOTS)
        raidEndTime = "",        -- e.g. "11:00 PM" (from TIME_SLOTS)
        timezone = "",           -- e.g. "EST", "CST", "PST", "GMT", "CET"
        -- Roles & classes
        roles = {
            TANK   = { open = false, priority = "NONE", classes = {}, specs = {} },
            HEALER = { open = false, priority = "NONE", classes = {}, specs = {} },
            DPS    = { open = false, priority = "NONE", classes = {}, specs = {} },
        },
        preferredRaces = {},  -- { "BloodElf", "Orc", ... }
        questions = { "", "", "", "", "" },
        questionsEnabled = { true, true, true, false, false },
        minLevel = 80,
        minIlvl = 0,
        minMplus = 0,
        minRankIndex = 1,
        -- Team/rank recruiting for
        recruitTeam = "",           -- guild rank name or "All Ranks"
        -- M+ progress
        mplusTargetKey = 0,         -- target key level (2-30)
        mplusCurrentScore = 0,      -- current season M+ score
        -- Hardcore progress
        hardcoreHighestLevel = 0,
        hardcoreDeaths = 0,
        -- Message templates
        templates = {},  -- { [name] = { text = "", category = "prospect|accepted|rejected|welcome|custom" } }
        -- Auto-welcome
        welcomeMessages = { "", "", "", "", "" },
        autoWelcome = false,
        -- Prospect radar
        prospectRadar = true,
    },
    applications = {},
    history = {},
    teams = {
        { name = "Raid Team", members = {} },
        { name = "M+ Team", members = {} },
        { name = "PvP Team", members = {} },
    },
    banned = {},
    -- Member departure records (institutional memory)
    dossiers = {},  -- { ["Name-Realm"] = { name, realm, class, joinedAt, leftAt, leftHow, removedBy, officerNote, departureReason, encounters = {} } }
    -- Received guild listings from other guilds (channel broadcast cache)
    listings = {},
    -- Outbound applications awaiting ACK (retry queue)
    pendingOutbound = {},  -- { [guildName] = { payload, gapplyPayload, sender, guildName, sentAt, delivered } }
    settings = {
        expiryDays = 14,
        trialDays = 14,
        notifyOnApply = true,
        notifySound = true,
        autoReplyThrottle = 60,
        historyRetentionDays = 90,
        prospectCooldown = 600,   -- 10 min per prospect player
        welcomeCooldown = 30,     -- 30 sec between auto-welcomes
    },
}

local function DeepCopy(src)
    if type(src) ~= "table" then return src end
    local copy = {}
    for k, v in pairs(src) do copy[k] = DeepCopy(v) end
    return copy
end

local function EnsureDefaults(tbl, defaults)
    for k, v in pairs(defaults) do
        if tbl[k] == nil then
            tbl[k] = DeepCopy(v)
        elseif type(v) == "table" and type(tbl[k]) == "table" then
            EnsureDefaults(tbl[k], v)
        end
    end
end

local function InitDB()
    if not _G.MidnightUIGuildRecruit then
        _G.MidnightUIGuildRecruit = DeepCopy(DEFAULT_DB)
    end
    EnsureDefaults(_G.MidnightUIGuildRecruit, DEFAULT_DB)
    DB = _G.MidnightUIGuildRecruit

    -- Migrate flat banned entries to rich structure
    if DB.banned then
        for key, val in pairs(DB.banned) do
            if val == true then
                DB.banned[key] = {
                    name = key:match("^([^%-]+)") or key,
                    realm = key:match("%-(.+)$") or "",
                    class = "",
                    reason = "",
                    bannedBy = "",
                    bannedAt = 0,
                    expiresAt = 0,
                    duration = "PERM",
                }
            end
        end
    end
end

-- Ban duration options
local BAN_DURATIONS = {
    { key = "1D",   label = "1 Day",     seconds = 86400 },
    { key = "1W",   label = "1 Week",    seconds = 604800 },
    { key = "2W",   label = "2 Weeks",   seconds = 1209600 },
    { key = "1M",   label = "1 Month",   seconds = 2592000 },
    { key = "PERM", label = "Permanent", seconds = 0 },
}

local function IsBanned(key)
    local ban = DB and DB.banned and DB.banned[key]
    if not ban then return false end
    if type(ban) ~= "table" then return ban end  -- legacy compat
    if ban.expiresAt and ban.expiresAt > 0 and time() > ban.expiresAt then
        DB.banned[key] = nil
        return false
    end
    return true
end

local function BanPlayer(name, realm, classFile, reason, durationKey, bannedBy)
    if not DB or not DB.banned then return end
    local key = name .. (realm ~= "" and ("-" .. realm) or "")
    local dur = 0
    for _, d in ipairs(BAN_DURATIONS) do
        if d.key == durationKey then dur = d.seconds; break end
    end
    DB.banned[key] = {
        name = name,
        realm = realm or "",
        class = classFile or "",
        reason = reason or "",
        bannedBy = bannedBy or "",
        bannedAt = time(),
        expiresAt = dur > 0 and (time() + dur) or 0,
        duration = durationKey or "PERM",
    }
end

local function UnbanPlayer(key)
    if DB and DB.banned then DB.banned[key] = nil end
end

-- ============================================================================
-- §4  PERMISSION SYSTEM (rank-gated officer checks)
-- ============================================================================
local function CanManageRecruitment()
    if not IsInGuild() then return false end
    -- Check 1: CanGuildInvite — rank has invite permission
    if CanGuildInvite then
        local canInvite = SafeCall(CanGuildInvite)
        if canInvite then return true end
    end
    -- Check 2: C_GuildInfo.IsGuildOfficer — rank has "Is Officer" checked
    if C_GuildInfo and C_GuildInfo.IsGuildOfficer then
        local isOfficer = SafeCall(C_GuildInfo.IsGuildOfficer)
        if isOfficer then return true end
    end
    -- Check 3: rank index fallback
    local _, _, rankIndex = SafeCall(GetGuildInfo, "player")
    if not rankIndex then return false end
    local minRank = (DB and DB.config and DB.config.minRankIndex) or 3
    return rankIndex <= minRank
end

local function CanGuildInviteCheck()
    return CanManageRecruitment()
end

local function GetPlayerInfo()
    local name = SafeCall(UnitName, "player") or "Unknown"
    local _, classFile = SafeCall(UnitClass, "player")
    local level = SafeCall(UnitLevel, "player") or 0
    local specIdx = SafeCall(GetSpecialization)
    local specName = ""
    if specIdx then
        local _, sName = SafeCall(GetSpecializationInfo, specIdx)
        specName = sName or ""
    end

    -- ilvl
    local ilvl = 0
    if GetAverageItemLevel then
        local _, equipped = SafeCall(GetAverageItemLevel)
        ilvl = math.floor((equipped or 0) + 0.5)
    end

    -- M+ rating
    local mplusRating = 0
    if C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary then
        local summary = SafeCall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, "player")
        if summary and summary.currentSeasonScore then
            mplusRating = summary.currentSeasonScore
        end
    end

    -- Achievement points
    local achPts = 0
    if GetTotalAchievementPoints then
        achPts = SafeCall(GetTotalAchievementPoints) or 0
    end

    local realm = SafeCall(GetRealmName) or ""

    return {
        name = name,
        realm = realm,
        class = classFile or "",
        spec = specName,
        level = level,
        ilvl = ilvl,
        mplusRating = mplusRating,
        achievePts = achPts,
    }
end

-- ============================================================================
-- §5  SYNC PROTOCOL (RSYNC/ASYNC on login, version-vector resolution)
-- ============================================================================
local syncState = {
    hasSynced = false,
    lastSyncTime = 0,
}

local function BroadcastConfig()
    if not DB or not DB.config then return end
    local cfg = DB.config

    -- Serialize roles
    local function serializeRole(role)
        local r = cfg.roles[role] or {}
        local openStr = r.open and "1" or "0"
        local prio = r.priority or "NONE"
        local classes = table.concat(r.classes or {}, ",")
        if classes == "" then classes = "NONE" end
        return openStr .. "~" .. prio .. "~" .. classes
    end

    local payload = "RCONFIG|" .. (cfg.version or 0)
        .. "|" .. (cfg.enabled and "1" or "0")
        .. "|" .. (cfg.description or "")
        .. "|" .. serializeRole("TANK")
        .. "|" .. serializeRole("HEALER")
        .. "|" .. serializeRole("DPS")
        .. "|" .. (cfg.minLevel or 80)
        .. "|" .. (cfg.minIlvl or 0)
        .. "|" .. (cfg.minMplus or 0)

    SendChunked(payload, "GUILD")

    -- Send questions separately (smaller messages)
    for i = 1, 5 do
        local q = cfg.questions[i] or ""
        local enabled = (cfg.questionsEnabled[i] ~= false) and "1" or "0"
        if q ~= "" then
            C_Timer.After(0.3 * i, function()
                local qPayload = "RQUEST|" .. (cfg.version or 0) .. "|" .. i .. "|" .. enabled .. "|" .. q
                SendChunked(qPayload, "GUILD")
            end)
        end
    end
end

-- Broadcast a compact guild listing to the shared channel for cross-guild discovery
local function BroadcastListing()
    if not DB or not DB.config or not DB.config.enabled then return end
    if not recruitChannelId then return end

    local now = time()
    if now - lastChannelBroadcast < CHANNEL_BROADCAST_INTERVAL then return end
    lastChannelBroadcast = now

    local cfg = DB.config
    local guildName = ""
    if IsInGuild() then guildName = SafeCall(GetGuildInfo, "player") or "" end
    if guildName == "" then return end

    -- Serialize guild types
    local gtStr = table.concat(cfg.guildType or {}, ",")
    if gtStr == "" then gtStr = "NONE" end

    -- Serialize raid days
    local dayStr = table.concat(cfg.raidDays or {}, ",")
    if dayStr == "" then dayStr = "NONE" end

    -- Serialize open roles compactly: TANK~1~HIGH~WARRIOR,DK|HEALER~0~NONE~NONE|DPS~1~LOW~NONE
    local function serializeRole(role)
        local r = cfg.roles[role] or {}
        local openStr = r.open and "1" or "0"
        local prio = r.priority or "NONE"
        local classes = table.concat(r.classes or {}, ",")
        if classes == "" then classes = "NONE" end
        return openStr .. "~" .. prio .. "~" .. classes
    end

    -- GLISTING|guildName|realm|faction|region|guildTypes|raidProgress|raidDays|raidTime|timezone|tank|healer|dps|minIlvl|minMplus|description
    local payload = "GLISTING"
        .. "|" .. guildName
        .. "|" .. (cfg.realm or "")
        .. "|" .. (cfg.faction or "")
        .. "|" .. (cfg.region or "")
        .. "|" .. gtStr
        .. "|" .. (cfg.raidProgress or "")
        .. "|" .. dayStr
        .. "|" .. (cfg.raidTime or "")
        .. "|" .. (cfg.timezone or "")
        .. "|" .. serializeRole("TANK")
        .. "|" .. serializeRole("HEALER")
        .. "|" .. serializeRole("DPS")
        .. "|" .. (cfg.minIlvl or 0)
        .. "|" .. (cfg.minMplus or 0)
        .. "|" .. (cfg.description or "")

    SendChunked(payload, "CHANNEL", tostring(recruitChannelId))
end

-- Relay: re-broadcast cached listings from other guilds so they persist in the network
local function RelayListings()
    if not DB or not DB.listings then return end
    if not recruitChannelId then return end

    local now = time()
    if now - lastRelayTime < RELAY_INTERVAL then return end
    lastRelayTime = now

    -- Collect valid listings (not expired, not our own guild)
    local myGuild = ""
    if IsInGuild() then myGuild = SafeCall(GetGuildInfo, "player") or "" end

    local toRelay = {}
    for key, listing in pairs(DB.listings) do
        if listing.guildName ~= myGuild and (now - (listing.receivedAt or 0)) < LISTING_TTL then
            toRelay[#toRelay + 1] = { key = key, listing = listing }
        end
    end

    -- Relay up to RELAY_MAX_PER_CYCLE listings, staggered
    local count = math.min(#toRelay, RELAY_MAX_PER_CYCLE)
    for i = 1, count do
        local entry = toRelay[i]
        local l = entry.listing

        C_Timer.After(0.5 * i, function()
            local function serializeRole(r)
                if not r then return "0~NONE~NONE" end
                local openStr = r.open and "1" or "0"
                local prio = r.priority or "NONE"
                local classes = table.concat(r.classes or {}, ",")
                if classes == "" then classes = "NONE" end
                return openStr .. "~" .. prio .. "~" .. classes
            end

            local gtStr = table.concat(l.guildType or {}, ",")
            if gtStr == "" then gtStr = "NONE" end
            local dayStr = table.concat(l.raidDays or {}, ",")
            if dayStr == "" then dayStr = "NONE" end

            local payload = "GLISTING"
                .. "|" .. (l.guildName or "")
                .. "|" .. (l.realm or "")
                .. "|" .. (l.faction or "")
                .. "|" .. (l.region or "")
                .. "|" .. gtStr
                .. "|" .. (l.raidProgress or "")
                .. "|" .. dayStr
                .. "|" .. (l.raidTime or "")
                .. "|" .. (l.timezone or "")
                .. "|" .. serializeRole(l.roles and l.roles.TANK)
                .. "|" .. serializeRole(l.roles and l.roles.HEALER)
                .. "|" .. serializeRole(l.roles and l.roles.DPS)
                .. "|" .. (l.minIlvl or 0)
                .. "|" .. (l.minMplus or 0)
                .. "|" .. (l.description or "")

            SendChunked(payload, "CHANNEL", tostring(recruitChannelId))
        end)
    end
end

local function BroadcastClear()
    if not DB or not DB.config then return end
    local payload = "RCLEAR|" .. (DB.config.version or 0)
    pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, payload, "GUILD")
end

local function RequestSync()
    if not DB or not DB.config then return end
    local payload = "RSYNC|" .. (DB.config.version or 0)
    pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, payload, "GUILD")
    syncState.hasSynced = true
    syncState.lastSyncTime = time()
end

local function ParseRole(str)
    if not str or str == "" then return { open = false, priority = "NONE", classes = {} } end
    local openStr, prio, classStr = strsplit("~", str)
    local open = openStr == "1"
    prio = prio or "NONE"
    local classes = {}
    if classStr and classStr ~= "NONE" and classStr ~= "" then
        for c in classStr:gmatch("[^,]+") do
            classes[#classes + 1] = c
        end
    end
    return { open = open, priority = prio, classes = classes }
end

local function HandleRCONFIG(message, sender)
    local parts = { strsplit("|", message) }
    -- RCONFIG|ver|enabled|desc|tank|healer|dps|minLvl|minIlvl|minMplus
    if #parts < 10 then return end

    local ver = tonumber(parts[2]) or 0
    local myVer = (DB and DB.config and DB.config.version) or 0

    if ver <= myVer then return end  -- stale or same version, ignore

    DB.config.version = ver
    DB.config.enabled = parts[3] == "1"
    DB.config.description = parts[4] or ""
    DB.config.roles.TANK = ParseRole(parts[5])
    DB.config.roles.HEALER = ParseRole(parts[6])
    DB.config.roles.DPS = ParseRole(parts[7])
    DB.config.minLevel = tonumber(parts[8]) or 80
    DB.config.minIlvl = tonumber(parts[9]) or 0
    DB.config.minMplus = tonumber(parts[10]) or 0
    DB.config.lastUpdated = time()
    DB.config.updatedBy = sender or ""

    -- Refresh UI if open
    Recruit.RefreshBadge()
    Recruit.RefreshConfigOverlay()
end

local function HandleRQUEST(message, sender)
    local parts = { strsplit("|", message) }
    -- RQUEST|ver|qIdx|enabled|questionText
    if #parts < 5 then return end

    local ver = tonumber(parts[2]) or 0
    local myVer = (DB and DB.config and DB.config.version) or 0
    if ver < myVer then return end  -- only accept from same or newer version

    local qIdx = tonumber(parts[3]) or 0
    if qIdx < 1 or qIdx > 5 then return end

    local enabled = parts[4] == "1"
    local qText = parts[5] or ""

    DB.config.questions[qIdx] = qText
    DB.config.questionsEnabled[qIdx] = enabled
end

local function HandleRCLEAR(message, sender)
    local parts = { strsplit("|", message) }
    local ver = tonumber(parts[2]) or 0
    local myVer = (DB and DB.config and DB.config.version) or 0
    if ver < myVer then return end

    DB.config.version = ver
    DB.config.enabled = false
    DB.config.lastUpdated = time()
    DB.config.updatedBy = sender or ""

    Recruit.RefreshBadge()
    Recruit.RefreshConfigOverlay()
end

local function HandleRSYNC(message, sender)
    local parts = { strsplit("|", message) }
    local theirVer = tonumber(parts[2]) or 0
    local myVer = (DB and DB.config and DB.config.version) or 0

    -- If we have a newer version, send it to them
    if myVer > theirVer and CanManageRecruitment() then
        C_Timer.After(1 + math.random() * 2, function()
            BroadcastConfig()
        end)
    end
end

-- ── Application Protocol Handlers (Phase 2) ──

local function HandleAPPLY(message, sender)
    local parts = { strsplit("|", message) }
    -- APPLY|name|realm|class|spec|level|ilvl|mplus|achPts|role|availability
    if #parts < 7 then return end

    local appName = parts[2] or ""
    local appRealm = parts[3] or ""
    local appClass = parts[4] or ""
    local appSpec = parts[5] or ""
    local appLevel = tonumber(parts[6]) or 0
    local appIlvl = tonumber(parts[7]) or 0
    local appMplus = tonumber(parts[8]) or 0
    local appAchPts = tonumber(parts[9]) or 0
    local appRole = parts[10] or ""
    local appAvail = parts[11] or ""

    local key = appName .. "-" .. appRealm
    if key == "-" then key = appName end

    -- Check ban list
    if IsBanned(key) then return end

    -- Don't overwrite existing pending app
    if DB.applications[key] and DB.applications[key].status == STATUS.PENDING then return end

    DB.applications[key] = {
        name = appName,
        realm = appRealm,
        class = appClass,
        spec = appSpec,
        level = appLevel,
        ilvl = appIlvl,
        mplusRating = appMplus,
        achievePts = appAchPts,
        role = appRole,
        availability = appAvail,
        answers = {},
        status = STATUS.PENDING,
        appliedAt = time(),
        statusChangedAt = time(),
        statusChangedBy = "",
        officerNotes = {},
        votes = { up = {}, down = {} },
        source = "addon",
        trialStarted = nil,
        trialDays = (DB.settings and DB.settings.trialDays) or 14,
    }

    -- RaiderIO enrichment (snapshot at receive time)
    EnrichWithRaiderIO(DB.applications[key])

    -- Check dossier for returning players
    local dossier = CheckDossierOnApply(appName, appRealm)

    -- Show notification to officers
    if CanManageRecruitment() or CanGuildInviteCheck() then
        if dossier then
            Recruit.ShowDossierToast(appName, dossier)
        else
            Recruit.ShowApplicationToast(appName, appClass, appSpec, appMplus, appIlvl)
        end
    end

    -- Store dossier reference on the application
    if dossier then
        DB.applications[key].dossierKey = appName .. "-" .. (appRealm or "")
    end

    -- Send ACK back to applicant so they stop retrying
    local ackPayload = "AACK|" .. (appName or "") .. "|" .. (appRealm or "")
    pcall(function()
        if sender and sender ~= "" then
            SendChunked(ackPayload, "WHISPER", sender)
        end
        if recruitChannelId then
            C_Timer.After(0.3, function()
                SendChunked(ackPayload, "CHANNEL", tostring(recruitChannelId))
            end)
        end
    end)

    Recruit.RefreshBadge()
    Recruit.RefreshReviewPanel()
end

local function HandleAANSWER(message, sender)
    local parts = { strsplit("|", message) }
    -- AANSWER|name|qIdx|answerText
    if #parts < 4 then return end

    local appName = parts[2] or ""
    local qIdx = tonumber(parts[3]) or 0
    if qIdx < 1 or qIdx > 5 then return end

    -- Find the application by name (try name-realm first, then just name)
    local app = nil
    for key, a in pairs(DB.applications) do
        if a.name == appName or key:match("^" .. appName) then
            app = a
            break
        end
    end
    if not app then return end
    app.answers[qIdx] = parts[4] or ""
end

local function HandleASTATUS(message, sender)
    local parts = { strsplit("|", message) }
    -- ASTATUS|name|realm|newStatus|officerName
    if #parts < 5 then return end

    local appName = parts[2] or ""
    local appRealm = parts[3] or ""
    local newStatus = parts[4] or ""
    local officerName = parts[5] or ""
    local key = appName .. "-" .. appRealm
    if key == "-" then key = appName end

    if not DB.applications[key] then return end
    if not STATUS[newStatus] then return end

    DB.applications[key].status = newStatus
    DB.applications[key].statusChangedAt = time()
    DB.applications[key].statusChangedBy = officerName

    if newStatus == STATUS.TRIAL then
        DB.applications[key].trialStarted = time()
    end

    -- Move to history if terminal status
    if newStatus == STATUS.ACCEPTED or newStatus == STATUS.REJECTED or newStatus == STATUS.WITHDRAWN then
        local app = DB.applications[key]
        app.archivedAt = time()
        DB.history[key] = app
        DB.applications[key] = nil
    end

    Recruit.RefreshBadge()
    Recruit.RefreshReviewPanel()
end

local function HandleONOTE(message, sender)
    local parts = { strsplit("|", message) }
    -- ONOTE|name|realm|officerName|noteText
    if #parts < 5 then return end

    local appName = parts[2] or ""
    local appRealm = parts[3] or ""
    local officerName = parts[4] or ""
    local noteText = parts[5] or ""
    local key = appName .. "-" .. appRealm
    if key == "-" then key = appName end

    if not DB.applications[key] then return end

    local notes = DB.applications[key].officerNotes
    notes[#notes + 1] = {
        officer = officerName,
        note = noteText,
        time = time(),
    }
end

local function HandleOVOTE(message, sender)
    local parts = { strsplit("|", message) }
    -- OVOTE|name|realm|officerName|UP_or_DOWN
    if #parts < 5 then return end

    local appName = parts[2] or ""
    local appRealm = parts[3] or ""
    local officerName = parts[4] or ""
    local voteDir = parts[5] or ""
    local key = appName .. "-" .. appRealm
    if key == "-" then key = appName end

    if not DB.applications[key] then return end

    local votes = DB.applications[key].votes

    -- Remove existing vote from this officer
    for i = #votes.up, 1, -1 do
        if votes.up[i] == officerName then table.remove(votes.up, i) end
    end
    for i = #votes.down, 1, -1 do
        if votes.down[i] == officerName then table.remove(votes.down, i) end
    end

    -- Add new vote
    if voteDir == "UP" then
        votes.up[#votes.up + 1] = officerName
    elseif voteDir == "DOWN" then
        votes.down[#votes.down + 1] = officerName
    end

    Recruit.RefreshReviewPanel()
end

local function HandleASYNC(message, sender)
    -- Respond with all pending applications
    if not CanManageRecruitment() then return end

    local idx = 0
    for key, app in pairs(DB.applications) do
        idx = idx + 1
        C_Timer.After(0.3 * idx, function()
            local payload = "AENTRY|" .. (app.name or "") .. "|" .. (app.realm or "")
                .. "|" .. (app.class or "") .. "|" .. (app.spec or "")
                .. "|" .. (app.level or 0) .. "|" .. (app.ilvl or 0)
                .. "|" .. (app.mplusRating or 0) .. "|" .. (app.role or "")
                .. "|" .. (app.status or STATUS.PENDING)
                .. "|" .. (app.appliedAt or 0) .. "|" .. (app.source or "addon")
            SendChunked(payload, "GUILD")
        end)
    end
end

local function HandleAENTRY(message, sender)
    local parts = { strsplit("|", message) }
    -- AENTRY|name|realm|class|spec|level|ilvl|mplus|role|status|appliedAt|source
    if #parts < 12 then return end

    local appName = parts[2] or ""
    local appRealm = parts[3] or ""
    local key = appName .. "-" .. appRealm
    if key == "-" then key = appName end

    -- Only accept if we don't already have this application
    if DB.applications[key] then return end

    DB.applications[key] = {
        name = appName,
        realm = appRealm,
        class = parts[4] or "",
        spec = parts[5] or "",
        level = tonumber(parts[6]) or 0,
        ilvl = tonumber(parts[7]) or 0,
        mplusRating = tonumber(parts[8]) or 0,
        achievePts = 0,
        role = parts[9] or "",
        availability = "",
        answers = {},
        status = parts[10] or STATUS.PENDING,
        appliedAt = tonumber(parts[11]) or 0,
        statusChangedAt = time(),
        statusChangedBy = "",
        officerNotes = {},
        votes = { up = {}, down = {} },
        source = parts[12] or "addon",
    }

    Recruit.RefreshBadge()
    Recruit.RefreshReviewPanel()
end

-- ── Handle incoming guild listing from shared channel ──
-- Handle cross-guild application received via shared channel
-- Only processes if the target guild matches YOUR guild
local function HandleGAPPLY(message, sender)
    local parts = { strsplit("|", message) }
    -- GAPPLY|targetGuild|name|realm|class|spec|level|ilvl|mplus|achPts|role|availability
    if #parts < 7 then return end

    local targetGuild = parts[2] or ""
    if not IsInGuild() then return end

    local myGuild = SafeCall(GetGuildInfo, "player") or ""
    if myGuild == "" or myGuild ~= targetGuild then return end  -- not for us

    -- Reconstruct as a standard APPLY message and process it
    local applyMsg = "APPLY"
    for i = 3, #parts do
        applyMsg = applyMsg .. "|" .. (parts[i] or "")
    end
    HandleAPPLY(applyMsg, sender)
end

-- ── ACK handler: marks outbound application as delivered ──
local function HandleAACK(message, sender)
    local parts = { strsplit("|", message) }
    -- AACK|name|realm
    if #parts < 3 then return end
    local ackName = parts[2] or ""
    local ackRealm = parts[3] or ""

    -- Check if we have a pending outbound for this name
    local playerName = UnitName("player") or ""
    local playerRealm = GetRealmName() or ""
    if ackName ~= playerName then return end  -- not for us

    if DB and DB.pendingOutbound then
        for guildKey, pending in pairs(DB.pendingOutbound) do
            if not pending.delivered then
                pending.delivered = true
                dbg("|cff40d940[Recruit]|r Application to " .. guildKey .. " confirmed delivered.")
            end
        end
    end
end

-- ── Retry timer: resend undelivered applications every 25-35 minutes ──
local function StartRetryTimer()
    local delay = 1500 + math.random(0, 600)  -- 25-35 minutes in seconds
    C_Timer.After(delay, function()
        if not DB or not DB.pendingOutbound then
            StartRetryTimer()
            return
        end

        for guildKey, pending in pairs(DB.pendingOutbound) do
            if not pending.delivered then
                local age = time() - (pending.sentAt or 0)
                -- Give up after 48 hours
                if age > 172800 then
                    DB.pendingOutbound[guildKey] = nil
                else
                    -- Retry via channel
                    if recruitChannelId and pending.gapplyPayload then
                        pcall(function()
                            SendChunked(pending.gapplyPayload, "CHANNEL", tostring(recruitChannelId))
                        end)
                    end
                    -- Retry via whisper if we know the officer
                    if pending.sender and pending.sender ~= "" and pending.payload then
                        C_Timer.After(0.5, function()
                            pcall(function()
                                SendChunked(pending.payload, "WHISPER", pending.sender)
                            end)
                        end)
                    end
                end
            end
        end

        StartRetryTimer()
    end)
end

local function HandleGLISTING(message, sender)
    local parts = { strsplit("|", message) }
    -- GLISTING|guildName|realm|faction|region|guildTypes|raidProgress|raidDays|raidTime|timezone|tank|healer|dps|minIlvl|minMplus|description
    if #parts < 14 then return end

    local guildName = parts[2] or ""
    local realm = parts[3] or ""
    if guildName == "" then return end

    -- Don't store our own guild's listing
    if IsInGuild() then
        local myGuild = SafeCall(GetGuildInfo, "player") or ""
        if myGuild == guildName then return end
    end

    local key = guildName .. "-" .. realm

    -- Parse guild types
    local guildTypes = {}
    if parts[6] and parts[6] ~= "NONE" then
        for gt in parts[6]:gmatch("[^,]+") do guildTypes[#guildTypes + 1] = gt end
    end

    -- Parse raid days
    local raidDays = {}
    if parts[8] and parts[8] ~= "NONE" then
        for d in parts[8]:gmatch("[^,]+") do raidDays[#raidDays + 1] = d end
    end

    DB.listings[key] = {
        guildName = guildName,
        realm = realm,
        faction = parts[4] or "",
        region = parts[5] or "",
        guildType = guildTypes,
        raidProgress = parts[7] or "",
        raidDays = raidDays,
        raidTime = parts[9] or "",
        timezone = parts[10] or "",
        roles = {
            TANK   = ParseRole(parts[11]),
            HEALER = ParseRole(parts[12]),
            DPS    = ParseRole(parts[13]),
        },
        minIlvl = tonumber(parts[14]) or 0,
        minMplus = tonumber(parts[15]) or 0,
        description = parts[16] or "",
        sender = sender,
        receivedAt = time(),
    }

    -- Refresh the guild finder panel if open
    Recruit.RefreshGuildFinder()
end

-- ============================================================================
-- §6  MESSAGE HANDLERS (CHAT_MSG_ADDON, CHAT_MSG_WHISPER, CHAT_MSG_GUILD)
-- ============================================================================
local msgEvf = CreateFrame("Frame")
msgEvf:RegisterEvent("CHAT_MSG_ADDON")
msgEvf:RegisterEvent("CHAT_MSG_GUILD")
msgEvf:RegisterEvent("CHAT_MSG_WHISPER")

local lastAutoReply = 0

msgEvf:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if not DB then return end

    if event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = arg1, arg2, arg3, arg4
        if prefix ~= RCRT_PREFIX then return end

        local shortSender = sender and sender:match("^([^%-]+)") or sender or ""

        -- Process chunking
        local fullMsg = ProcessChunk(shortSender, message)
        if not fullMsg then return end  -- still buffering chunks

        -- Route by command
        local cmd = fullMsg:match("^(%a+)|") or fullMsg:match("^(%a+)$")
        if not cmd then return end

        if     cmd == "RCONFIG" then HandleRCONFIG(fullMsg, shortSender)
        elseif cmd == "RQUEST"  then HandleRQUEST(fullMsg, shortSender)
        elseif cmd == "RCLEAR"  then HandleRCLEAR(fullMsg, shortSender)
        elseif cmd == "RSYNC"   then HandleRSYNC(fullMsg, shortSender)
        elseif cmd == "APPLY"   then HandleAPPLY(fullMsg, shortSender)
        elseif cmd == "AANSWER" then HandleAANSWER(fullMsg, shortSender)
        elseif cmd == "ASTATUS" then HandleASTATUS(fullMsg, shortSender)
        elseif cmd == "ONOTE"   then HandleONOTE(fullMsg, shortSender)
        elseif cmd == "OVOTE"   then HandleOVOTE(fullMsg, shortSender)
        elseif cmd == "ASYNC"   then HandleASYNC(fullMsg, shortSender)
        elseif cmd == "AENTRY"  then HandleAENTRY(fullMsg, shortSender)
        elseif cmd == "GLISTING" then HandleGLISTING(fullMsg, shortSender)
        elseif cmd == "GAPPLY"  then HandleGAPPLY(fullMsg, shortSender)
        elseif cmd == "AACK"    then HandleAACK(fullMsg, shortSender)
        end

    elseif event == "CHAT_MSG_GUILD" then
        local msg, sender = arg1, arg2
        if not msg or not sender then return end
        local trimmed = msg:match("^%s*(.-)%s*$") or msg
        local lower = trimmed:lower()
        local shortSender = sender:match("^([^%-]+)") or sender

        -- !recruit command
        if lower == "!recruit" or lower == "!recruiting" then
            local now = time()
            local throttle = (DB.settings and DB.settings.autoReplyThrottle) or 60
            if now - lastAutoReply < throttle then return end

            if not DB.config.enabled then return end

            lastAutoReply = now
            local reply = Recruit.FormatRecruitmentMessage()
            if reply then
                C_Timer.After(0.5, function()
                    pcall(SendChatMessage, reply, "GUILD")
                end)
            end
        end

        -- !apply command (Phase 2 - create chat-based application)
        if lower == "!apply" then
            if not DB.config.enabled then return end
            local playerName = SafeCall(UnitName, "player") or ""
            if shortSender == playerName then return end

            -- Only one officer should respond; use a deterministic check
            if not CanGuildInviteCheck() then return end

            local key = shortSender
            if not DB.applications[key] then
                DB.applications[key] = {
                    name = shortSender,
                    realm = "",
                    class = "",
                    spec = "",
                    level = 0,
                    ilvl = 0,
                    mplusRating = 0,
                    achievePts = 0,
                    role = "",
                    availability = "",
                    answers = {},
                    status = STATUS.PENDING,
                    appliedAt = time(),
                    statusChangedAt = time(),
                    statusChangedBy = "",
                    officerNotes = {},
                    votes = { up = {}, down = {} },
                    source = "chat",
                }

                Recruit.ShowApplicationToast(shortSender, "", "", 0, 0)
                Recruit.RefreshBadge()
                Recruit.RefreshReviewPanel()

                -- Auto-whisper the applicant
                C_Timer.After(1, function()
                    pcall(SendChatMessage,
                        "[MUI] Thanks for your interest! An officer will review your application. You can whisper us your role (tank/healer/dps) and availability.",
                        "WHISPER", nil, shortSender)
                end)
            end
        end

    elseif event == "CHAT_MSG_WHISPER" then
        local msg, sender = arg1, arg2
        if not msg or not sender then return end
        local trimmed = msg:match("^%s*(.-)%s*$") or msg
        local lower = trimmed:lower()
        local shortSender = sender:match("^([^%-]+)") or sender

        -- !apply command via whisper (cross-guild)
        if lower:match("^!apply") then
            if not DB.config.enabled then return end
            if not CanGuildInviteCheck() then return end

            -- Check ban list
            if IsBanned(shortSender) then return end

            local key = shortSender
            if not DB.applications[key] then
                DB.applications[key] = {
                    name = shortSender,
                    realm = "",
                    class = "",
                    spec = "",
                    level = 0,
                    ilvl = 0,
                    mplusRating = 0,
                    achievePts = 0,
                    role = "",
                    availability = "",
                    answers = {},
                    status = STATUS.PENDING,
                    appliedAt = time(),
                    statusChangedAt = time(),
                    statusChangedBy = "",
                    officerNotes = {},
                    votes = { up = {}, down = {} },
                    source = "whisper",
                }

                Recruit.ShowApplicationToast(shortSender, "", "", 0, 0)
                Recruit.RefreshBadge()
                Recruit.RefreshReviewPanel()

                -- Try to send recruitment config via addon whisper (MUI-to-MUI)
                C_Timer.After(0.5, function()
                    BroadcastConfig()  -- they'll receive it if they have MUI
                end)

                -- Also auto-whisper
                C_Timer.After(1, function()
                    pcall(SendChatMessage,
                        "[MUI] Thanks for your interest in our guild! An officer will review your application shortly.",
                        "WHISPER", nil, sender)
                end)
            end
        end
    end
end)

-- ============================================================================
-- §7  UI: RECRUITMENT CONFIG OVERLAY (officer-only)
-- ============================================================================
local configOverlay = nil
local configState = {
    roleToggles = {},
    prioButtons = {},
    classButtons = {},
    questionInputs = {},
    questionToggles = {},
    descInput = nil,
    minLvlInput = nil,
    minIlvlInput = nil,
    minMplusInput = nil,
    enableToggle = nil,
}

-- Theme helper: reads from GuildPanel's theme system
local function GetThemeColors()
    local C = {}
    -- Try to read from GuildPanel's loaded theme
    local gp = _G.MidnightUI_GuildPanelAPI
    if gp and gp._theme then
        for k, v in pairs(gp._theme) do C[k] = v end
        return C
    end
    -- Fallback to midnight theme
    C.frameBg    = { 0.06, 0.07, 0.12, 0.97 }
    C.headerBg   = { 0.07, 0.08, 0.14, 0.95 }
    C.heroBg     = { 0.08, 0.09, 0.16, 0.92 }
    C.panelBg    = { 0.06, 0.07, 0.13, 0.95 }
    C.chatBg     = { 0.04, 0.05, 0.10, 0.95 }
    C.accent     = { 0.00, 0.78, 1.00 }
    C.titleText  = { 0.92, 0.93, 0.96 }
    C.bodyText   = { 0.82, 0.84, 0.88 }
    C.mutedText  = { 0.58, 0.60, 0.65 }
    C.divider    = { 0.25, 0.35, 0.55 }
    C.inputBg    = { 0.05, 0.06, 0.10, 0.9 }
    C.hoverBg    = { 0.10, 0.14, 0.25, 0.4 }
    C.borderTint = { 0.00, 0.78, 1.00, 0.5 }
    C.online     = { 0.40, 0.85, 0.40 }
    C.offline    = { 0.50, 0.50, 0.50 }
    return C
end

function Recruit.ShowConfigOverlay()
    if not CanManageRecruitment() then
        local dbg = _G.MidnightUI_Debug or print
        dbg("|cffff5555[Recruitment]|r You don't have permission to manage recruitment.")
        return
    end

    local gp = _G.MidnightUI_GuildPanelAPI
    local parent = (gp and gp._refs and gp._refs.panel) or UIParent
    local C = GetThemeColors()

    if configOverlay and configOverlay:IsShown() then
        configOverlay:Hide()
        return
    end

    if configOverlay then
        Recruit.RefreshConfigOverlay()
        configOverlay:Show()
        return
    end

    -- ── Build the overlay ──
    local PAD = 20
    local OVL_W, OVL_H = 1100, 920
    local LEFT_W = math.floor(OVL_W * 0.46)   -- 506
    local RIGHT_W = OVL_W - LEFT_W             -- 594

    -- Auto-detect faction, realm, region on first open
    if DB and DB.config then
        if (DB.config.faction == nil or DB.config.faction == "") then
            local factionName = SafeCall(UnitFactionGroup, "player")
            DB.config.faction = factionName or ""
        end
        if (DB.config.realm == nil or DB.config.realm == "") then
            DB.config.realm = SafeCall(GetRealmName) or ""
        end
        if (DB.config.region == nil or DB.config.region == "") then
            local regionID = SafeCall(GetCurrentRegion)
            local regionMap = { [1] = "US", [2] = "KR", [3] = "EU", [4] = "TW", [5] = "CN" }
            DB.config.region = regionMap[regionID] or "US"
        end
        -- Ensure new config fields have defaults
        if DB.config.recruitTeam == nil then DB.config.recruitTeam = "All Ranks" end
        if DB.config.mplusTargetKey == nil then DB.config.mplusTargetKey = 15 end
        if DB.config.mplusCurrentScore == nil then DB.config.mplusCurrentScore = 0 end
        if DB.config.hardcoreHighestLevel == nil then DB.config.hardcoreHighestLevel = 0 end
        if DB.config.hardcoreDeaths == nil then DB.config.hardcoreDeaths = 0 end
    end

    configOverlay = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    configOverlay:SetSize(OVL_W, OVL_H)
    configOverlay:SetPoint("CENTER", parent, "CENTER", 0, 0)
    configOverlay:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    configOverlay:SetBackdropColor(0.020, 0.022, 0.038, 0.98)
    configOverlay:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.18)
    configOverlay:SetFrameLevel(parent:GetFrameLevel() + 30)
    configOverlay:EnableMouse(true); configOverlay:SetMovable(true); configOverlay:SetClampedToScreen(true)

    -- 8-layer drop shadow
    for i = 1, 8 do
        local s = configOverlay:CreateTexture(nil, "BACKGROUND", nil, -1)
        local off = i * 2.5
        s:SetColorTexture(0, 0, 0, 0.22 - (i * 0.024))
        s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
    end

    -- Top accent bar (3px gradient)
    local topBar = configOverlay:CreateTexture(nil, "OVERLAY", nil, 4)
    topBar:SetHeight(3); topBar:SetPoint("TOPLEFT", 1, -1); topBar:SetPoint("TOPRIGHT", -1, -1)
    topBar:SetTexture(W8)
    if topBar.SetGradient and CreateColor then
        topBar:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.9),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.1))
    end

    -- 80px vertical ambient glow
    local ambGlow = configOverlay:CreateTexture(nil, "BACKGROUND", nil, 1)
    ambGlow:SetHeight(80); ambGlow:SetPoint("TOPLEFT", 1, -4); ambGlow:SetPoint("TOPRIGHT", -1, -4)
    ambGlow:SetTexture(W8)
    if ambGlow.SetGradient and CreateColor then
        ambGlow:SetGradient("VERTICAL",
            CreateColor(0, 0, 0, 0),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.06))
    end

    -- ── Header (50px, draggable) ──
    local headerBar = CreateFrame("Frame", nil, configOverlay)
    headerBar:SetHeight(50); headerBar:SetPoint("TOPLEFT", 0, 0); headerBar:SetPoint("TOPRIGHT", 0, 0)
    headerBar:EnableMouse(true); headerBar:RegisterForDrag("LeftButton")
    headerBar:SetScript("OnDragStart", function() configOverlay:StartMoving() end)
    headerBar:SetScript("OnDragStop", function() configOverlay:StopMovingOrSizing() end)

    local hdrLine = headerBar:CreateTexture(nil, "OVERLAY")
    hdrLine:SetHeight(1); hdrLine:SetPoint("BOTTOMLEFT", 1, 0); hdrLine:SetPoint("BOTTOMRIGHT", -1, 0)
    hdrLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.15)

    local titleFS = headerBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(titleFS, TITLE_FONT, 18, "OUTLINE")
    titleFS:SetPoint("LEFT", headerBar, "LEFT", PAD, 0)
    titleFS:SetText("Guild Recruitment")
    titleFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    titleFS:SetShadowColor(0, 0, 0, 0.6); titleFS:SetShadowOffset(1, -1)

    local subtitleFS = headerBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(subtitleFS, BODY_FONT, 10, "")
    subtitleFS:SetPoint("LEFT", titleFS, "RIGHT", 10, 0)
    subtitleFS:SetText("Configure your guild's recruitment")
    subtitleFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7)

    -- Close X button
    local closeBtn = CreateFrame("Button", nil, headerBar)
    closeBtn:SetSize(28, 28); closeBtn:SetPoint("RIGHT", headerBar, "RIGHT", -10, 0)
    local closeTx = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeTx, TITLE_FONT, 16, "OUTLINE"); closeTx:SetPoint("CENTER"); closeTx:SetText("X")
    closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)
    closeBtn:SetScript("OnEnter", function() closeTx:SetTextColor(1, 0.35, 0.35) end)
    closeBtn:SetScript("OnLeave", function() closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5) end)
    closeBtn:SetScript("OnClick", function() configOverlay:Hide() end)

    -- ── Tab buttons: Settings / Applications ──
    local tabSettingsBtn = CreateFrame("Button", nil, headerBar)
    tabSettingsBtn:SetSize(90, 24); tabSettingsBtn:SetPoint("RIGHT", closeBtn, "LEFT", -12, 0)
    local tabSettingsBg = tabSettingsBtn:CreateTexture(nil, "BACKGROUND"); tabSettingsBg:SetAllPoints()
    local tabSettingsFS = tabSettingsBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(tabSettingsFS, BODY_FONT, 10, "OUTLINE"); tabSettingsFS:SetPoint("CENTER")
    tabSettingsFS:SetText("Settings")

    local tabAppsBtn = CreateFrame("Button", nil, headerBar)
    tabAppsBtn:SetSize(120, 24); tabAppsBtn:SetPoint("RIGHT", tabSettingsBtn, "LEFT", -4, 0)
    local tabAppsBg = tabAppsBtn:CreateTexture(nil, "BACKGROUND"); tabAppsBg:SetAllPoints()
    local tabAppsFS = tabAppsBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(tabAppsFS, BODY_FONT, 10, "OUTLINE"); tabAppsFS:SetPoint("CENTER")
    tabAppsFS:SetText("Applications")

    configOverlay._tabSettings = { btn = tabSettingsBtn, bg = tabSettingsBg, fs = tabSettingsFS }
    configOverlay._tabApps = { btn = tabAppsBtn, bg = tabAppsBg, fs = tabAppsFS }
    configOverlay._activeTab = "settings"

    -- ── Content area (between header and action bar, no scroll) ──
    local content = CreateFrame("Frame", nil, configOverlay)
    content:SetPoint("TOPLEFT", configOverlay, "TOPLEFT", 0, -50)
    content:SetPoint("BOTTOMRIGHT", configOverlay, "BOTTOMRIGHT", 0, 54)

    -- ── Left column (46%) with scroll safety net ──
    local leftScroll = CreateFrame("ScrollFrame", nil, content)
    leftScroll:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    leftScroll:SetPoint("BOTTOMLEFT", content, "BOTTOMLEFT", 0, 0)
    leftScroll:SetWidth(LEFT_W)
    leftScroll:EnableMouseWheel(true)
    leftScroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local maxScroll = math.max(0, (self:GetScrollChild():GetHeight() or 0) - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(maxScroll, cur - delta * 30)))
    end)
    local leftCol = CreateFrame("Frame", nil, leftScroll)
    leftCol:SetWidth(LEFT_W)
    leftScroll:SetScrollChild(leftCol)

    -- ── Right column (54%) ──
    local rightCol = CreateFrame("Frame", nil, content)
    rightCol:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
    rightCol:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
    rightCol:SetWidth(RIGHT_W)

    -- ── 1px vertical divider ──
    local vDiv = content:CreateTexture(nil, "OVERLAY")
    vDiv:SetWidth(1)
    vDiv:SetPoint("TOP", content, "TOP", LEFT_W - (OVL_W / 2), -8)
    vDiv:SetPoint("BOTTOM", content, "BOTTOM", 0, 8)
    vDiv:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.12)

    -- ══════════════════════════════════════════════════════════
    -- HELPERS
    -- ══════════════════════════════════════════════════════════

    -- Section header with gradient line (standalone, returns label + line frames)
    local function MakeSectionHeader(parentFrame, text)
        local container = CreateFrame("Frame", nil, parentFrame)
        container:SetHeight(18)
        local lbl = container:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 10, "OUTLINE")
        lbl:SetPoint("LEFT", container, "LEFT", PAD, 0)
        lbl:SetText(text)
        lbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

        local line = container:CreateTexture(nil, "OVERLAY")
        line:SetHeight(1); line:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
        line:SetPoint("RIGHT", container, "RIGHT", -PAD, 0)
        line:SetTexture(W8)
        if line.SetGradient and CreateColor then
            line:SetGradient("HORIZONTAL",
                CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.25),
                CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.0))
        end
        return container, lbl
    end

    -- Bordered button with hover
    local function MakeBorderedBtn(parentFrame, w, h, color, text)
        local btn = CreateFrame("Button", nil, parentFrame)
        btn:SetSize(w, h)
        local bg = btn:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
        bg:SetColorTexture(color[1], color[2], color[3], 0.2)
        local fs = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(fs, BODY_FONT, 11, "OUTLINE"); fs:SetPoint("CENTER")
        fs:SetText(text); fs:SetTextColor(color[1], color[2], color[3])
        for _, edge in ipairs({
            { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false }
        }) do
            local b = btn:CreateTexture(nil, "OVERLAY")
            if edge[3] then b:SetHeight(1) else b:SetWidth(1) end
            b:SetPoint(edge[1]); b:SetPoint(edge[2])
            b:SetColorTexture(color[1], color[2], color[3], 0.25)
        end
        btn:SetScript("OnEnter", function() bg:SetColorTexture(color[1], color[2], color[3], 0.35) end)
        btn:SetScript("OnLeave", function() bg:SetColorTexture(color[1], color[2], color[3], 0.2) end)
        return btn, bg, fs
    end

    -- Frost line helper (adds glass depth to cards)
    local function AddFrostLine(card)
        local frost = card:CreateTexture(nil, "OVERLAY")
        frost:SetHeight(1); frost:SetPoint("TOPLEFT", 1, -1); frost:SetPoint("TOPRIGHT", -1, -1)
        frost:SetColorTexture(1, 1, 1, 0.08)
    end

    -- ══════════════════════════════════════════════════════════
    -- LEFT COLUMN — dynamic layout via leftSections array
    -- ══════════════════════════════════════════════════════════

    -- Left sections ordered array: { frame, getHeight, isVisible }
    local leftSections = {}

    local function RebuildLeftColumn()
        local y = -PAD
        for _, sec in ipairs(leftSections) do
            if sec.isVisible() then
                sec.frame:Show()
                sec.frame:ClearAllPoints()
                sec.frame:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 0, y)
                sec.frame:SetPoint("RIGHT", leftCol, "RIGHT", 0, 0)
                y = y - sec.getHeight() - 16
            else
                sec.frame:Hide()
            end
        end
        -- Update scroll child height so scrolling works when content exceeds viewport
        leftCol:SetHeight(math.abs(y) + PAD)
    end

    -- Progress visibility helpers
    local function IsProgressVisible()
        if not DB or not DB.config or not DB.config.guildType then return false end
        for _, gt in ipairs(DB.config.guildType) do
            if gt == "RAID" or gt == "MYTHICPLUS" or gt == "HARDCORE" then return true end
        end
        return false
    end

    local function GetActiveProgressTypes()
        local types = {}
        for _, gt in ipairs(DB.config.guildType or {}) do
            if gt == "RAID" then types.raid = true end
            if gt == "MYTHICPLUS" then types.mplus = true end
            if gt == "HARDCORE" then types.hardcore = true end
        end
        return types
    end

    -- UpdateProgressString helper
    local function UpdateProgressString()
        if not DB or not DB.config then return end
        local bosses = DB.config.raidProgBosses or 0
        local total = DB.config.raidProgTotal or 8
        local diff = DB.config.raidProgDiff or "H"
        local aotc = DB.config.raidProgAOTC
        local ce = DB.config.raidProgCE
        local parts = {}
        if bosses > 0 and total > 0 then
            local diffSuffix = diff == "N" and "N" or diff == "H" and "H" or diff == "M" and "M" or "H"
            parts[#parts + 1] = bosses .. "/" .. total .. diffSuffix
        end
        if ce then parts[#parts + 1] = "CE" end
        if aotc and not ce then parts[#parts + 1] = "AOTC" end
        DB.config.raidProgress = table.concat(parts, " ")
    end

    -- ── Section 1: Recruitment Status Pill (48px) ──
    local sec1 = CreateFrame("Frame", nil, leftCol)
    sec1:SetHeight(48)
    do
        local statusCard = CreateFrame("Frame", nil, sec1, "BackdropTemplate")
        statusCard:SetHeight(48)
        statusCard:SetPoint("TOPLEFT", sec1, "TOPLEFT", PAD, 0)
        statusCard:SetPoint("RIGHT", sec1, "RIGHT", -PAD, 0)
        statusCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        statusCard:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        statusCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(statusCard)

        local enableLbl = statusCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(enableLbl, BODY_FONT, 13, "")
        enableLbl:SetPoint("LEFT", statusCard, "LEFT", 14, 0)
        enableLbl:SetText("Recruitment Status")
        enableLbl:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

        local pillW, pillH = 56, 24
        local pillTrack = CreateFrame("Button", nil, statusCard)
        pillTrack:SetSize(pillW, pillH); pillTrack:SetPoint("RIGHT", statusCard, "RIGHT", -14, 0)
        local pillBg = pillTrack:CreateTexture(nil, "BACKGROUND"); pillBg:SetAllPoints()
        local pillKnob = pillTrack:CreateTexture(nil, "OVERLAY")
        pillKnob:SetSize(pillH - 4, pillH - 4)
        local pillStatusFS = statusCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(pillStatusFS, BODY_FONT, 10, "OUTLINE")
        pillStatusFS:SetPoint("RIGHT", pillTrack, "LEFT", -8, 0)
        configState.enableToggle = pillTrack
        configState._pillBg = pillBg
        configState._pillKnob = pillKnob
        configState._pillStatusFS = pillStatusFS
        configState._enableLbl = enableLbl

        pillTrack:SetScript("OnClick", function()
            if DB and DB.config then
                DB.config.enabled = not DB.config.enabled
                DB.config.version = (DB.config.version or 0) + 1
                DB.config.lastUpdated = time()
                DB.config.updatedBy = SafeCall(UnitName, "player") or ""
                Recruit.SaveConfigFromUI()
                if DB.config.enabled then
                    BroadcastConfig()
                    BroadcastListing()
                    PropagateOwnListing()  -- cross-realm via BNet friends
                else
                    BroadcastClear()
                end
                Recruit.RefreshBadge()
                Recruit.RefreshConfigOverlay()
            end
        end)
    end
    leftSections[#leftSections + 1] = {
        frame = sec1,
        getHeight = function() return 48 end,
        isVisible = function() return true end,
    }

    -- ── Section 2: Team Dropdown (36px) ──
    local sec2 = CreateFrame("Frame", nil, leftCol)
    sec2:SetHeight(36)
    do
        -- Build rank list at overlay open time
        local rankList = { "All Ranks" }
        local numRanks = SafeCall(GuildControlGetNumRanks) or 0
        for i = 1, numRanks do
            local rName = SafeCall(GuildControlGetRankName, i)
            if rName and rName ~= "" then
                rankList[#rankList + 1] = rName
            end
        end

        local teamCard = CreateFrame("Frame", nil, sec2, "BackdropTemplate")
        teamCard:SetHeight(36)
        teamCard:SetPoint("TOPLEFT", sec2, "TOPLEFT", PAD, 0)
        teamCard:SetPoint("RIGHT", sec2, "RIGHT", -PAD, 0)
        teamCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        teamCard:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        teamCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(teamCard)

        local teamLbl = teamCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(teamLbl, BODY_FONT, 10, "")
        teamLbl:SetPoint("LEFT", teamCard, "LEFT", 14, 0)
        teamLbl:SetText("Recruiting For:")
        teamLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local teamBtn = CreateFrame("Button", nil, teamCard, "BackdropTemplate")
        teamBtn:SetSize(160, 24)
        teamBtn:SetPoint("LEFT", teamLbl, "RIGHT", 8, 0)
        teamBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        teamBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        teamBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        local teamFS = teamBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(teamFS, BODY_FONT, 10, "OUTLINE"); teamFS:SetPoint("CENTER")
        teamFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

        configState.teamBtn = { btn = teamBtn, fs = teamFS }

        teamBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        teamBtn:SetScript("OnClick", function(_, mouseBtn)
            if not DB or not DB.config then return end
            local cur = DB.config.recruitTeam or "All Ranks"
            local idx = 1
            for i, rk in ipairs(rankList) do
                if rk == cur then idx = i; break end
            end
            if mouseBtn == "RightButton" then
                idx = idx - 1
                if idx < 1 then idx = #rankList end
            else
                idx = idx + 1
                if idx > #rankList then idx = 1 end
            end
            DB.config.recruitTeam = rankList[idx]
            teamFS:SetText(DB.config.recruitTeam)
        end)
        teamBtn:SetScript("OnEnter", function()
            teamBtn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)
        end)
        teamBtn:SetScript("OnLeave", function()
            teamBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        end)

        teamFS:SetText(DB.config.recruitTeam or "All Ranks")
    end
    leftSections[#leftSections + 1] = {
        frame = sec2,
        getHeight = function() return 36 end,
        isVisible = function() return true end,
    }

    -- ── Section 3: Guild Identity Card (42px) ──
    local sec3 = CreateFrame("Frame", nil, leftCol)
    sec3:SetHeight(42)
    do
        local identityCard = CreateFrame("Frame", nil, sec3, "BackdropTemplate")
        identityCard:SetHeight(42)
        identityCard:SetPoint("TOPLEFT", sec3, "TOPLEFT", PAD, 0)
        identityCard:SetPoint("RIGHT", sec3, "RIGHT", -PAD, 0)
        identityCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        identityCard:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        identityCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(identityCard)

        local factionFS = identityCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(factionFS, BODY_FONT, 11, "")
        factionFS:SetPoint("LEFT", identityCard, "LEFT", 12, 0)
        local fStr = DB.config.faction or ""
        local fColor = fStr == "Alliance" and "|cff3399ff" or fStr == "Horde" and "|cffff3333" or "|cffcccccc"
        factionFS:SetText(fColor .. fStr .. "|r")

        local realmFS = identityCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(realmFS, BODY_FONT, 11, "")
        realmFS:SetPoint("CENTER", identityCard, "CENTER", 0, 0)
        realmFS:SetText("|cffdddddd" .. (DB.config.realm or "") .. "|r")

        local regionFS = identityCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(regionFS, BODY_FONT, 10, "OUTLINE")
        regionFS:SetPoint("RIGHT", identityCard, "RIGHT", -12, 0)
        regionFS:SetText("|cffaaaaaa" .. (DB.config.region or "") .. "|r")
    end
    leftSections[#leftSections + 1] = {
        frame = sec3,
        getHeight = function() return 42 end,
        isVisible = function() return true end,
    }

    -- ── Section 4: Guild Focus Tags (28-62px) ──
    local sec4 = CreateFrame("Frame", nil, leftCol)
    local sec4Height = 28  -- will be calculated
    do
        local typeLbl = sec4:CreateFontString(nil, "OVERLAY")
        TrySetFont(typeLbl, BODY_FONT, 10, "")
        typeLbl:SetPoint("TOPLEFT", sec4, "TOPLEFT", PAD, 0)
        typeLbl:SetText("Guild Focus:")
        typeLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        configState.guildTypeBtns = {}
        local typeXOfs = PAD
        local typeY = -18
        local typeRowH = 26
        local typeGap = 4
        local typeBtnW = 76

        for _, gt in ipairs(GUILD_TYPES) do
            local typeBtn = CreateFrame("Button", nil, sec4, "BackdropTemplate")
            typeBtn:SetSize(typeBtnW, typeRowH)
            typeBtn:SetPoint("TOPLEFT", sec4, "TOPLEFT", typeXOfs, typeY)
            typeBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })

            local typeIcon = typeBtn:CreateTexture(nil, "ARTWORK")
            typeIcon:SetSize(14, 14); typeIcon:SetPoint("LEFT", typeBtn, "LEFT", 4, 0)
            typeIcon:SetTexture(gt.icon)
            typeIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            local typeFS = typeBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(typeFS, BODY_FONT, 9, "")
            typeFS:SetPoint("LEFT", typeIcon, "RIGHT", 3, 0)
            typeFS:SetText(gt.label)

            configState.guildTypeBtns[gt.key] = { btn = typeBtn, fs = typeFS, icon = typeIcon }

            local capturedKey = gt.key
            typeBtn:SetScript("OnClick", function()
                if not DB or not DB.config then return end
                if not DB.config.guildType then DB.config.guildType = {} end
                local found = false
                for i, v in ipairs(DB.config.guildType) do
                    if v == capturedKey then table.remove(DB.config.guildType, i); found = true; break end
                end
                if not found then DB.config.guildType[#DB.config.guildType + 1] = capturedKey end
                RebuildLeftColumn()
                Recruit.RefreshConfigOverlay()
            end)

            typeXOfs = typeXOfs + typeBtnW + typeGap + 2
            if typeXOfs + typeBtnW > LEFT_W - PAD then
                typeXOfs = PAD
                typeY = typeY - (typeRowH + typeGap)
            end
        end

        -- Calculate actual height: 18 for label + rows of buttons
        local numCols = math.floor((LEFT_W - 2 * PAD) / (typeBtnW + typeGap + 2))
        local numRows = math.ceil(#GUILD_TYPES / numCols)
        sec4Height = 18 + numRows * (typeRowH + typeGap)
        sec4:SetHeight(sec4Height)
    end
    leftSections[#leftSections + 1] = {
        frame = sec4,
        getHeight = function() return sec4Height end,
        isVisible = function() return true end,
    }

    -- ── Section 5: Progress Section (CONDITIONAL) ──
    local sec5 = CreateFrame("Frame", nil, leftCol)
    local sec5RaidFrame, sec5MplusFrame, sec5HardcoreFrame
    local sec5Header

    do
        sec5Header = MakeSectionHeader(sec5, "PROGRESS")
        sec5Header:SetPoint("TOPLEFT", sec5, "TOPLEFT", 0, 0)
        sec5Header:SetPoint("RIGHT", sec5, "RIGHT", 0, 0)

        -- Raid sub-frame (80px)
        sec5RaidFrame = CreateFrame("Frame", nil, sec5, "BackdropTemplate")
        sec5RaidFrame:SetHeight(80)
        sec5RaidFrame:SetPoint("TOPLEFT", sec5, "TOPLEFT", PAD, -22)
        sec5RaidFrame:SetPoint("RIGHT", sec5, "RIGHT", -PAD, 0)
        sec5RaidFrame:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        sec5RaidFrame:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        sec5RaidFrame:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(sec5RaidFrame)

        -- Row 1: "Killed:" [bossBtn] / [totalBtn] [diffBtn] preview
        local killLbl = sec5RaidFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(killLbl, BODY_FONT, 10, "")
        killLbl:SetPoint("TOPLEFT", sec5RaidFrame, "TOPLEFT", 14, -14)
        killLbl:SetText("Killed:")
        killLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local bossBtn = CreateFrame("Button", nil, sec5RaidFrame, "BackdropTemplate")
        bossBtn:SetSize(40, 26); bossBtn:SetPoint("LEFT", killLbl, "RIGHT", 8, 0)
        bossBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        bossBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        bossBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        local bossFS = bossBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(bossFS, BODY_FONT, 11, "OUTLINE"); bossFS:SetPoint("CENTER")
        bossFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

        bossBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        bossBtn:SetScript("OnClick", function(_, mouseBtn)
            if not DB or not DB.config then return end
            local total = DB.config.raidProgTotal or 8
            if mouseBtn == "RightButton" then
                DB.config.raidProgBosses = math.max(0, (DB.config.raidProgBosses or 0) - 1)
            else
                DB.config.raidProgBosses = math.min(total, (DB.config.raidProgBosses or 0) + 1)
            end
            UpdateProgressString()
            Recruit.RefreshConfigOverlay()
        end)
        bossBtn:SetScript("OnEnter", function(self)
            bossBtn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Bosses Killed", 1, 1, 1)
            GameTooltip:AddLine("Left-click: +1  |  Right-click: -1", C.mutedText[1], C.mutedText[2], C.mutedText[3])
            GameTooltip:Show()
        end)
        bossBtn:SetScript("OnLeave", function() bossBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15); GameTooltip:Hide() end)

        local slashFS = sec5RaidFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(slashFS, BODY_FONT, 14, "OUTLINE"); slashFS:SetPoint("LEFT", bossBtn, "RIGHT", 4, 0)
        slashFS:SetText("/"); slashFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.5)

        local totalBtn = CreateFrame("Button", nil, sec5RaidFrame, "BackdropTemplate")
        totalBtn:SetSize(40, 26); totalBtn:SetPoint("LEFT", slashFS, "RIGHT", 4, 0)
        totalBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        totalBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        totalBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        local totalFS = totalBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(totalFS, BODY_FONT, 11, "OUTLINE"); totalFS:SetPoint("CENTER")
        totalFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

        totalBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        totalBtn:SetScript("OnClick", function(_, mouseBtn)
            if not DB or not DB.config then return end
            if mouseBtn == "RightButton" then
                DB.config.raidProgTotal = math.max(1, (DB.config.raidProgTotal or 8) - 1)
            else
                DB.config.raidProgTotal = math.min(14, (DB.config.raidProgTotal or 8) + 1)
            end
            if (DB.config.raidProgBosses or 0) > DB.config.raidProgTotal then
                DB.config.raidProgBosses = DB.config.raidProgTotal
            end
            UpdateProgressString()
            Recruit.RefreshConfigOverlay()
        end)
        totalBtn:SetScript("OnEnter", function(self)
            totalBtn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Total Bosses in Tier", 1, 1, 1)
            GameTooltip:AddLine("Left-click: +1  |  Right-click: -1", C.mutedText[1], C.mutedText[2], C.mutedText[3])
            GameTooltip:Show()
        end)
        totalBtn:SetScript("OnLeave", function() totalBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15); GameTooltip:Hide() end)

        local diffBtn = CreateFrame("Button", nil, sec5RaidFrame, "BackdropTemplate")
        diffBtn:SetSize(76, 26); diffBtn:SetPoint("LEFT", totalBtn, "RIGHT", 16, 0)
        diffBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        diffBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        diffBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        local diffFS = diffBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(diffFS, BODY_FONT, 10, "OUTLINE"); diffFS:SetPoint("CENTER")

        diffBtn:SetScript("OnClick", function()
            if not DB or not DB.config then return end
            local cur = DB.config.raidProgDiff or "H"
            if cur == "N" then DB.config.raidProgDiff = "H"
            elseif cur == "H" then DB.config.raidProgDiff = "M"
            else DB.config.raidProgDiff = "N" end
            UpdateProgressString()
            Recruit.RefreshConfigOverlay()
        end)
        diffBtn:SetScript("OnEnter", function() diffBtn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3) end)
        diffBtn:SetScript("OnLeave", function() diffBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15) end)

        local progPreviewFS = sec5RaidFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(progPreviewFS, BODY_FONT, 11, "OUTLINE")
        progPreviewFS:SetPoint("RIGHT", sec5RaidFrame, "RIGHT", -14, 12)
        progPreviewFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3], 0.8)

        -- Row 2: AOTC + CE toggles
        local aotcBtn = CreateFrame("Button", nil, sec5RaidFrame, "BackdropTemplate")
        aotcBtn:SetSize(64, 26); aotcBtn:SetPoint("TOPLEFT", sec5RaidFrame, "TOPLEFT", 14, -50)
        aotcBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        local aotcBg = aotcBtn:CreateTexture(nil, "BACKGROUND"); aotcBg:SetAllPoints()
        local aotcFS = aotcBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(aotcFS, BODY_FONT, 9, "OUTLINE"); aotcFS:SetPoint("CENTER")
        aotcFS:SetText("AOTC")

        aotcBtn:SetScript("OnClick", function()
            if not DB or not DB.config then return end
            DB.config.raidProgAOTC = not DB.config.raidProgAOTC
            UpdateProgressString()
            Recruit.RefreshConfigOverlay()
        end)

        local ceBtn = CreateFrame("Button", nil, sec5RaidFrame, "BackdropTemplate")
        ceBtn:SetSize(52, 26); ceBtn:SetPoint("LEFT", aotcBtn, "RIGHT", 10, 0)
        ceBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        local ceBg = ceBtn:CreateTexture(nil, "BACKGROUND"); ceBg:SetAllPoints()
        local ceFS = ceBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(ceFS, BODY_FONT, 9, "OUTLINE"); ceFS:SetPoint("CENTER")
        ceFS:SetText("CE")

        ceBtn:SetScript("OnClick", function()
            if not DB or not DB.config then return end
            DB.config.raidProgCE = not DB.config.raidProgCE
            UpdateProgressString()
            Recruit.RefreshConfigOverlay()
        end)

        configState.progInput = nil
        configState.progBossBtn = { btn = bossBtn, fs = bossFS }
        configState.progTotalBtn = { btn = totalBtn, fs = totalFS }
        configState.progDiffBtn = { btn = diffBtn, fs = diffFS }
        configState.progPreviewFS = progPreviewFS
        configState.progAOTCBtn = { btn = aotcBtn, bg = aotcBg, fs = aotcFS }
        configState.progCEBtn = { btn = ceBtn, bg = ceBg, fs = ceFS }

        -- M+ sub-frame (40px)
        sec5MplusFrame = CreateFrame("Frame", nil, sec5, "BackdropTemplate")
        sec5MplusFrame:SetHeight(40)
        sec5MplusFrame:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        sec5MplusFrame:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        sec5MplusFrame:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(sec5MplusFrame)

        local mkLbl = sec5MplusFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(mkLbl, BODY_FONT, 10, "")
        mkLbl:SetPoint("LEFT", sec5MplusFrame, "LEFT", 14, 0)
        mkLbl:SetText("Target Key:")
        mkLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local mkBtn = CreateFrame("Button", nil, sec5MplusFrame, "BackdropTemplate")
        mkBtn:SetSize(40, 24); mkBtn:SetPoint("LEFT", mkLbl, "RIGHT", 8, 0)
        mkBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        mkBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        mkBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        local mkFS = mkBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(mkFS, BODY_FONT, 11, "OUTLINE"); mkFS:SetPoint("CENTER")
        mkFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

        mkBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        mkBtn:SetScript("OnClick", function(_, mouseBtn)
            if not DB or not DB.config then return end
            local cur = DB.config.mplusTargetKey or 15
            if mouseBtn == "RightButton" then
                DB.config.mplusTargetKey = math.max(2, cur - 1)
            else
                DB.config.mplusTargetKey = math.min(30, cur + 1)
            end
            mkFS:SetText(tostring(DB.config.mplusTargetKey))
        end)
        mkBtn:SetScript("OnEnter", function()
            mkBtn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)
        end)
        mkBtn:SetScript("OnLeave", function()
            mkBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        end)

        local scoreLbl = sec5MplusFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(scoreLbl, BODY_FONT, 10, "")
        scoreLbl:SetPoint("LEFT", mkBtn, "RIGHT", 20, 0)
        scoreLbl:SetText("Score:")
        scoreLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local scoreInput = CreateFrame("EditBox", nil, sec5MplusFrame, "BackdropTemplate")
        scoreInput:SetSize(60, 24)
        scoreInput:SetPoint("LEFT", scoreLbl, "RIGHT", 6, 0)
        scoreInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        scoreInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        scoreInput:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        scoreInput:SetAutoFocus(false)
        scoreInput:SetNumeric(true)
        scoreInput:SetMaxLetters(5)
        TrySetFont(scoreInput, BODY_FONT, 11, "")
        scoreInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        scoreInput:SetTextInsets(8, 8, 4, 4)
        scoreInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        scoreInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

        configState.mplusKeyBtn = { btn = mkBtn, fs = mkFS }
        configState.mplusScoreInput = scoreInput

        -- Hardcore sub-frame (40px)
        sec5HardcoreFrame = CreateFrame("Frame", nil, sec5, "BackdropTemplate")
        sec5HardcoreFrame:SetHeight(40)
        sec5HardcoreFrame:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        sec5HardcoreFrame:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        sec5HardcoreFrame:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(sec5HardcoreFrame)

        local hcLvlLbl = sec5HardcoreFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(hcLvlLbl, BODY_FONT, 10, "")
        hcLvlLbl:SetPoint("LEFT", sec5HardcoreFrame, "LEFT", 14, 0)
        hcLvlLbl:SetText("Highest Level:")
        hcLvlLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local hcLvlInput = CreateFrame("EditBox", nil, sec5HardcoreFrame, "BackdropTemplate")
        hcLvlInput:SetSize(50, 24)
        hcLvlInput:SetPoint("LEFT", hcLvlLbl, "RIGHT", 6, 0)
        hcLvlInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        hcLvlInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        hcLvlInput:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        hcLvlInput:SetAutoFocus(false)
        hcLvlInput:SetNumeric(true)
        hcLvlInput:SetMaxLetters(3)
        TrySetFont(hcLvlInput, BODY_FONT, 11, "")
        hcLvlInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        hcLvlInput:SetTextInsets(8, 8, 4, 4)
        hcLvlInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        hcLvlInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

        local hcDeathLbl = sec5HardcoreFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(hcDeathLbl, BODY_FONT, 10, "")
        hcDeathLbl:SetPoint("LEFT", hcLvlInput, "RIGHT", 20, 0)
        hcDeathLbl:SetText("Deaths:")
        hcDeathLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local hcDeathInput = CreateFrame("EditBox", nil, sec5HardcoreFrame, "BackdropTemplate")
        hcDeathInput:SetSize(50, 24)
        hcDeathInput:SetPoint("LEFT", hcDeathLbl, "RIGHT", 6, 0)
        hcDeathInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        hcDeathInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        hcDeathInput:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        hcDeathInput:SetAutoFocus(false)
        hcDeathInput:SetNumeric(true)
        hcDeathInput:SetMaxLetters(5)
        TrySetFont(hcDeathInput, BODY_FONT, 11, "")
        hcDeathInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        hcDeathInput:SetTextInsets(8, 8, 4, 4)
        hcDeathInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        hcDeathInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

        configState.hardcoreLevelInput = hcLvlInput
        configState.hardcoreDeathsInput = hcDeathInput
    end

    -- Function to rebuild progress sub-frame visibility and height
    local function RebuildProgressSection()
        local types = GetActiveProgressTypes()
        local subY = -22  -- below header

        if types.raid then
            sec5RaidFrame:ClearAllPoints()
            sec5RaidFrame:SetPoint("TOPLEFT", sec5, "TOPLEFT", PAD, subY)
            sec5RaidFrame:SetPoint("RIGHT", sec5, "RIGHT", -PAD, 0)
            sec5RaidFrame:Show()
            subY = subY - 80 - 6
        else
            sec5RaidFrame:Hide()
        end

        if types.mplus then
            sec5MplusFrame:ClearAllPoints()
            sec5MplusFrame:SetPoint("TOPLEFT", sec5, "TOPLEFT", PAD, subY)
            sec5MplusFrame:SetPoint("RIGHT", sec5, "RIGHT", -PAD, 0)
            sec5MplusFrame:Show()
            subY = subY - 40 - 6
        else
            sec5MplusFrame:Hide()
        end

        if types.hardcore then
            sec5HardcoreFrame:ClearAllPoints()
            sec5HardcoreFrame:SetPoint("TOPLEFT", sec5, "TOPLEFT", PAD, subY)
            sec5HardcoreFrame:SetPoint("RIGHT", sec5, "RIGHT", -PAD, 0)
            sec5HardcoreFrame:Show()
            subY = subY - 40 - 6
        else
            sec5HardcoreFrame:Hide()
        end

        local totalH = math.abs(subY) + 6
        sec5:SetHeight(totalH)
    end

    -- Store for external access
    Recruit.RebuildProgressSection = function()
        RebuildProgressSection()
        RebuildLeftColumn()
    end

    leftSections[#leftSections + 1] = {
        frame = sec5,
        getHeight = function()
            local types = GetActiveProgressTypes()
            local h = 22  -- header
            if types.raid then h = h + 86 end
            if types.mplus then h = h + 46 end
            if types.hardcore then h = h + 46 end
            return h
        end,
        isVisible = IsProgressVisible,
    }

    -- ── Section 6: Schedule (92px) ──
    local sec6 = CreateFrame("Frame", nil, leftCol)
    sec6:SetHeight(92)
    do
        local schedHeader = MakeSectionHeader(sec6, "SCHEDULE")
        schedHeader:SetPoint("TOPLEFT", sec6, "TOPLEFT", 0, 0)
        schedHeader:SetPoint("RIGHT", sec6, "RIGHT", 0, 0)

        local daysLbl = sec6:CreateFontString(nil, "OVERLAY")
        TrySetFont(daysLbl, BODY_FONT, 10, "")
        daysLbl:SetPoint("TOPLEFT", sec6, "TOPLEFT", PAD, -22)
        daysLbl:SetText("Active Days:")
        daysLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local dayCount = #RAID_DAYS
        local dayGap = 4
        local dayAvailW = LEFT_W - (2 * PAD)
        local dayBtnW = math.floor((dayAvailW - (dayCount - 1) * dayGap) / dayCount)

        configState.dayBtns = {}
        local dayXOfs = PAD
        for _, day in ipairs(RAID_DAYS) do
            local dayBtn = CreateFrame("Button", nil, sec6, "BackdropTemplate")
            dayBtn:SetSize(dayBtnW, 28)
            dayBtn:SetPoint("TOPLEFT", sec6, "TOPLEFT", dayXOfs, -36)
            dayBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })

            local dayFS = dayBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(dayFS, BODY_FONT, 10, "OUTLINE"); dayFS:SetPoint("CENTER")
            dayFS:SetText(day.label)

            configState.dayBtns[day.key] = { btn = dayBtn, fs = dayFS }

            local capturedKey = day.key
            dayBtn:SetScript("OnClick", function()
                if not DB or not DB.config then return end
                if not DB.config.raidDays then DB.config.raidDays = {} end
                local found = false
                for i, v in ipairs(DB.config.raidDays) do
                    if v == capturedKey then table.remove(DB.config.raidDays, i); found = true; break end
                end
                if not found then DB.config.raidDays[#DB.config.raidDays + 1] = capturedKey end
                Recruit.RefreshConfigOverlay()
            end)

            dayXOfs = dayXOfs + dayBtnW + dayGap
        end

        -- Time card (40px)
        local timeCard = CreateFrame("Frame", nil, sec6, "BackdropTemplate")
        timeCard:SetHeight(40)
        timeCard:SetPoint("TOPLEFT", sec6, "TOPLEFT", PAD, -70)
        timeCard:SetPoint("RIGHT", sec6, "RIGHT", -PAD, 0)
        timeCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        timeCard:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        timeCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(timeCard)

        local function MakeTimeCycleBtn(parentCard, label, xOfs, configKey)
            local lbl = parentCard:CreateFontString(nil, "OVERLAY")
            TrySetFont(lbl, BODY_FONT, 10, "")
            lbl:SetPoint("LEFT", parentCard, "LEFT", xOfs, 0)
            lbl:SetText(label)
            lbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

            local btn = CreateFrame("Button", nil, parentCard, "BackdropTemplate")
            btn:SetSize(86, 24)
            btn:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
            btn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            btn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
            btn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)

            local fs = btn:CreateFontString(nil, "OVERLAY")
            TrySetFont(fs, BODY_FONT, 10, ""); fs:SetPoint("CENTER")
            fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

            btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            btn:SetScript("OnClick", function(self, mouseBtn)
                if not DB or not DB.config then return end
                local cur = DB.config[configKey] or ""
                local idx = 0
                for i, slot in ipairs(TIME_SLOTS) do
                    if slot == cur then idx = i; break end
                end
                if mouseBtn == "RightButton" then
                    idx = idx - 1
                    if idx < 1 then idx = #TIME_SLOTS end
                else
                    idx = idx + 1
                    if idx > #TIME_SLOTS then idx = 1 end
                end
                DB.config[configKey] = TIME_SLOTS[idx]
                local startT = DB.config.raidStartTime or ""
                local endT = DB.config.raidEndTime or ""
                if startT ~= "" and endT ~= "" then
                    DB.config.raidTime = startT .. " - " .. endT
                elseif startT ~= "" then
                    DB.config.raidTime = startT
                else
                    DB.config.raidTime = ""
                end
                Recruit.RefreshConfigOverlay()
            end)

            btn:SetScript("OnEnter", function(self)
                btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText("Left-click: next time", 1, 1, 1)
                GameTooltip:AddLine("Right-click: previous time", C.mutedText[1], C.mutedText[2], C.mutedText[3])
                GameTooltip:Show()
            end)
            btn:SetScript("OnLeave", function()
                btn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
                GameTooltip:Hide()
            end)

            return { btn = btn, fs = fs, lbl = lbl }
        end

        configState.startTimeBtn = MakeTimeCycleBtn(timeCard, "Start:", 12, "raidStartTime")
        configState.endTimeBtn = MakeTimeCycleBtn(timeCard, "End:", 174, "raidEndTime")

        local tzLbl = timeCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(tzLbl, BODY_FONT, 10, "")
        tzLbl:SetPoint("LEFT", timeCard, "LEFT", 330, 0)
        tzLbl:SetText("TZ:")
        tzLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local tzBtn = CreateFrame("Button", nil, timeCard, "BackdropTemplate")
        tzBtn:SetSize(56, 24)
        tzBtn:SetPoint("LEFT", tzLbl, "RIGHT", 6, 0)
        tzBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        tzBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        tzBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        local tzFS = tzBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(tzFS, BODY_FONT, 10, "OUTLINE"); tzFS:SetPoint("CENTER")
        tzFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
        configState.tzBtn = { btn = tzBtn, fs = tzFS }

        tzBtn:SetScript("OnClick", function()
            if not DB or not DB.config then return end
            local cur = DB.config.timezone or ""
            local idx = 1
            for i, tz in ipairs(TIMEZONES) do
                if tz == cur then idx = i + 1; break end
            end
            if idx > #TIMEZONES then idx = 1 end
            DB.config.timezone = TIMEZONES[idx]
            Recruit.RefreshConfigOverlay()
        end)
        tzBtn:SetScript("OnEnter", function() tzBtn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3) end)
        tzBtn:SetScript("OnLeave", function() tzBtn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15) end)

        configState.timeInput = nil
    end
    leftSections[#leftSections + 1] = {
        frame = sec6,
        getHeight = function() return 112 end,  -- header + days + gap + time card
        isVisible = function() return true end,
    }

    -- ── Section 7: Guild Pitch (126px) ──
    local sec7 = CreateFrame("Frame", nil, leftCol)
    sec7:SetHeight(126)
    do
        local pitchHeader = MakeSectionHeader(sec7, "GUILD PITCH")
        pitchHeader:SetPoint("TOPLEFT", sec7, "TOPLEFT", 0, 0)
        pitchHeader:SetPoint("RIGHT", sec7, "RIGHT", 0, 0)

        local descBox = CreateFrame("EditBox", nil, sec7, "BackdropTemplate")
        descBox:SetHeight(110)
        descBox:SetPoint("TOPLEFT", sec7, "TOPLEFT", PAD, -20)
        descBox:SetPoint("RIGHT", sec7, "RIGHT", -PAD, 0)
        descBox:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        descBox:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        descBox:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.2)
        descBox:SetMultiLine(true)
        descBox:SetMaxLetters(300)
        descBox:SetAutoFocus(false)
        TrySetFont(descBox, BODY_FONT, 11, "")
        descBox:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        descBox:SetTextInsets(8, 8, 4, 4)
        descBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        configState.descInput = descBox
    end
    leftSections[#leftSections + 1] = {
        frame = sec7,
        getHeight = function() return 126 end,  -- header + desc box (tight)
        isVisible = function() return true end,
    }

    -- ── Section 8: Race Preferences (left column, below Guild Pitch) ──
    local sec8 = CreateFrame("Frame", nil, leftCol)
    sec8:SetClipsChildren(true)
    configState.racesExpanded = false
    do
        -- Header bar (clickable to expand/collapse)
        local raceHeaderBtn = CreateFrame("Button", nil, sec8)
        raceHeaderBtn:SetHeight(22)
        raceHeaderBtn:SetPoint("TOPLEFT", sec8, "TOPLEFT", 0, 0)
        raceHeaderBtn:SetPoint("RIGHT", sec8, "RIGHT", 0, 0)

        local raceHeaderLbl = raceHeaderBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(raceHeaderLbl, BODY_FONT, 10, "OUTLINE")
        raceHeaderLbl:SetPoint("LEFT", raceHeaderBtn, "LEFT", PAD, 0)
        raceHeaderLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

        local raceHeaderLine = raceHeaderBtn:CreateTexture(nil, "OVERLAY")
        raceHeaderLine:SetHeight(1); raceHeaderLine:SetPoint("LEFT", raceHeaderLbl, "RIGHT", 8, 0)
        raceHeaderLine:SetPoint("RIGHT", raceHeaderBtn, "RIGHT", -PAD, 0)
        raceHeaderLine:SetTexture(W8)
        if raceHeaderLine.SetGradient and CreateColor then
            raceHeaderLine:SetGradient("HORIZONTAL",
                CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.25),
                CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.0))
        end

        -- Race content (expandable area) — TWO COLUMN layout
        local raceContent = CreateFrame("Frame", nil, sec8)
        raceContent:SetPoint("TOPLEFT", sec8, "TOPLEFT", 0, -26)
        raceContent:SetPoint("RIGHT", sec8, "RIGHT", 0, 0)
        raceContent:Hide()
        configState._raceContent = raceContent

        configState.raceBtns = {}

        -- Split categories: left = Alliance-related, right = Horde-related
        local leftCats = {}   -- Alliance, Allied (Alliance)
        local rightCats = {}  -- Horde, Allied (Horde)
        local bottomCats = {} -- Allied (Neutral), Neutral
        for _, cat in ipairs(RACE_CATEGORIES) do
            local h = cat.header
            if h == "ALLIANCE" or h == "ALLIED (ALLIANCE)" then
                leftCats[#leftCats + 1] = cat
            elseif h == "HORDE" or h == "ALLIED (HORDE)" then
                rightCats[#rightCats + 1] = cat
            else
                bottomCats[#bottomCats + 1] = cat
            end
        end

        local RACE_BTN_H = 20
        local RACE_BTN_GAP = 3
        local RACE_FONT_SIZE = 8
        local halfW = math.floor((LEFT_W - PAD * 2 - 10) / 2) -- half column width with gap

        local function BuildRaceColumn(cats, startX, startY)
            local y = startY
            for _, cat in ipairs(cats) do
                local catLbl = raceContent:CreateFontString(nil, "OVERLAY")
                TrySetFont(catLbl, BODY_FONT, RACE_FONT_SIZE, "OUTLINE")
                catLbl:SetPoint("TOPLEFT", raceContent, "TOPLEFT", startX, y)
                catLbl:SetText(cat.header)
                catLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.6)
                y = y - 12

                local xOfs = startX
                for _, race in ipairs(cat.races) do
                    local raceBtn = CreateFrame("Button", nil, raceContent, "BackdropTemplate")
                    local btnW = math.max(56, race.name:len() * 6 + 14)
                    raceBtn:SetSize(btnW, RACE_BTN_H)
                    raceBtn:SetPoint("TOPLEFT", raceContent, "TOPLEFT", xOfs, y)
                    raceBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
                        insets = { left = 1, right = 1, top = 1, bottom = 1 } })

                    local raceFS = raceBtn:CreateFontString(nil, "OVERLAY")
                    TrySetFont(raceFS, BODY_FONT, RACE_FONT_SIZE, ""); raceFS:SetPoint("CENTER")
                    raceFS:SetText(race.name)

                    configState.raceBtns[race.key] = { btn = raceBtn, fs = raceFS }

                    local capturedKey = race.key
                    raceBtn:SetScript("OnClick", function()
                        if not DB or not DB.config then return end
                        if not DB.config.preferredRaces then DB.config.preferredRaces = {} end
                        local found = false
                        for i, v in ipairs(DB.config.preferredRaces) do
                            if v == capturedKey then table.remove(DB.config.preferredRaces, i); found = true; break end
                        end
                        if not found then DB.config.preferredRaces[#DB.config.preferredRaces + 1] = capturedKey end
                        Recruit.RefreshConfigOverlay()
                    end)

                    xOfs = xOfs + btnW + RACE_BTN_GAP
                    if xOfs + btnW > startX + halfW then
                        xOfs = startX
                        y = y - (RACE_BTN_H + RACE_BTN_GAP)
                    end
                end
                y = y - (RACE_BTN_H + 8) -- gap between categories
            end
            return y
        end

        local leftBottom = BuildRaceColumn(leftCats, PAD, 0)
        local rightBottom = BuildRaceColumn(rightCats, PAD + halfW + 10, 0)
        local twoColBottom = math.min(leftBottom, rightBottom)

        -- Bottom row: Neutral races span full width
        local bottomY = twoColBottom - 4
        for _, cat in ipairs(bottomCats) do
            local catLbl = raceContent:CreateFontString(nil, "OVERLAY")
            TrySetFont(catLbl, BODY_FONT, RACE_FONT_SIZE, "OUTLINE")
            catLbl:SetPoint("TOPLEFT", raceContent, "TOPLEFT", PAD, bottomY)
            catLbl:SetText(cat.header)
            catLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.6)
            bottomY = bottomY - 12

            local xOfs = PAD
            for _, race in ipairs(cat.races) do
                local raceBtn = CreateFrame("Button", nil, raceContent, "BackdropTemplate")
                local btnW = math.max(56, race.name:len() * 6 + 14)
                raceBtn:SetSize(btnW, RACE_BTN_H)
                raceBtn:SetPoint("TOPLEFT", raceContent, "TOPLEFT", xOfs, bottomY)
                raceBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
                    insets = { left = 1, right = 1, top = 1, bottom = 1 } })

                local raceFS = raceBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(raceFS, BODY_FONT, RACE_FONT_SIZE, ""); raceFS:SetPoint("CENTER")
                raceFS:SetText(race.name)

                configState.raceBtns[race.key] = { btn = raceBtn, fs = raceFS }

                local capturedKey = race.key
                raceBtn:SetScript("OnClick", function()
                    if not DB or not DB.config then return end
                    if not DB.config.preferredRaces then DB.config.preferredRaces = {} end
                    local found = false
                    for i, v in ipairs(DB.config.preferredRaces) do
                        if v == capturedKey then table.remove(DB.config.preferredRaces, i); found = true; break end
                    end
                    if not found then DB.config.preferredRaces[#DB.config.preferredRaces + 1] = capturedKey end
                    Recruit.RefreshConfigOverlay()
                end)

                xOfs = xOfs + btnW + RACE_BTN_GAP
            end
            bottomY = bottomY - (RACE_BTN_H + 8)
        end

        local raceContentH = math.abs(bottomY)
        raceContent:SetHeight(raceContentH)

        local function UpdateRaceHeader()
            if configState.racesExpanded then
                raceHeaderLbl:SetText("RACE PREFERENCES (OPTIONAL) [-]")
                raceContent:Show()
                sec8:SetHeight(26 + raceContentH)
            else
                raceHeaderLbl:SetText("RACE PREFERENCES (OPTIONAL) [+]")
                raceContent:Hide()
                sec8:SetHeight(22)
            end
        end

        raceHeaderBtn:SetScript("OnClick", function()
            configState.racesExpanded = not configState.racesExpanded
            UpdateRaceHeader()
            RebuildLeftColumn()
        end)
        raceHeaderBtn:SetScript("OnEnter", function()
            raceHeaderLbl:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
        end)
        raceHeaderBtn:SetScript("OnLeave", function()
            raceHeaderLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
        end)

        UpdateRaceHeader()
        sec8._raceContentH = raceContentH
    end
    leftSections[#leftSections + 1] = {
        frame = sec8,
        getHeight = function()
            if configState.racesExpanded then
                return 26 + (sec8._raceContentH or 0)
            else
                return 22
            end
        end,
        isVisible = function() return true end,
    }

    -- ══════════════════════════════════════════════════════════
    -- RIGHT COLUMN
    -- ══════════════════════════════════════════════════════════
    local rY = -PAD

    -- ── 1. ROLE OPENINGS section ──
    do
        local roleHeader = MakeSectionHeader(rightCol, "ROLE OPENINGS")
        roleHeader:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, rY)
        roleHeader:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0)
    end
    rY = rY - 30

    local SPEC_BTN_SIZE = 26
    local SPEC_BTN_GAP = 3

    for _, roleDef in ipairs(ROLE_DEFS) do
        local roleKey = roleDef.key
        local rc = roleDef.color

        local roleSpecs = ROLE_SPECS[roleKey] or {}
        -- Dynamic columns: fit as many as the card allows (max 10), min of spec count
        local maxCols = math.floor((RIGHT_W - 2 * PAD - 24) / (SPEC_BTN_SIZE + SPEC_BTN_GAP))
        local SPEC_PER_ROW = math.min(maxCols, math.max(#roleSpecs, 1))
        local specRows = math.ceil(#roleSpecs / SPEC_PER_ROW)
        local actualCardH = 56 + specRows * (SPEC_BTN_SIZE + SPEC_BTN_GAP)

        local card = CreateFrame("Frame", nil, rightCol, "BackdropTemplate")
        card:SetHeight(actualCardH)
        card:SetPoint("TOPLEFT", rightCol, "TOPLEFT", PAD, rY)
        card:SetPoint("RIGHT", rightCol, "RIGHT", -PAD, 0)
        card:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        card:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        card:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(card)

        local leftBar = card:CreateTexture(nil, "OVERLAY")
        leftBar:SetWidth(3); leftBar:SetPoint("TOPLEFT", 1, -1); leftBar:SetPoint("BOTTOMLEFT", 1, 1)
        leftBar:SetColorTexture(rc[1], rc[2], rc[3], 0.5)

        local roleIcon = card:CreateTexture(nil, "ARTWORK")
        roleIcon:SetSize(24, 24); roleIcon:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -8)
        roleIcon:SetTexture(roleDef.icon)
        roleIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local roleLbl = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(roleLbl, BODY_FONT, 13, "OUTLINE")
        roleLbl:SetPoint("LEFT", roleIcon, "RIGHT", 6, 0)
        roleLbl:SetText(roleDef.label)
        roleLbl:SetTextColor(rc[1], rc[2], rc[3])

        local statusBtn = CreateFrame("Button", nil, card)
        statusBtn:SetSize(110, 26); statusBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -6)
        local statusBg = statusBtn:CreateTexture(nil, "BACKGROUND"); statusBg:SetAllPoints()
        local statusFS = statusBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(statusFS, BODY_FONT, 10, "OUTLINE"); statusFS:SetPoint("CENTER")
        for _, edge in ipairs({
            { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false }
        }) do
            local b = statusBtn:CreateTexture(nil, "OVERLAY")
            if edge[3] then b:SetHeight(1) else b:SetWidth(1) end
            b:SetPoint(edge[1]); b:SetPoint(edge[2])
            b:SetColorTexture(rc[1], rc[2], rc[3], 0.2)
        end

        configState.roleToggles[roleKey] = { btn = statusBtn, bg = statusBg, fs = statusFS, card = card, leftBar = leftBar }
        configState.prioButtons[roleKey] = { btn = statusBtn, bg = statusBg, fs = statusFS }

        statusBtn:SetScript("OnClick", function()
            if not DB or not DB.config then return end
            local r = DB.config.roles[roleKey]
            if not r.open then
                r.open = true; r.priority = "LOW"
            elseif r.priority == "LOW" then
                r.priority = "HIGH"
            else
                r.open = false; r.priority = "NONE"
            end
            Recruit.RefreshConfigOverlay()
        end)
        statusBtn:SetScript("OnEnter", function() statusBg:SetColorTexture(rc[1], rc[2], rc[3], 0.25) end)
        statusBtn:SetScript("OnLeave", function() Recruit.RefreshConfigOverlay() end)

        local sepLine = card:CreateTexture(nil, "OVERLAY")
        sepLine:SetHeight(1); sepLine:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -36)
        sepLine:SetPoint("RIGHT", card, "RIGHT", -10, 0)
        sepLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.12)

        local specLbl = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(specLbl, BODY_FONT, 9, "")
        specLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -41)
        specLbl:SetText("Preferred Specs:")
        specLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7)

        configState.classButtons[roleKey] = {}
        local gridStartX = 12
        local gridStartY = -54
        for si, spec in ipairs(roleSpecs) do
            local col = (si - 1) % SPEC_PER_ROW
            local row = math.floor((si - 1) / SPEC_PER_ROW)
            local bx = gridStartX + col * (SPEC_BTN_SIZE + SPEC_BTN_GAP)
            local by = gridStartY - row * (SPEC_BTN_SIZE + SPEC_BTN_GAP)

            local specBtn = CreateFrame("Button", nil, card)
            specBtn:SetSize(SPEC_BTN_SIZE, SPEC_BTN_SIZE)
            specBtn:SetPoint("TOPLEFT", card, "TOPLEFT", bx, by)

            local specBg = specBtn:CreateTexture(nil, "BACKGROUND")
            specBg:SetPoint("TOPLEFT", -2, 2); specBg:SetPoint("BOTTOMRIGHT", 2, -2)
            specBg:SetColorTexture(0, 0, 0, 0)

            local specTex = specBtn:CreateTexture(nil, "ARTWORK")
            specTex:SetAllPoints()
            specTex:SetTexture(spec.icon)
            specTex:SetTexCoord(0.07, 0.93, 0.07, 0.93)

            local specBorder = specBtn:CreateTexture(nil, "OVERLAY")
            specBorder:SetPoint("TOPLEFT", -1, 1); specBorder:SetPoint("BOTTOMRIGHT", 1, -1)
            specBorder:SetColorTexture(0, 0, 0, 0)

            configState.classButtons[roleKey][si] = {
                btn = specBtn, tex = specTex, border = specBorder, bg = specBg,
                classFile = spec.class, specId = spec.id,
            }

            local capturedSpec = spec.id
            local capturedClass = spec.class
            specBtn:SetScript("OnClick", function()
                if not DB or not DB.config then return end
                local specs = DB.config.roles[roleKey].specs
                if not specs then DB.config.roles[roleKey].specs = {}; specs = DB.config.roles[roleKey].specs end
                local found = false
                for idx, s in ipairs(specs) do
                    if s == capturedSpec then
                        table.remove(specs, idx)
                        found = true
                        break
                    end
                end
                if not found then
                    specs[#specs + 1] = capturedSpec
                end
                local classSet = {}
                for _, s in ipairs(specs) do
                    for _, rs in ipairs(roleSpecs) do
                        if rs.id == s then classSet[rs.class] = true; break end
                    end
                end
                DB.config.roles[roleKey].classes = {}
                for cls in pairs(classSet) do
                    DB.config.roles[roleKey].classes[#DB.config.roles[roleKey].classes + 1] = cls
                end
                Recruit.RefreshConfigOverlay()
            end)

            specBtn:SetScript("OnEnter", function(self)
                specTex:SetAlpha(1.0)
                specTex:SetDesaturated(false)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                local cr, cg, cb = GetClassColor(capturedClass)
                GameTooltip:SetText(spec.name, cr, cg, cb)
                GameTooltip:AddLine(CLASS_LOOKUP[capturedClass] and CLASS_LOOKUP[capturedClass].name or "", 0.7, 0.7, 0.7)
                GameTooltip:Show()
            end)
            specBtn:SetScript("OnLeave", function()
                Recruit.RefreshConfigOverlay()
                GameTooltip:Hide()
            end)
        end

        rY = rY - (actualCardH + 10)
    end

    rY = rY - 6

    -- ── 2. APPLICATION QUESTIONS section ──
    do
        local qHeader = MakeSectionHeader(rightCol, "APPLICATION QUESTIONS")
        qHeader:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, rY)
        qHeader:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0)
    end
    rY = rY - 28

    local qPlaceholders = {
        "e.g. What is your raid availability?",
        "e.g. Do you have prior mythic experience?",
        "e.g. Why are you interested in our guild?",
        "e.g. What addons do you use?",
        "e.g. Anything else we should know?",
    }

    for qi = 1, 5 do
        local qRow = CreateFrame("Frame", nil, rightCol, "BackdropTemplate")
        qRow:SetHeight(32)
        qRow:SetPoint("TOPLEFT", rightCol, "TOPLEFT", PAD, rY)
        qRow:SetPoint("RIGHT", rightCol, "RIGHT", -PAD, 0)
        qRow:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        qRow:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        qRow:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)

        local qToggle = CreateFrame("Button", nil, qRow)
        qToggle:SetSize(20, 20); qToggle:SetPoint("LEFT", qRow, "LEFT", 8, 0)
        local qToggleBg = qToggle:CreateTexture(nil, "BACKGROUND"); qToggleBg:SetAllPoints()
        local qToggleFS = qToggle:CreateFontString(nil, "OVERLAY")
        TrySetFont(qToggleFS, BODY_FONT, 11, "OUTLINE"); qToggleFS:SetPoint("CENTER")
        configState.questionToggles[qi] = { btn = qToggle, bg = qToggleBg, fs = qToggleFS }

        local capturedQi = qi
        qToggle:SetScript("OnClick", function()
            if not DB or not DB.config then return end
            DB.config.questionsEnabled[capturedQi] = not DB.config.questionsEnabled[capturedQi]
            Recruit.RefreshConfigOverlay()
        end)

        local qInput = CreateFrame("EditBox", nil, qRow, "BackdropTemplate")
        qInput:SetHeight(24)
        qInput:SetPoint("LEFT", qToggle, "RIGHT", 8, 0)
        qInput:SetPoint("RIGHT", qRow, "RIGHT", -8, 0)
        qInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        qInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
        qInput:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        qInput:SetAutoFocus(false)
        qInput:SetMaxLetters(200)
        TrySetFont(qInput, BODY_FONT, 9, "")
        qInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        qInput:SetTextInsets(8, 8, 4, 4)
        qInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        qInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

        local phFS = qInput:CreateFontString(nil, "OVERLAY")
        TrySetFont(phFS, BODY_FONT, 9, "")
        phFS:SetPoint("LEFT", 8, 0)
        phFS:SetText(qPlaceholders[qi] or "")
        phFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.35)
        qInput:SetScript("OnTextChanged", function(self)
            local t = self:GetText()
            if t and t ~= "" then phFS:Hide() else phFS:Show() end
        end)
        qInput:SetScript("OnEditFocusGained", function() phFS:Hide() end)
        qInput:SetScript("OnEditFocusLost", function(self)
            local t = self:GetText()
            if not t or t == "" then phFS:Show() end
        end)

        configState.questionInputs[qi] = qInput
        rY = rY - 38  -- 32 row + 6 gap
    end

    rY = rY - 16

    -- ── 3. REQUIREMENTS section ──
    do
        local reqHeader = MakeSectionHeader(rightCol, "REQUIREMENTS")
        reqHeader:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, rY)
        reqHeader:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0)
    end
    rY = rY - 28

    local reqCard = CreateFrame("Frame", nil, rightCol, "BackdropTemplate")
    reqCard:SetHeight(44)
    reqCard:SetPoint("TOPLEFT", rightCol, "TOPLEFT", PAD, rY)
    reqCard:SetPoint("RIGHT", rightCol, "RIGHT", -PAD, 0)
    reqCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    reqCard:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
    reqCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
    AddFrostLine(reqCard)

    local function MakeReqInput(parentCard, label, xOffset)
        local lbl = parentCard:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 10, "")
        lbl:SetPoint("LEFT", parentCard, "LEFT", xOffset, 0)
        lbl:SetText(label)
        lbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local input = CreateFrame("EditBox", nil, parentCard, "BackdropTemplate")
        input:SetSize(56, 24)
        input:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        input:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        input:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.8)
        input:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.2)
        input:SetAutoFocus(false)
        input:SetNumeric(true)
        input:SetMaxLetters(5)
        TrySetFont(input, BODY_FONT, 11, "")
        input:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        input:SetTextInsets(8, 8, 4, 4)
        input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        input:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        return input
    end

    -- All three fields on a single horizontal row, evenly spaced
    local reqThird = math.floor((RIGHT_W - 2 * PAD) / 3)
    configState.minLvlInput = MakeReqInput(reqCard, "Level:", 14)
    configState.minIlvlInput = MakeReqInput(reqCard, "ilvl:", 14 + reqThird)
    configState.minMplusInput = MakeReqInput(reqCard, "M+:", 14 + reqThird * 2)

    -- ══════════════════════════════════════════════════════════
    -- BOTTOM ACTION BAR (54px)
    -- ══════════════════════════════════════════════════════════
    local actionBar = CreateFrame("Frame", nil, configOverlay, "BackdropTemplate")
    actionBar:SetHeight(54); actionBar:SetPoint("BOTTOMLEFT", 0, 0); actionBar:SetPoint("BOTTOMRIGHT", 0, 0)
    actionBar:SetBackdrop({ bgFile = W8 })
    actionBar:SetBackdropColor(0.015, 0.018, 0.032, 0.95)

    local actionLine = actionBar:CreateTexture(nil, "OVERLAY")
    actionLine:SetHeight(1); actionLine:SetPoint("TOPLEFT"); actionLine:SetPoint("TOPRIGHT")
    actionLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.2)

    -- Save & Broadcast button
    local saveBtn, saveBg, saveFS = MakeBorderedBtn(actionBar, 180, 30, { 0.3, 0.9, 0.3 }, "Save & Broadcast")
    saveBtn:SetPoint("LEFT", actionBar, "LEFT", PAD, 0)
    saveBtn:SetScript("OnClick", function()
        Recruit.SaveConfigFromUI()
        DB.config.version = (DB.config.version or 0) + 1
        DB.config.lastUpdated = time()
        DB.config.updatedBy = SafeCall(UnitName, "player") or ""
        -- Save new fields
        if configState.mplusScoreInput then
            DB.config.mplusCurrentScore = tonumber(configState.mplusScoreInput:GetText()) or 0
        end
        if configState.hardcoreLevelInput then
            DB.config.hardcoreHighestLevel = tonumber(configState.hardcoreLevelInput:GetText()) or 0
        end
        if configState.hardcoreDeathsInput then
            DB.config.hardcoreDeaths = tonumber(configState.hardcoreDeathsInput:GetText()) or 0
        end
        if configState.teamBtn then
            DB.config.recruitTeam = configState.teamBtn.fs:GetText() or "All Ranks"
        end
        if configState.mplusKeyBtn then
            DB.config.mplusTargetKey = tonumber(configState.mplusKeyBtn.fs:GetText()) or 15
        end
        BroadcastConfig()
        BroadcastListing()
        PropagateOwnListing()  -- send to BNet friends for cross-realm spread
        Recruit.RefreshBadge()
        saveFS:SetText("Saved!")
        saveBg:SetColorTexture(0.2, 0.5, 0.2, 0.3)
        C_Timer.After(1.5, function()
            saveFS:SetText("Save & Broadcast")
            saveBg:SetColorTexture(0.3, 0.9, 0.3, 0.2)
        end)
    end)

    -- Close Recruitment button
    local closeRecBtn, closeRecBg, closeRecFS = MakeBorderedBtn(actionBar, 160, 30, { 0.9, 0.3, 0.3 }, "Close Recruitment")
    closeRecBtn:SetPoint("RIGHT", actionBar, "RIGHT", -PAD, 0)
    closeRecBtn:SetScript("OnClick", function()
        if DB and DB.config then
            DB.config.enabled = false
            DB.config.version = (DB.config.version or 0) + 1
            DB.config.lastUpdated = time()
            DB.config.updatedBy = SafeCall(UnitName, "player") or ""
            BroadcastClear()
            Recruit.RefreshBadge()
            Recruit.RefreshConfigOverlay()
        end
    end)

    -- ══════════════════════════════════════════════════════════
    -- EMBEDDED REVIEW PANEL (Applications tab)
    -- ══════════════════════════════════════════════════════════
    local reviewContent = CreateFrame("Frame", nil, configOverlay)
    reviewContent:SetPoint("TOPLEFT", configOverlay, "TOPLEFT", 1, -50)
    reviewContent:SetPoint("BOTTOMRIGHT", configOverlay, "BOTTOMRIGHT", -1, 54)
    reviewContent:Hide()
    configOverlay._reviewContent = reviewContent
    configOverlay._configContent = content

    local revTabBar = CreateFrame("Frame", nil, reviewContent)
    revTabBar:SetHeight(32); revTabBar:SetPoint("TOPLEFT", 0, 0); revTabBar:SetPoint("TOPRIGHT", 0, 0)

    local revTabLine = revTabBar:CreateTexture(nil, "OVERLAY")
    revTabLine:SetHeight(1); revTabLine:SetPoint("BOTTOMLEFT", 1, 0); revTabLine:SetPoint("BOTTOMRIGHT", -1, 0)
    revTabLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.12)

    configOverlay._revTabButtons = {}
    configOverlay._revTab = "pending"
    local revTabs = { { key = "pending", label = "Pending" }, { key = "trial", label = "Trial" }, { key = "history", label = "History" } }
    local revTabX = PAD
    for _, td in ipairs(revTabs) do
        local rtBtn = CreateFrame("Button", nil, revTabBar)
        rtBtn:SetSize(110, 26); rtBtn:SetPoint("LEFT", revTabBar, "LEFT", revTabX, 0)
        local rtBg = rtBtn:CreateTexture(nil, "BACKGROUND"); rtBg:SetAllPoints()
        local rtFS = rtBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(rtFS, BODY_FONT, 11, ""); rtFS:SetPoint("CENTER")
        configOverlay._revTabButtons[td.key] = { btn = rtBtn, bg = rtBg, fs = rtFS }

        local capturedKey = td.key
        rtBtn:SetScript("OnClick", function()
            configOverlay._revTab = capturedKey
            Recruit.RefreshEmbeddedReview()
        end)
        revTabX = revTabX + 116
    end

    local revScroll = CreateFrame("ScrollFrame", nil, reviewContent, "UIPanelScrollFrameTemplate")
    revScroll:SetPoint("TOPLEFT", reviewContent, "TOPLEFT", 1, -34)
    revScroll:SetPoint("BOTTOMRIGHT", reviewContent, "BOTTOMRIGHT", -20, 0)
    local revScrollContent = CreateFrame("Frame", nil, revScroll)
    revScrollContent:SetWidth(OVL_W - 22)
    revScrollContent:SetHeight(1)
    revScroll:SetScrollChild(revScrollContent)
    revScroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then revScrollContent:SetWidth(w) end end)
    if revScroll.ScrollBar then
        local sb = revScroll.ScrollBar
        if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.15); sb.ThumbTexture:SetWidth(3) end
        if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
        if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
    end
    configOverlay._revScrollContent = revScrollContent
    configOverlay._revRows = {}

    -- ══════════════════════════════════════════════════════════
    -- TAB SWITCHING LOGIC
    -- ══════════════════════════════════════════════════════════
    local function SwitchTab(tab)
        configOverlay._activeTab = tab
        if tab == "settings" then
            content:Show()
            actionBar:Show()
            reviewContent:Hide()
            tabSettingsBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
            tabSettingsFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            tabAppsBg:SetColorTexture(0, 0, 0, 0)
            tabAppsFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
        else
            content:Hide()
            actionBar:Hide()
            reviewContent:Show()
            tabSettingsBg:SetColorTexture(0, 0, 0, 0)
            tabSettingsFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
            tabAppsBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
            tabAppsFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            Recruit.RefreshEmbeddedReview()
        end
    end

    tabSettingsBtn:SetScript("OnClick", function() SwitchTab("settings") end)
    tabAppsBtn:SetScript("OnClick", function() SwitchTab("applications") end)

    configOverlay._updateAppCount = function()
        local count = 0
        if DB and DB.applications then
            for _, app in pairs(DB.applications) do
                if app.status == STATUS.PENDING or app.status == STATUS.REVIEWING then
                    count = count + 1
                end
            end
        end
        if count > 0 then
            tabAppsFS:SetText("Applications (" .. count .. ")")
        else
            tabAppsFS:SetText("Applications")
        end
    end

    -- Initial progress section build and left column layout
    RebuildProgressSection()
    RebuildLeftColumn()

    -- Load values for new fields
    if configState.mplusKeyBtn then
        configState.mplusKeyBtn.fs:SetText(tostring(DB.config.mplusTargetKey or 15))
    end
    if configState.mplusScoreInput then
        configState.mplusScoreInput:SetText(tostring(DB.config.mplusCurrentScore or 0))
    end
    if configState.hardcoreLevelInput then
        configState.hardcoreLevelInput:SetText(tostring(DB.config.hardcoreHighestLevel or 0))
    end
    if configState.hardcoreDeathsInput then
        configState.hardcoreDeathsInput:SetText(tostring(DB.config.hardcoreDeaths or 0))
    end

    -- Load current values and set default tab
    Recruit.RefreshConfigOverlay()
    SwitchTab("settings")
    configOverlay._updateAppCount()
    configOverlay:Show()
end

-- ── Refresh the embedded review panel within the config overlay ──
function Recruit.RefreshEmbeddedReview()
    if not configOverlay or not configOverlay._revScrollContent then return end
    if not DB then return end
    local C = GetThemeColors()

    -- Frost line helper (local for review panel)
    local function AddFrostLine(card)
        local frost = card:CreateTexture(nil, "OVERLAY")
        frost:SetHeight(1); frost:SetPoint("TOPLEFT", 1, -1); frost:SetPoint("TOPRIGHT", -1, -1)
        frost:SetColorTexture(1, 1, 1, 0.08)
    end

    -- Clear old rows
    for _, row in ipairs(configOverlay._revRows or {}) do row:Hide(); row:SetParent(nil) end
    configOverlay._revRows = {}

    -- Update sub-tab visuals and counts
    local pendingCount, trialCount, historyCount = 0, 0, 0
    for _, app in pairs(DB.applications) do
        if app.status == STATUS.PENDING or app.status == STATUS.REVIEWING then pendingCount = pendingCount + 1
        elseif app.status == STATUS.TRIAL then trialCount = trialCount + 1 end
    end
    for _ in pairs(DB.history or {}) do historyCount = historyCount + 1 end

    local tabCounts = { pending = pendingCount, trial = trialCount, history = historyCount }
    for key, td in pairs(configOverlay._revTabButtons) do
        local label = key:sub(1,1):upper() .. key:sub(2) .. " (" .. (tabCounts[key] or 0) .. ")"
        td.fs:SetText(label)
        if configOverlay._revTab == key then
            td.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
            td.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
        else
            td.bg:SetColorTexture(0, 0, 0, 0)
            td.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.6)
        end
    end

    if configOverlay._updateAppCount then configOverlay._updateAppCount() end

    local apps = {}
    local curTab = configOverlay._revTab or "pending"
    if curTab == "pending" then
        for key, app in pairs(DB.applications) do
            if app.status == STATUS.PENDING or app.status == STATUS.REVIEWING then
                app._key = key; apps[#apps + 1] = app
            end
        end
    elseif curTab == "trial" then
        for key, app in pairs(DB.applications) do
            if app.status == STATUS.TRIAL then
                app._key = key; apps[#apps + 1] = app
            end
        end
    elseif curTab == "history" then
        for key, app in pairs(DB.history or {}) do
            app._key = key; apps[#apps + 1] = app
        end
    end

    table.sort(apps, function(a, b)
        return (a.appliedAt or 0) > (b.appliedAt or 0)
    end)

    local PAD2 = 20
    local revContent = configOverlay._revScrollContent
    local yOfs = -PAD2

    if #apps == 0 then
        local emptyFS = revContent:CreateFontString(nil, "OVERLAY")
        TrySetFont(emptyFS, BODY_FONT, 12, "")
        emptyFS:SetPoint("TOP", revContent, "TOP", 0, -60)
        emptyFS:SetText("No applications in this category.")
        emptyFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)
        local emptyHolder = CreateFrame("Frame", nil, revContent)
        emptyHolder:SetSize(1, 1); emptyHolder:SetPoint("TOPLEFT")
        emptyHolder.fs = emptyFS
        emptyHolder:SetScript("OnHide", function() emptyFS:Hide() end)
        configOverlay._revRows[1] = emptyHolder
        revContent:SetHeight(120)
        return
    end

    for _, app in ipairs(apps) do
        local row = CreateFrame("Frame", nil, revContent, "BackdropTemplate")
        row:SetHeight(72)
        row:SetPoint("TOPLEFT", revContent, "TOPLEFT", PAD2, yOfs)
        row:SetPoint("RIGHT", revContent, "RIGHT", -PAD2, 0)
        row:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        row:SetBackdropColor(0.08, 0.09, 0.14, 0.5)
        row:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
        AddFrostLine(row)

        local nameFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFS, BODY_FONT, 13, "OUTLINE")
        nameFS:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -10)
        local cr, cg, cb = GetClassColor(app.class or "")
        nameFS:SetText(app.name or "Unknown")
        nameFS:SetTextColor(cr, cg, cb)

        local realmFS2 = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(realmFS2, BODY_FONT, 10, "")
        realmFS2:SetPoint("LEFT", nameFS, "RIGHT", 6, 0)
        realmFS2:SetText("-" .. (app.realm or ""))
        realmFS2:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.6)

        local sc = STATUS_COLORS[app.status] or { 0.5, 0.5, 0.5 }
        local statusBadge = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(statusBadge, BODY_FONT, 9, "OUTLINE")
        statusBadge:SetPoint("TOPRIGHT", row, "TOPRIGHT", -12, -10)
        statusBadge:SetText(app.status or "")
        statusBadge:SetTextColor(sc[1], sc[2], sc[3])

        local infoFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(infoFS, BODY_FONT, 10, "")
        infoFS:SetPoint("TOPLEFT", row, "TOPLEFT", 12, -30)
        local infoParts = {}
        if app.role then infoParts[#infoParts + 1] = app.role end
        if app.spec then infoParts[#infoParts + 1] = app.spec end
        if app.ilvl and app.ilvl > 0 then infoParts[#infoParts + 1] = "ilvl " .. app.ilvl end
        if app.level and app.level > 0 then infoParts[#infoParts + 1] = "Lv" .. app.level end
        infoFS:SetText(table.concat(infoParts, " | "))
        infoFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.7)

        local timeFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(timeFS, BODY_FONT, 9, "")
        timeFS:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -12, 8)
        local appliedTime = app.appliedAt or 0
        if appliedTime > 0 then
            local elapsed = time() - appliedTime
            if elapsed < 3600 then
                timeFS:SetText(math.floor(elapsed / 60) .. "m ago")
            elseif elapsed < 86400 then
                timeFS:SetText(math.floor(elapsed / 3600) .. "h ago")
            else
                timeFS:SetText(math.floor(elapsed / 86400) .. "d ago")
            end
        end
        timeFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)

        local capturedKey = app._key
        local capturedName = (app.name or "") .. "-" .. (app.realm or "")

        if curTab == "pending" or curTab == "trial" then
            local accBtn = CreateFrame("Button", nil, row)
            accBtn:SetSize(52, 22); accBtn:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 12, 8)
            local accBg = accBtn:CreateTexture(nil, "BACKGROUND"); accBg:SetAllPoints()
            accBg:SetColorTexture(0.20, 0.45, 0.20, 0.3)
            local accFS2 = accBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(accFS2, BODY_FONT, 10, ""); accFS2:SetPoint("CENTER")
            accFS2:SetText("Accept"); accFS2:SetTextColor(0.30, 0.90, 0.30)
            accBtn:SetScript("OnEnter", function() accBg:SetColorTexture(0.25, 0.55, 0.25, 0.4) end)
            accBtn:SetScript("OnLeave", function() accBg:SetColorTexture(0.20, 0.45, 0.20, 0.3) end)
            accBtn:SetScript("OnClick", function()
                local officer = SafeCall(UnitName, "player") or ""
                local a2 = DB.applications[capturedKey]
                if a2 then
                    a2.status = STATUS.ACCEPTED; a2.statusChangedAt = time(); a2.statusChangedBy = officer
                    pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, "ASTATUS|" .. (a2.name or "") .. "|" .. (a2.realm or "") .. "|ACCEPTED|" .. officer, "GUILD")
                    pcall(GuildInvite, capturedName)
                    Recruit.RefreshBadge(); Recruit.RefreshEmbeddedReview()
                end
            end)

            local rejBtn = CreateFrame("Button", nil, row)
            rejBtn:SetSize(46, 22); rejBtn:SetPoint("LEFT", accBtn, "RIGHT", 6, 0)
            local rejBg = rejBtn:CreateTexture(nil, "BACKGROUND"); rejBg:SetAllPoints()
            rejBg:SetColorTexture(0.45, 0.20, 0.20, 0.3)
            local rejFS2 = rejBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(rejFS2, BODY_FONT, 10, ""); rejFS2:SetPoint("CENTER")
            rejFS2:SetText("Reject"); rejFS2:SetTextColor(0.90, 0.30, 0.30)
            rejBtn:SetScript("OnEnter", function() rejBg:SetColorTexture(0.55, 0.25, 0.25, 0.4) end)
            rejBtn:SetScript("OnLeave", function() rejBg:SetColorTexture(0.45, 0.20, 0.20, 0.3) end)
            rejBtn:SetScript("OnClick", function()
                local officer = SafeCall(UnitName, "player") or ""
                local a2 = DB.applications[capturedKey]
                if a2 then
                    a2.status = STATUS.REJECTED; a2.statusChangedAt = time(); a2.statusChangedBy = officer
                    pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, "ASTATUS|" .. (a2.name or "") .. "|" .. (a2.realm or "") .. "|REJECTED|" .. officer, "GUILD")
                    Recruit.RefreshBadge(); Recruit.RefreshEmbeddedReview()
                end
            end)

            if curTab == "pending" then
                local trialBtn = CreateFrame("Button", nil, row)
                trialBtn:SetSize(46, 22); trialBtn:SetPoint("LEFT", rejBtn, "RIGHT", 6, 0)
                local trialBg = trialBtn:CreateTexture(nil, "BACKGROUND"); trialBg:SetAllPoints()
                trialBg:SetColorTexture(0.30, 0.20, 0.50, 0.3)
                local trialFS2 = trialBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(trialFS2, BODY_FONT, 10, ""); trialFS2:SetPoint("CENTER")
                trialFS2:SetText("Trial"); trialFS2:SetTextColor(0.60, 0.40, 1.00)
                trialBtn:SetScript("OnEnter", function() trialBg:SetColorTexture(0.40, 0.25, 0.60, 0.4) end)
                trialBtn:SetScript("OnLeave", function() trialBg:SetColorTexture(0.30, 0.20, 0.50, 0.3) end)
                trialBtn:SetScript("OnClick", function()
                    local officer = SafeCall(UnitName, "player") or ""
                    local a2 = DB.applications[capturedKey]
                    if a2 then
                        a2.status = STATUS.TRIAL; a2.statusChangedAt = time(); a2.statusChangedBy = officer
                        a2.trialStarted = time()
                        pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, "ASTATUS|" .. (a2.name or "") .. "|" .. (a2.realm or "") .. "|TRIAL|" .. officer, "GUILD")
                        pcall(GuildInvite, capturedName)
                        Recruit.RefreshBadge(); Recruit.RefreshEmbeddedReview()
                    end
                end)
            end
        end

        row:Show()
        configOverlay._revRows[#configOverlay._revRows + 1] = row
        yOfs = yOfs - 78
    end

    revContent:SetHeight(math.abs(yOfs) + PAD2)
end

function Recruit.SaveConfigFromUI()
    if not DB or not DB.config then return end

    -- Description
    if configState.descInput then
        DB.config.description = configState.descInput:GetText() or ""
    end

    -- Raid progress (auto-generated from structured fields, saved on click)

    -- Schedule (raidStartTime, raidEndTime, raidDays, timezone all saved on click)
    -- Ensure raidTime is synced from start+end
    local startT = DB.config.raidStartTime or ""
    local endT = DB.config.raidEndTime or ""
    if startT ~= "" and endT ~= "" then
        DB.config.raidTime = startT .. " - " .. endT
    elseif startT ~= "" then
        DB.config.raidTime = startT
    else
        DB.config.raidTime = ""
    end

    -- Requirements
    if configState.minLvlInput then
        DB.config.minLevel = tonumber(configState.minLvlInput:GetText()) or 80
    end
    if configState.minIlvlInput then
        DB.config.minIlvl = tonumber(configState.minIlvlInput:GetText()) or 0
    end
    if configState.minMplusInput then
        DB.config.minMplus = tonumber(configState.minMplusInput:GetText()) or 0
    end

    -- Questions
    for qi = 1, 5 do
        if configState.questionInputs[qi] then
            DB.config.questions[qi] = configState.questionInputs[qi]:GetText() or ""
        end
    end

    -- New fields: team, M+, hardcore
    if configState.teamBtn then
        DB.config.recruitTeam = configState.teamBtn.fs:GetText() or "All Ranks"
    end
    if configState.mplusKeyBtn then
        DB.config.mplusTargetKey = tonumber(configState.mplusKeyBtn.fs:GetText()) or 15
    end
    if configState.mplusScoreInput then
        DB.config.mplusCurrentScore = tonumber(configState.mplusScoreInput:GetText()) or 0
    end
    if configState.hardcoreLevelInput then
        DB.config.hardcoreHighestLevel = tonumber(configState.hardcoreLevelInput:GetText()) or 0
    end
    if configState.hardcoreDeathsInput then
        DB.config.hardcoreDeaths = tonumber(configState.hardcoreDeathsInput:GetText()) or 0
    end
end

function Recruit.RefreshConfigOverlay()
    if not configOverlay or not configOverlay:IsShown() then return end
    if not DB or not DB.config then return end
    local cfg = DB.config
    local C = GetThemeColors()

    -- Pill toggle
    if configState._pillBg and configState._pillKnob and configState._pillStatusFS then
        if cfg.enabled then
            configState._pillBg:SetColorTexture(0.15, 0.50, 0.20, 0.5)
            configState._pillKnob:SetColorTexture(0.30, 0.90, 0.30, 0.9)
            configState._pillKnob:SetPoint("RIGHT", configState.enableToggle, "RIGHT", -2, 0)
            configState._pillKnob:ClearAllPoints()
            configState._pillKnob:SetPoint("RIGHT", configState.enableToggle, "RIGHT", -2, 0)
            configState._pillStatusFS:SetText("ACTIVE")
            configState._pillStatusFS:SetTextColor(0.30, 0.90, 0.30)
            if configState._enableLbl then
                configState._enableLbl:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
            end
        else
            configState._pillBg:SetColorTexture(0.25, 0.12, 0.12, 0.5)
            configState._pillKnob:SetColorTexture(0.70, 0.25, 0.25, 0.9)
            configState._pillKnob:ClearAllPoints()
            configState._pillKnob:SetPoint("LEFT", configState.enableToggle, "LEFT", 2, 0)
            configState._pillStatusFS:SetText("INACTIVE")
            configState._pillStatusFS:SetTextColor(0.70, 0.30, 0.30)
            if configState._enableLbl then
                configState._enableLbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
            end
        end
    end

    -- Description
    if configState.descInput then
        configState.descInput:SetText(cfg.description or "")
    end

    -- Guild type tags
    if configState.guildTypeBtns then
        local selectedTypes = {}
        for _, v in ipairs(cfg.guildType or {}) do selectedTypes[v] = true end
        for key, td in pairs(configState.guildTypeBtns) do
            if selectedTypes[key] then
                td.btn:SetBackdropColor(C.accent[1], C.accent[2], C.accent[3], 0.2)
                td.btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.4)
                td.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
                td.icon:SetDesaturated(false); td.icon:SetAlpha(1.0)
            else
                td.btn:SetBackdropColor(0.12, 0.13, 0.20, 0.6)
                td.btn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.25)
                td.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.7)
                td.icon:SetDesaturated(false); td.icon:SetAlpha(0.6)
            end
        end
    end

    -- Rebuild progress section visibility based on guild type
    if Recruit.RebuildProgressSection then
        Recruit.RebuildProgressSection()
    end

    -- Team dropdown
    if configState.teamBtn then
        configState.teamBtn.fs:SetText(cfg.recruitTeam or "All Ranks")
    end

    -- M+ fields
    if configState.mplusKeyBtn then
        configState.mplusKeyBtn.fs:SetText(tostring(cfg.mplusTargetKey or 15))
    end
    if configState.mplusScoreInput then
        local curScore = configState.mplusScoreInput:GetText() or ""
        if curScore == "" then
            configState.mplusScoreInput:SetText(tostring(cfg.mplusCurrentScore or 0))
        end
    end

    -- Hardcore fields
    if configState.hardcoreLevelInput then
        local curLvl = configState.hardcoreLevelInput:GetText() or ""
        if curLvl == "" then
            configState.hardcoreLevelInput:SetText(tostring(cfg.hardcoreHighestLevel or 0))
        end
    end
    if configState.hardcoreDeathsInput then
        local curDeath = configState.hardcoreDeathsInput:GetText() or ""
        if curDeath == "" then
            configState.hardcoreDeathsInput:SetText(tostring(cfg.hardcoreDeaths or 0))
        end
    end

    -- Raid progress selectors
    if configState.progBossBtn then
        configState.progBossBtn.fs:SetText(tostring(cfg.raidProgBosses or 0))
    end
    if configState.progTotalBtn then
        configState.progTotalBtn.fs:SetText(tostring(cfg.raidProgTotal or 8))
    end
    if configState.progDiffBtn then
        local diff = cfg.raidProgDiff or "H"
        local DIFF_DISPLAY = { N = { "Normal", { 0.60, 0.60, 0.60 } }, H = { "Heroic", { 0.65, 0.40, 1.00 } }, M = { "Mythic", { 1.00, 0.50, 0.00 } } }
        local dd = DIFF_DISPLAY[diff] or DIFF_DISPLAY.H
        configState.progDiffBtn.fs:SetText(dd[1])
        configState.progDiffBtn.fs:SetTextColor(dd[2][1], dd[2][2], dd[2][3])
        configState.progDiffBtn.btn:SetBackdropBorderColor(dd[2][1], dd[2][2], dd[2][3], 0.25)
    end
    if configState.progPreviewFS then
        local prog = cfg.raidProgress or ""
        configState.progPreviewFS:SetText(prog ~= "" and prog or "")
    end
    if configState.progAOTCBtn then
        if cfg.raidProgAOTC then
            configState.progAOTCBtn.bg:SetColorTexture(0.65, 0.40, 1.00, 0.2)
            configState.progAOTCBtn.btn:SetBackdropBorderColor(0.65, 0.40, 1.00, 0.4)
            configState.progAOTCBtn.fs:SetTextColor(0.65, 0.40, 1.00)
        else
            configState.progAOTCBtn.bg:SetColorTexture(0.12, 0.13, 0.20, 0.6)
            configState.progAOTCBtn.btn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.25)
            configState.progAOTCBtn.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.6)
        end
    end
    if configState.progCEBtn then
        if cfg.raidProgCE then
            configState.progCEBtn.bg:SetColorTexture(1.00, 0.50, 0.00, 0.2)
            configState.progCEBtn.btn:SetBackdropBorderColor(1.00, 0.50, 0.00, 0.4)
            configState.progCEBtn.fs:SetTextColor(1.00, 0.50, 0.00)
        else
            configState.progCEBtn.bg:SetColorTexture(0.12, 0.13, 0.20, 0.6)
            configState.progCEBtn.btn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.25)
            configState.progCEBtn.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.6)
        end
    end

    -- Race preferences
    if configState.raceBtns then
        local selectedRaces = {}
        for _, v in ipairs(cfg.preferredRaces or {}) do selectedRaces[v] = true end
        for key, rb in pairs(configState.raceBtns) do
            if selectedRaces[key] then
                rb.btn:SetBackdropColor(C.accent[1], C.accent[2], C.accent[3], 0.2)
                rb.btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.4)
                rb.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            else
                rb.btn:SetBackdropColor(0.12, 0.13, 0.20, 0.6)
                rb.btn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.2)
                rb.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.6)
            end
        end
    end

    -- Raid days
    if configState.dayBtns then
        local selectedDays = {}
        for _, v in ipairs(cfg.raidDays or {}) do selectedDays[v] = true end
        for key, dd in pairs(configState.dayBtns) do
            if selectedDays[key] then
                dd.btn:SetBackdropColor(C.accent[1], C.accent[2], C.accent[3], 0.25)
                dd.btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.4)
                dd.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            else
                dd.btn:SetBackdropColor(0.12, 0.13, 0.20, 0.6)
                dd.btn:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.25)
                dd.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.6)
            end
        end
    end

    -- Raid time selectors
    if configState.startTimeBtn then
        local startT = cfg.raidStartTime or ""
        configState.startTimeBtn.fs:SetText(startT ~= "" and startT or "-- : --")
        if startT ~= "" then
            configState.startTimeBtn.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        else
            configState.startTimeBtn.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.4)
        end
    end
    if configState.endTimeBtn then
        local endT = cfg.raidEndTime or ""
        configState.endTimeBtn.fs:SetText(endT ~= "" and endT or "-- : --")
        if endT ~= "" then
            configState.endTimeBtn.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        else
            configState.endTimeBtn.fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.4)
        end
    end

    -- Timezone
    if configState.tzBtn then
        configState.tzBtn.fs:SetText(cfg.timezone or "EST")
    end

    -- Requirements
    if configState.minLvlInput then configState.minLvlInput:SetText(tostring(cfg.minLevel or 80)) end
    if configState.minIlvlInput then configState.minIlvlInput:SetText(tostring(cfg.minIlvl or 0)) end
    if configState.minMplusInput then configState.minMplusInput:SetText(tostring(cfg.minMplus or 0)) end

    -- Role cards
    for _, roleDef in ipairs(ROLE_DEFS) do
        local roleKey = roleDef.key
        local role = cfg.roles[roleKey] or {}
        local rc = roleDef.color

        local toggle = configState.roleToggles[roleKey]
        if toggle then
            if not role.open then
                -- Closed state
                toggle.bg:SetColorTexture(0.35, 0.15, 0.15, 0.35)
                toggle.fs:SetText("Closed"); toggle.fs:SetTextColor(0.75, 0.35, 0.35)
                toggle.card:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)
                toggle.card:SetBackdropColor(0.08, 0.08, 0.12, 0.5)
                if toggle.leftBar then toggle.leftBar:SetColorTexture(0.5, 0.2, 0.2, 0.4) end
            elseif role.priority == "HIGH" then
                -- High need
                toggle.bg:SetColorTexture(rc[1], rc[2], rc[3], 0.25)
                toggle.fs:SetText("High Need"); toggle.fs:SetTextColor(rc[1], rc[2], rc[3])
                toggle.card:SetBackdropBorderColor(rc[1], rc[2], rc[3], 0.3)
                toggle.card:SetBackdropColor(0.08, 0.09, 0.14, 0.6)
                if toggle.leftBar then toggle.leftBar:SetColorTexture(rc[1], rc[2], rc[3], 0.8) end
            else
                -- Low need
                toggle.bg:SetColorTexture(0.50, 0.45, 0.12, 0.2)
                toggle.fs:SetText("Low Need"); toggle.fs:SetTextColor(0.90, 0.80, 0.30)
                toggle.card:SetBackdropBorderColor(0.85, 0.75, 0.25, 0.2)
                toggle.card:SetBackdropColor(0.08, 0.09, 0.14, 0.55)
                if toggle.leftBar then toggle.leftBar:SetColorTexture(0.90, 0.80, 0.30, 0.6) end
            end
        end

        -- Spec buttons
        local specBtns = configState.classButtons[roleKey]
        if specBtns then
            local selectedSpecs = {}
            for _, s in ipairs(role.specs or {}) do selectedSpecs[s] = true end
            for si, sb in ipairs(specBtns) do
                if sb.specId and selectedSpecs[sb.specId] then
                    sb.tex:SetDesaturated(false)
                    sb.tex:SetAlpha(1.0)
                    local cr, cg, cb2 = GetClassColor(sb.classFile)
                    sb.border:SetColorTexture(cr, cg, cb2, 0.7)
                    if sb.bg then sb.bg:SetColorTexture(cr, cg, cb2, 0.12) end
                else
                    sb.tex:SetDesaturated(not role.open)
                    sb.tex:SetAlpha(role.open and 0.55 or 0.35)
                    sb.border:SetColorTexture(0, 0, 0, 0)
                    if sb.bg then sb.bg:SetColorTexture(0, 0, 0, 0) end
                end
            end
        end
    end

    -- Questions
    for qi = 1, 5 do
        if configState.questionInputs[qi] then
            local curText = configState.questionInputs[qi]:GetText() or ""
            if curText == "" then
                configState.questionInputs[qi]:SetText(cfg.questions[qi] or "")
            end
        end
        local qt = configState.questionToggles[qi]
        if qt then
            local enabled = cfg.questionsEnabled[qi] ~= false
            if enabled then
                qt.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
                qt.fs:SetText("+"); qt.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            else
                qt.bg:SetColorTexture(0.15, 0.12, 0.12, 0.5)
                qt.fs:SetText("-"); qt.fs:SetTextColor(0.65, 0.40, 0.40)
            end
            if configState.questionInputs[qi] then
                configState.questionInputs[qi]:SetAlpha(enabled and 1.0 or 0.45)
            end
        end
    end
end

-- ============================================================================
-- §8  UI: APPLICATION FORM (applicant view)
-- ============================================================================
local appFormOverlay = nil
local appFormState = {
    roleSelector = nil,
    availInput = nil,
    answerInputs = {},
}

-- targetInfo: optional table { guildName, sender, listing } for cross-guild applications
function Recruit.ShowApplicationForm(targetInfo)
    local isExternal = targetInfo and targetInfo.sender
    if not isExternal then
        if not DB or not DB.config or not DB.config.enabled then
            local dbg = _G.MidnightUI_Debug or print
            dbg("|cffff5555[Recruitment]|r This guild is not currently recruiting.")
            return
        end
    end

    local gp = _G.MidnightUI_GuildPanelAPI
    local parent
    if isExternal then
        parent = UIParent  -- external applications always anchor to UIParent (Guild Panel may not be open)
    else
        parent = (gp and gp._refs and gp._refs.panel) or UIParent
    end
    local C = GetThemeColors()

    -- Store target info for the submit handler
    appFormState.targetInfo = targetInfo

    if appFormOverlay and appFormOverlay:IsShown() then
        appFormOverlay:Hide()
        return
    end

    local info = GetPlayerInfo()
    local cfg = isExternal and {} or DB.config

    if appFormOverlay then
        -- Re-parent and reposition in case context changed (Guild Panel vs UIParent)
        appFormOverlay:SetParent(parent)
        appFormOverlay:ClearAllPoints()
        appFormOverlay:SetPoint("CENTER", parent, "CENTER", 0, 0)
        appFormOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
        appFormOverlay:Show()
        return
    end

    local PAD = 16
    local OVL_W, OVL_H = 460, 560

    appFormOverlay = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    appFormOverlay:SetSize(OVL_W, OVL_H)
    appFormOverlay:SetPoint("CENTER", parent, "CENTER", 0, 0)
    appFormOverlay:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    appFormOverlay:SetBackdropColor(0.025, 0.028, 0.045, 0.98)
    appFormOverlay:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.25)
    appFormOverlay:SetFrameStrata("FULLSCREEN_DIALOG")
    appFormOverlay:SetFrameLevel(600)  -- above Guild Finder (level 500)
    appFormOverlay:EnableMouse(true); appFormOverlay:SetMovable(true); appFormOverlay:SetClampedToScreen(true)

    -- Drop shadow
    for i = 1, 6 do
        local s = appFormOverlay:CreateTexture(nil, "BACKGROUND", nil, -1)
        local off = i * 2
        s:SetColorTexture(0, 0, 0, 0.20 - (i * 0.028))
        s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
    end

    -- Top accent bar
    local topBar = appFormOverlay:CreateTexture(nil, "OVERLAY", nil, 4)
    topBar:SetHeight(3); topBar:SetPoint("TOPLEFT", 1, -1); topBar:SetPoint("TOPRIGHT", -1, -1)
    topBar:SetTexture(W8)
    if topBar.SetGradient and CreateColor then
        topBar:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.9),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.2))
    end

    -- Header (draggable)
    local headerBar = CreateFrame("Frame", nil, appFormOverlay)
    headerBar:SetHeight(44); headerBar:SetPoint("TOPLEFT", 0, 0); headerBar:SetPoint("TOPRIGHT", 0, 0)
    headerBar:EnableMouse(true); headerBar:RegisterForDrag("LeftButton")
    headerBar:SetScript("OnDragStart", function() appFormOverlay:StartMoving() end)
    headerBar:SetScript("OnDragStop", function() appFormOverlay:StopMovingOrSizing() end)

    local titleFS = headerBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(titleFS, TITLE_FONT, 16, "OUTLINE")
    titleFS:SetPoint("LEFT", headerBar, "LEFT", PAD, 0)
    if targetInfo and targetInfo.guildName then
        titleFS:SetText("Apply to " .. targetInfo.guildName)
    else
        titleFS:SetText("Apply to Guild")
    end
    titleFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

    local closeBtn = CreateFrame("Button", nil, headerBar)
    closeBtn:SetSize(28, 28); closeBtn:SetPoint("RIGHT", headerBar, "RIGHT", -10, 0)
    local closeTx = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeTx, TITLE_FONT, 16, "OUTLINE"); closeTx:SetPoint("CENTER"); closeTx:SetText("X")
    closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7)
    closeBtn:SetScript("OnEnter", function() closeTx:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3]) end)
    closeBtn:SetScript("OnLeave", function() closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7) end)
    closeBtn:SetScript("OnClick", function() appFormOverlay:Hide() end)

    -- Scrollable content
    local scroll = CreateFrame("ScrollFrame", nil, appFormOverlay, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", appFormOverlay, "TOPLEFT", 1, -44)
    scroll:SetPoint("BOTTOMRIGHT", appFormOverlay, "BOTTOMRIGHT", -20, 50)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(OVL_W - 22)
    content:SetHeight(1)
    scroll:SetScrollChild(content)

    local yOfs = -PAD

    -- ── Character Info Card (auto-populated, read-only) ──
    local infoCard = CreateFrame("Frame", nil, content, "BackdropTemplate")
    infoCard:SetHeight(70)
    infoCard:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, yOfs)
    infoCard:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    infoCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    infoCard:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.5)
    infoCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.15)

    local r, g, b = GetClassColor(info.class)

    local nameFS = infoCard:CreateFontString(nil, "OVERLAY")
    TrySetFont(nameFS, BODY_FONT, 14, "")
    nameFS:SetPoint("TOPLEFT", infoCard, "TOPLEFT", 10, -10)
    nameFS:SetText(info.name .. " - " .. info.realm)
    nameFS:SetTextColor(r, g, b)

    local detailFS = infoCard:CreateFontString(nil, "OVERLAY")
    TrySetFont(detailFS, BODY_FONT, 11, "")
    detailFS:SetPoint("TOPLEFT", nameFS, "BOTTOMLEFT", 0, -4)
    local detailText = info.spec .. " " .. (info.class and info.class:sub(1,1):upper() .. info.class:sub(2):lower() or "")
        .. "  |cffaaaaaa" .. info.level .. "|r"
        .. "  |cffaaaaaa" .. info.ilvl .. " ilvl|r"
        .. "  |cff00c8ff" .. info.mplusRating .. " M+|r"
    detailFS:SetText(detailText)
    detailFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

    yOfs = yOfs - 80

    -- ── Role Selector ──
    local roleLbl = content:CreateFontString(nil, "OVERLAY")
    TrySetFont(roleLbl, BODY_FONT, 10, "OUTLINE")
    roleLbl:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, yOfs)
    roleLbl:SetText("APPLYING AS")
    roleLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

    yOfs = yOfs - 20

    local selectedRole = nil
    local roleBtns = {}
    local roleXOfs = PAD
    for _, roleDef in ipairs(ROLE_DEFS) do
        local roleBtn = CreateFrame("Button", nil, content)
        roleBtn:SetSize(80, 28); roleBtn:SetPoint("TOPLEFT", content, "TOPLEFT", roleXOfs, yOfs)
        local roleBg = roleBtn:CreateTexture(nil, "BACKGROUND"); roleBg:SetAllPoints()
        roleBg:SetColorTexture(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.6)
        local roleFS = roleBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(roleFS, BODY_FONT, 11, ""); roleFS:SetPoint("CENTER")
        roleFS:SetText(roleDef.label)
        roleFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local capturedKey = roleDef.key
        local capturedColor = roleDef.color
        roleBtn:SetScript("OnClick", function()
            selectedRole = capturedKey
            for _, rb in ipairs(roleBtns) do
                rb.bg:SetColorTexture(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.6)
                rb.fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
            end
            roleBg:SetColorTexture(capturedColor[1], capturedColor[2], capturedColor[3], 0.3)
            roleFS:SetTextColor(capturedColor[1], capturedColor[2], capturedColor[3])
        end)

        roleBtns[#roleBtns + 1] = { bg = roleBg, fs = roleFS }
        roleXOfs = roleXOfs + 88
    end

    yOfs = yOfs - 38

    -- ── Availability ──
    local availLbl = content:CreateFontString(nil, "OVERLAY")
    TrySetFont(availLbl, BODY_FONT, 10, "OUTLINE")
    availLbl:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, yOfs)
    availLbl:SetText("AVAILABILITY")
    availLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

    yOfs = yOfs - 18

    local availInput = CreateFrame("EditBox", nil, content, "BackdropTemplate")
    availInput:SetHeight(22)
    availInput:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, yOfs)
    availInput:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    availInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    availInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4] or 0.9)
    availInput:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.3)
    availInput:SetAutoFocus(false)
    availInput:SetMaxLetters(200)
    TrySetFont(availInput, BODY_FONT, 11, "")
    availInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    availInput:SetTextInsets(6, 6, 0, 0)
    availInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    availInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    appFormState.availInput = availInput

    yOfs = yOfs - 30

    -- ── Custom Questions ──
    appFormState.answerInputs = {}
    local cfgQuestions = cfg.questions or {}
    local cfgQEnabled = cfg.questionsEnabled or {}
    for qi = 1, 5 do
        if cfgQEnabled[qi] and cfgQuestions[qi] and cfgQuestions[qi] ~= "" then
            local qLblFS = content:CreateFontString(nil, "OVERLAY")
            TrySetFont(qLblFS, BODY_FONT, 10, "")
            qLblFS:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, yOfs)
            qLblFS:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
            qLblFS:SetText(cfgQuestions[qi])
            qLblFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
            qLblFS:SetWordWrap(true)
            qLblFS:SetJustifyH("LEFT")

            yOfs = yOfs - (qLblFS:GetStringHeight() + 6)

            local ansInput = CreateFrame("EditBox", nil, content, "BackdropTemplate")
            ansInput:SetHeight(40)
            ansInput:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, yOfs)
            ansInput:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
            ansInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            ansInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4] or 0.9)
            ansInput:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.3)
            ansInput:SetMultiLine(true)
            ansInput:SetAutoFocus(false)
            ansInput:SetMaxLetters(300)
            TrySetFont(ansInput, BODY_FONT, 10, "")
            ansInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
            ansInput:SetTextInsets(6, 6, 4, 4)
            ansInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            appFormState.answerInputs[qi] = ansInput

            yOfs = yOfs - 48
        end
    end

    -- Set content height
    content:SetHeight(math.abs(yOfs) + PAD)

    -- ── Submit Button ──
    local actionBar = CreateFrame("Frame", nil, appFormOverlay)
    actionBar:SetHeight(46); actionBar:SetPoint("BOTTOMLEFT", 0, 0); actionBar:SetPoint("BOTTOMRIGHT", 0, 0)
    local actionLine = actionBar:CreateTexture(nil, "OVERLAY")
    actionLine:SetHeight(1); actionLine:SetPoint("TOPLEFT"); actionLine:SetPoint("TOPRIGHT")
    actionLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.3)

    local submitBtn = CreateFrame("Button", nil, actionBar)
    submitBtn:SetSize(160, 28); submitBtn:SetPoint("CENTER", actionBar, "CENTER", 0, 0)
    local submitBg = submitBtn:CreateTexture(nil, "BACKGROUND"); submitBg:SetAllPoints()
    submitBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3)
    local submitFS = submitBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(submitFS, BODY_FONT, 12, "OUTLINE"); submitFS:SetPoint("CENTER")
    submitFS:SetText("Submit Application"); submitFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

    -- Borders
    local stT = submitBtn:CreateTexture(nil, "OVERLAY"); stT:SetHeight(1)
    stT:SetPoint("TOPLEFT"); stT:SetPoint("TOPRIGHT"); stT:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3)
    local stB = submitBtn:CreateTexture(nil, "OVERLAY"); stB:SetHeight(1)
    stB:SetPoint("BOTTOMLEFT"); stB:SetPoint("BOTTOMRIGHT"); stB:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3)
    local stL = submitBtn:CreateTexture(nil, "OVERLAY"); stL:SetWidth(1)
    stL:SetPoint("TOPLEFT"); stL:SetPoint("BOTTOMLEFT"); stL:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3)
    local stR = submitBtn:CreateTexture(nil, "OVERLAY"); stR:SetWidth(1)
    stR:SetPoint("TOPRIGHT"); stR:SetPoint("BOTTOMRIGHT"); stR:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3)

    submitBtn:SetScript("OnEnter", function() submitBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.5) end)
    submitBtn:SetScript("OnLeave", function() submitBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3) end)
    submitBtn:SetScript("OnClick", function()
        local avail = appFormState.availInput and appFormState.availInput:GetText() or ""
        local role = selectedRole or ""
        local target = appFormState.targetInfo

        local applyPayload = "APPLY|" .. info.name .. "|" .. info.realm .. "|" .. info.class
            .. "|" .. info.spec .. "|" .. info.level .. "|" .. info.ilvl
            .. "|" .. info.mplusRating .. "|" .. info.achievePts
            .. "|" .. role .. "|" .. avail

        if target and target.sender and target.sender ~= "" then
            -- Cross-guild application: send via WHISPER to officer (if online)
            SendChunked(applyPayload, "WHISPER", target.sender)

            -- Also broadcast via shared channel so ANY guild member can receive it
            -- GAPPLY includes the target guild name so only that guild processes it
            if recruitChannelId and target.guildName then
                local gapplyPayload = "GAPPLY|" .. (target.guildName or "") .. "|" .. info.name
                    .. "|" .. info.realm .. "|" .. info.class .. "|" .. info.spec
                    .. "|" .. info.level .. "|" .. info.ilvl .. "|" .. info.mplusRating
                    .. "|" .. info.achievePts .. "|" .. role .. "|" .. avail
                C_Timer.After(0.5, function()
                    SendChunked(gapplyPayload, "CHANNEL", tostring(recruitChannelId))
                end)
            end

            -- Send answers via both channels
            for qi = 1, 5 do
                if appFormState.answerInputs[qi] then
                    local ans = appFormState.answerInputs[qi]:GetText() or ""
                    if ans ~= "" then
                        C_Timer.After(0.3 * qi, function()
                            local aPayload = "AANSWER|" .. info.name .. "|" .. qi .. "|" .. ans
                            SendChunked(aPayload, "WHISPER", target.sender)
                        end)
                    end
                end
            end
        else
            -- In-guild application: send via GUILD channel
            SendChunked(applyPayload, "GUILD")

            for qi = 1, 5 do
                if appFormState.answerInputs[qi] then
                    local ans = appFormState.answerInputs[qi]:GetText() or ""
                    if ans ~= "" then
                        C_Timer.After(0.3 * qi, function()
                            local aPayload = "AANSWER|" .. info.name .. "|" .. qi .. "|" .. ans
                            SendChunked(aPayload, "GUILD")
                        end)
                    end
                end
            end
        end

        -- Store in pending outbound for retry if no ACK received
        if target and target.guildName and target.guildName ~= "" then
            if not DB.pendingOutbound then DB.pendingOutbound = {} end
            DB.pendingOutbound[target.guildName] = {
                payload = applyPayload,
                gapplyPayload = (target.guildName and recruitChannelId) and
                    ("GAPPLY|" .. (target.guildName or "") .. "|" .. info.name
                    .. "|" .. info.realm .. "|" .. info.class .. "|" .. info.spec
                    .. "|" .. info.level .. "|" .. info.ilvl .. "|" .. info.mplusRating
                    .. "|" .. info.achievePts .. "|" .. role .. "|" .. avail) or nil,
                sender = target.sender or "",
                guildName = target.guildName,
                sentAt = time(),
                delivered = false,
            }
        end

        submitFS:SetText("Submitted!")
        submitBg:SetColorTexture(0.15, 0.40, 0.15, 0.3)
        submitBtn:SetScript("OnClick", nil)

        C_Timer.After(2, function()
            if appFormOverlay then appFormOverlay:Hide() end
        end)
    end)

    appFormOverlay:Show()
end

-- ============================================================================
-- §9  UI: OFFICER REVIEW PANEL
-- ============================================================================
local reviewPanel = nil
local reviewState = {
    tab = "pending",  -- "pending", "trial", "history"
    rows = {},
    expandedKey = nil,
}

function Recruit.ShowReviewPanel()
    if not CanManageRecruitment() and not CanGuildInviteCheck() then
        local dbg = _G.MidnightUI_Debug or print
        dbg("|cffff5555[Recruitment]|r You don't have permission to review applications.")
        return
    end

    local gp = _G.MidnightUI_GuildPanelAPI
    local parent = (gp and gp._refs and gp._refs.panel) or UIParent
    local C = GetThemeColors()

    if reviewPanel and reviewPanel:IsShown() then
        reviewPanel:Hide()
        return
    end

    if reviewPanel then
        Recruit.RefreshReviewPanel()
        reviewPanel:Show()
        return
    end

    local PAD = 16
    local OVL_W, OVL_H = 560, 600

    reviewPanel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    reviewPanel:SetSize(OVL_W, OVL_H)
    reviewPanel:SetPoint("CENTER", parent, "CENTER", 0, 0)
    reviewPanel:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    reviewPanel:SetBackdropColor(0.025, 0.028, 0.045, 0.98)
    reviewPanel:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.25)
    reviewPanel:SetFrameLevel(parent:GetFrameLevel() + 30)
    reviewPanel:EnableMouse(true); reviewPanel:SetMovable(true); reviewPanel:SetClampedToScreen(true)

    -- Drop shadow
    for i = 1, 6 do
        local s = reviewPanel:CreateTexture(nil, "BACKGROUND", nil, -1)
        local off = i * 2
        s:SetColorTexture(0, 0, 0, 0.20 - (i * 0.028))
        s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
    end

    -- Top accent bar
    local topBar = reviewPanel:CreateTexture(nil, "OVERLAY", nil, 4)
    topBar:SetHeight(3); topBar:SetPoint("TOPLEFT", 1, -1); topBar:SetPoint("TOPRIGHT", -1, -1)
    topBar:SetTexture(W8)
    if topBar.SetGradient and CreateColor then
        topBar:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.9),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.2))
    end

    -- Header (draggable)
    local headerBar = CreateFrame("Frame", nil, reviewPanel)
    headerBar:SetHeight(44); headerBar:SetPoint("TOPLEFT", 0, 0); headerBar:SetPoint("TOPRIGHT", 0, 0)
    headerBar:EnableMouse(true); headerBar:RegisterForDrag("LeftButton")
    headerBar:SetScript("OnDragStart", function() reviewPanel:StartMoving() end)
    headerBar:SetScript("OnDragStop", function() reviewPanel:StopMovingOrSizing() end)

    local titleFS = headerBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(titleFS, TITLE_FONT, 16, "OUTLINE")
    titleFS:SetPoint("LEFT", headerBar, "LEFT", PAD, 0)
    titleFS:SetText("Applications")
    titleFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

    local closeBtn = CreateFrame("Button", nil, headerBar)
    closeBtn:SetSize(28, 28); closeBtn:SetPoint("RIGHT", headerBar, "RIGHT", -10, 0)
    local closeTx = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeTx, TITLE_FONT, 16, "OUTLINE"); closeTx:SetPoint("CENTER"); closeTx:SetText("X")
    closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7)
    closeBtn:SetScript("OnEnter", function() closeTx:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3]) end)
    closeBtn:SetScript("OnLeave", function() closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7) end)
    closeBtn:SetScript("OnClick", function() reviewPanel:Hide() end)

    -- Tab bar
    local tabBar = CreateFrame("Frame", nil, reviewPanel)
    tabBar:SetHeight(28); tabBar:SetPoint("TOPLEFT", reviewPanel, "TOPLEFT", 0, -44); tabBar:SetPoint("TOPRIGHT", reviewPanel, "TOPRIGHT", 0, -44)

    reviewPanel._tabButtons = {}
    local tabs = { { key = "pending", label = "Pending" }, { key = "trial", label = "Trial" }, { key = "history", label = "History" } }
    local tabXOfs = PAD
    for _, tabDef in ipairs(tabs) do
        local tabBtn = CreateFrame("Button", nil, tabBar)
        tabBtn:SetSize(100, 24); tabBtn:SetPoint("LEFT", tabBar, "LEFT", tabXOfs, 0)
        local tabBg = tabBtn:CreateTexture(nil, "BACKGROUND"); tabBg:SetAllPoints()
        local tabFS = tabBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(tabFS, BODY_FONT, 11, ""); tabFS:SetPoint("CENTER")
        reviewPanel._tabButtons[tabDef.key] = { btn = tabBtn, bg = tabBg, fs = tabFS }

        local capturedKey = tabDef.key
        tabBtn:SetScript("OnClick", function()
            reviewState.tab = capturedKey
            Recruit.RefreshReviewPanel()
        end)

        tabXOfs = tabXOfs + 108
    end

    -- Scrollable content
    local scroll = CreateFrame("ScrollFrame", nil, reviewPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", reviewPanel, "TOPLEFT", 1, -76)
    scroll:SetPoint("BOTTOMRIGHT", reviewPanel, "BOTTOMRIGHT", -20, 4)
    local revContent = CreateFrame("Frame", nil, scroll)
    revContent:SetWidth(OVL_W - 22)
    revContent:SetHeight(1)
    scroll:SetScrollChild(revContent)
    scroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then revContent:SetWidth(w) end end)

    reviewPanel._content = revContent
    reviewPanel._scroll = scroll

    Recruit.RefreshReviewPanel()
    reviewPanel:Show()
end

function Recruit.RefreshReviewPanel()
    if not reviewPanel or not reviewPanel:IsShown() then return end
    if not DB then return end
    local C = GetThemeColors()

    -- Clear old rows
    for _, row in ipairs(reviewState.rows) do
        row:Hide()
        row:SetParent(nil)
    end
    reviewState.rows = {}

    -- Update tab labels with counts
    local pendingCount, trialCount, historyCount = 0, 0, 0
    for _, app in pairs(DB.applications) do
        if app.status == STATUS.PENDING or app.status == STATUS.REVIEWING then
            pendingCount = pendingCount + 1
        elseif app.status == STATUS.TRIAL then
            trialCount = trialCount + 1
        end
    end
    for _ in pairs(DB.history or {}) do historyCount = historyCount + 1 end

    local tabCounts = { pending = pendingCount, trial = trialCount, history = historyCount }
    for key, td in pairs(reviewPanel._tabButtons) do
        local label = key:sub(1,1):upper() .. key:sub(2) .. " (" .. (tabCounts[key] or 0) .. ")"
        td.fs:SetText(label)
        if reviewState.tab == key then
            td.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
            td.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
        else
            td.bg:SetColorTexture(0, 0, 0, 0)
            td.fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
        end
    end

    -- Collect applications for current tab
    local apps = {}
    if reviewState.tab == "pending" then
        for key, app in pairs(DB.applications) do
            if app.status == STATUS.PENDING or app.status == STATUS.REVIEWING then
                app._key = key
                apps[#apps + 1] = app
            end
        end
    elseif reviewState.tab == "trial" then
        for key, app in pairs(DB.applications) do
            if app.status == STATUS.TRIAL then
                app._key = key
                apps[#apps + 1] = app
            end
        end
    elseif reviewState.tab == "history" then
        for key, app in pairs(DB.history or {}) do
            app._key = key
            apps[#apps + 1] = app
        end
    end

    -- Sort by appliedAt (newest first)
    table.sort(apps, function(a, b) return (a.appliedAt or 0) > (b.appliedAt or 0) end)

    local revContent = reviewPanel._content
    local PAD = 12
    local yOfs = -PAD

    if #apps == 0 then
        local emptyFS = revContent:CreateFontString(nil, "OVERLAY")
        TrySetFont(emptyFS, BODY_FONT, 12, "")
        emptyFS:SetPoint("CENTER", revContent, "TOP", 0, -60)
        emptyFS:SetText("No applications in this category.")
        emptyFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        local emptyHolder = CreateFrame("Frame", nil, revContent)
        emptyHolder:SetSize(1, 1); emptyHolder:SetPoint("CENTER")
        emptyHolder:SetScript("OnHide", function() emptyFS:Hide() end)
        reviewState.rows[1] = emptyHolder
        revContent:SetHeight(120)
        return
    end

    for _, app in ipairs(apps) do
        local cr, cg, cb = GetClassColor(app.class)

        local row = CreateFrame("Frame", nil, revContent, "BackdropTemplate")
        row:SetHeight(60)
        row:SetPoint("TOPLEFT", revContent, "TOPLEFT", PAD, yOfs)
        row:SetPoint("RIGHT", revContent, "RIGHT", -PAD, 0)
        row:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        row:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.4)
        row:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.1)

        -- Name (class-colored)
        local nameFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFS, BODY_FONT, 12, "")
        nameFS:SetPoint("TOPLEFT", row, "TOPLEFT", 10, -8)
        nameFS:SetText(app.name or "Unknown")
        nameFS:SetTextColor(cr, cg, cb)

        -- Spec + Level
        local specFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(specFS, BODY_FONT, 10, "")
        specFS:SetPoint("TOPLEFT", nameFS, "BOTTOMLEFT", 0, -2)
        local specText = (app.spec or "") .. "  " .. (app.level or 0)
        if (app.ilvl or 0) > 0 then specText = specText .. "  |cffaaaaaa" .. app.ilvl .. " ilvl|r" end
        if (app.mplusRating or 0) > 0 then specText = specText .. "  |cff00c8ff" .. app.mplusRating .. " M+|r" end
        specFS:SetText(specText)
        specFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        -- Source badge
        local sourceBadge = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(sourceBadge, BODY_FONT, 9, "OUTLINE")
        sourceBadge:SetPoint("TOPRIGHT", row, "TOPRIGHT", -10, -8)
        local src = app.source or "addon"
        if src == "addon" then
            sourceBadge:SetText("MUI"); sourceBadge:SetTextColor(0.00, 0.78, 1.00)
        elseif src == "chat" then
            sourceBadge:SetText("CHAT"); sourceBadge:SetTextColor(0.85, 0.70, 0.20)
        elseif src == "whisper" then
            sourceBadge:SetText("WHISPER"); sourceBadge:SetTextColor(0.70, 0.40, 1.00)
        end

        -- Time since applied
        local timeFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(timeFS, BODY_FONT, 9, "")
        timeFS:SetPoint("RIGHT", sourceBadge, "LEFT", -8, 0)
        local elapsed = time() - (app.appliedAt or 0)
        local timeText = ""
        if elapsed < 3600 then timeText = math.floor(elapsed / 60) .. "m ago"
        elseif elapsed < 86400 then timeText = math.floor(elapsed / 3600) .. "h ago"
        else timeText = math.floor(elapsed / 86400) .. "d ago" end
        timeFS:SetText(timeText)
        timeFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        -- Vote display
        local voteFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(voteFS, BODY_FONT, 9, "")
        voteFS:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -10, 8)
        local upCount = app.votes and #app.votes.up or 0
        local downCount = app.votes and #app.votes.down or 0
        voteFS:SetText("|cff40d940+" .. upCount .. "|r  |cffff4040-" .. downCount .. "|r")

        -- Action buttons (only for pending/reviewing/trial)
        if reviewState.tab ~= "history" then
            local capturedKey = app._key
            local capturedName = app.name or ""

            -- Accept button
            local accBtn = CreateFrame("Button", nil, row)
            accBtn:SetSize(50, 20); accBtn:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 10, 6)
            local accBg = accBtn:CreateTexture(nil, "BACKGROUND"); accBg:SetAllPoints()
            accBg:SetColorTexture(0.15, 0.40, 0.15, 0.3)
            local accFS = accBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(accFS, BODY_FONT, 10, ""); accFS:SetPoint("CENTER")
            accFS:SetText("Accept"); accFS:SetTextColor(0.3, 0.9, 0.3)
            accBtn:SetScript("OnEnter", function() accBg:SetColorTexture(0.20, 0.50, 0.20, 0.4) end)
            accBtn:SetScript("OnLeave", function() accBg:SetColorTexture(0.15, 0.40, 0.15, 0.3) end)
            accBtn:SetScript("OnClick", function()
                local officer = SafeCall(UnitName, "player") or ""
                local app2 = DB.applications[capturedKey]
                if app2 then
                    app2.status = STATUS.ACCEPTED
                    app2.statusChangedAt = time()
                    app2.statusChangedBy = officer
                    app2.archivedAt = time()
                    DB.history[capturedKey] = app2
                    DB.applications[capturedKey] = nil

                    -- Broadcast status change
                    local statusPayload = "ASTATUS|" .. (app2.name or "") .. "|" .. (app2.realm or "") .. "|" .. STATUS.ACCEPTED .. "|" .. officer
                    pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, statusPayload, "GUILD")

                    -- Try to invite
                    pcall(GuildInvite, capturedName)

                    Recruit.RefreshBadge()
                    Recruit.RefreshReviewPanel()
                end
            end)

            -- Reject button
            local rejBtn = CreateFrame("Button", nil, row)
            rejBtn:SetSize(50, 20); rejBtn:SetPoint("LEFT", accBtn, "RIGHT", 4, 0)
            local rejBg = rejBtn:CreateTexture(nil, "BACKGROUND"); rejBg:SetAllPoints()
            rejBg:SetColorTexture(0.40, 0.15, 0.15, 0.3)
            local rejFS = rejBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(rejFS, BODY_FONT, 10, ""); rejFS:SetPoint("CENTER")
            rejFS:SetText("Reject"); rejFS:SetTextColor(0.9, 0.3, 0.3)
            rejBtn:SetScript("OnEnter", function() rejBg:SetColorTexture(0.50, 0.20, 0.20, 0.4) end)
            rejBtn:SetScript("OnLeave", function() rejBg:SetColorTexture(0.40, 0.15, 0.15, 0.3) end)
            rejBtn:SetScript("OnClick", function()
                local officer = SafeCall(UnitName, "player") or ""
                local app2 = DB.applications[capturedKey]
                if app2 then
                    app2.status = STATUS.REJECTED
                    app2.statusChangedAt = time()
                    app2.statusChangedBy = officer
                    app2.archivedAt = time()
                    DB.history[capturedKey] = app2
                    DB.applications[capturedKey] = nil

                    local statusPayload = "ASTATUS|" .. (app2.name or "") .. "|" .. (app2.realm or "") .. "|" .. STATUS.REJECTED .. "|" .. officer
                    pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, statusPayload, "GUILD")

                    Recruit.RefreshBadge()
                    Recruit.RefreshReviewPanel()
                end
            end)

            -- Trial button (for pending only)
            if reviewState.tab == "pending" then
                local trialBtn = CreateFrame("Button", nil, row)
                trialBtn:SetSize(40, 20); trialBtn:SetPoint("LEFT", rejBtn, "RIGHT", 4, 0)
                local trialBg = trialBtn:CreateTexture(nil, "BACKGROUND"); trialBg:SetAllPoints()
                trialBg:SetColorTexture(0.30, 0.20, 0.50, 0.3)
                local trialFS = trialBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(trialFS, BODY_FONT, 10, ""); trialFS:SetPoint("CENTER")
                trialFS:SetText("Trial"); trialFS:SetTextColor(0.60, 0.40, 1.00)
                trialBtn:SetScript("OnEnter", function() trialBg:SetColorTexture(0.40, 0.25, 0.60, 0.4) end)
                trialBtn:SetScript("OnLeave", function() trialBg:SetColorTexture(0.30, 0.20, 0.50, 0.3) end)
                trialBtn:SetScript("OnClick", function()
                    local officer = SafeCall(UnitName, "player") or ""
                    local app2 = DB.applications[capturedKey]
                    if app2 then
                        app2.status = STATUS.TRIAL
                        app2.statusChangedAt = time()
                        app2.statusChangedBy = officer
                        app2.trialStarted = time()

                        local statusPayload = "ASTATUS|" .. (app2.name or "") .. "|" .. (app2.realm or "") .. "|" .. STATUS.TRIAL .. "|" .. officer
                        pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, statusPayload, "GUILD")

                        pcall(GuildInvite, capturedName)

                        Recruit.RefreshBadge()
                        Recruit.RefreshReviewPanel()
                    end
                end)
            end

            -- Vote buttons
            local voteUpBtn = CreateFrame("Button", nil, row)
            voteUpBtn:SetSize(20, 20); voteUpBtn:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -80, 6)
            local voteUpFS = voteUpBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(voteUpFS, BODY_FONT, 14, ""); voteUpFS:SetPoint("CENTER")
            voteUpFS:SetText("+"); voteUpFS:SetTextColor(0.40, 0.85, 0.40, 0.6)
            voteUpBtn:SetScript("OnEnter", function() voteUpFS:SetTextColor(0.40, 0.85, 0.40, 1.0) end)
            voteUpBtn:SetScript("OnLeave", function() voteUpFS:SetTextColor(0.40, 0.85, 0.40, 0.6) end)
            voteUpBtn:SetScript("OnClick", function()
                local officer = SafeCall(UnitName, "player") or ""
                local payload = "OVOTE|" .. (app.name or "") .. "|" .. (app.realm or "") .. "|" .. officer .. "|UP"
                pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, payload, "GUILD")
                HandleOVOTE(payload, officer)
            end)

            local voteDownBtn = CreateFrame("Button", nil, row)
            voteDownBtn:SetSize(20, 20); voteDownBtn:SetPoint("LEFT", voteUpBtn, "RIGHT", 2, 0)
            local voteDownFS = voteDownBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(voteDownFS, BODY_FONT, 14, ""); voteDownFS:SetPoint("CENTER")
            voteDownFS:SetText("-"); voteDownFS:SetTextColor(0.85, 0.40, 0.40, 0.6)
            voteDownBtn:SetScript("OnEnter", function() voteDownFS:SetTextColor(0.85, 0.40, 0.40, 1.0) end)
            voteDownBtn:SetScript("OnLeave", function() voteDownFS:SetTextColor(0.85, 0.40, 0.40, 0.6) end)
            voteDownBtn:SetScript("OnClick", function()
                local officer = SafeCall(UnitName, "player") or ""
                local payload = "OVOTE|" .. (app.name or "") .. "|" .. (app.realm or "") .. "|" .. officer .. "|DOWN"
                pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, payload, "GUILD")
                HandleOVOTE(payload, officer)
            end)
        end

        row:Show()
        reviewState.rows[#reviewState.rows + 1] = row
        yOfs = yOfs - 68
    end

    revContent:SetHeight(math.abs(yOfs) + PAD)
end

-- ============================================================================
-- §10  UI: RECRUITMENT STATUS BADGE (hero banner integration)
-- ============================================================================
local recruitBadge = nil

function Recruit.RefreshBadge()
    -- Update badge in hero banner if it exists
    if recruitBadge then
        if DB and DB.config and DB.config.enabled then
            local roles = {}
            for _, rd in ipairs(ROLE_DEFS) do
                local r = DB.config.roles[rd.key]
                if r and r.open then
                    local pc = PRIORITY_COLORS[r.priority or "NONE"]
                    local colorStr = string.format("|cff%02x%02x%02x", pc[1]*255, pc[2]*255, pc[3]*255)
                    roles[#roles + 1] = colorStr .. rd.label .. "|r"
                end
            end
            if #roles > 0 then
                recruitBadge.text:SetText("Recruiting:  " .. table.concat(roles, "  "))
                recruitBadge:Show()
            else
                recruitBadge:Hide()
            end
        else
            recruitBadge:Hide()
        end
    end

    -- Update header button badge dot
    if Recruit._headerBadgeDot then
        local count = 0
        if DB and DB.applications then
            for _, app in pairs(DB.applications) do
                if app.status == STATUS.PENDING or app.status == STATUS.REVIEWING then
                    count = count + 1
                end
            end
        end
        if count > 0 then
            Recruit._headerBadgeDot:Show()
            if Recruit._headerBadgeCount then
                Recruit._headerBadgeCount:SetText(tostring(count))
                Recruit._headerBadgeCount:Show()
            end
        else
            Recruit._headerBadgeDot:Hide()
            if Recruit._headerBadgeCount then Recruit._headerBadgeCount:Hide() end
        end
    end

    -- Update embedded review app count
    if configOverlay and configOverlay._updateAppCount then
        configOverlay._updateAppCount()
    end
end

function Recruit.CreateBadge(parent, C)
    if recruitBadge then return recruitBadge end

    recruitBadge = CreateFrame("Frame", nil, parent)
    recruitBadge:SetHeight(20)
    recruitBadge:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    recruitBadge:SetPoint("RIGHT", parent, "RIGHT", 0, 0)

    recruitBadge.text = recruitBadge:CreateFontString(nil, "OVERLAY")
    TrySetFont(recruitBadge.text, BODY_FONT, 10, "")
    recruitBadge.text:SetPoint("LEFT", recruitBadge, "LEFT", 0, 0)
    recruitBadge.text:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

    recruitBadge:Hide()
    return recruitBadge
end

-- ============================================================================
-- §11  UI: NOTIFICATION TOAST (new application)
-- ============================================================================
local appToast = nil

function Recruit.ShowApplicationToast(name, classFile, spec, mplus, ilvl)
    if DB and DB.settings and not DB.settings.notifyOnApply then return end

    if not appToast then
        appToast = CreateFrame("Frame", nil, UIParent)
        appToast:SetHeight(40)
        local messengerFrame = _G.MyMessengerFrame
        if messengerFrame then
            appToast:SetPoint("BOTTOMLEFT", messengerFrame, "TOPLEFT", 0, 4)
            appToast:SetPoint("BOTTOMRIGHT", messengerFrame, "TOPRIGHT", 0, 4)
        else
            appToast:SetSize(420, 40)
            appToast:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 270)
        end
        appToast:SetFrameStrata("FULLSCREEN_DIALOG")
        appToast:SetFrameLevel(500)
        appToast:SetAlpha(0)
        appToast:Hide()

        -- Drop shadow (matches M+ toast style)
        for i = 1, 4 do
            local s = appToast:CreateTexture(nil, "BACKGROUND", nil, -1)
            local off = i * 1.5
            s:SetColorTexture(0, 0, 0, 0.15 - (i * 0.03))
            s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
        end

        -- Background
        local bg = appToast:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0.04, 0.04, 0.07, 0.95)

        -- Accent top border (green gradient for applications)
        local bTop = appToast:CreateTexture(nil, "OVERLAY"); bTop:SetHeight(2)
        bTop:SetPoint("TOPLEFT"); bTop:SetPoint("TOPRIGHT")
        bTop:SetTexture(W8)
        if bTop.SetGradient and CreateColor then
            bTop:SetGradient("HORIZONTAL",
                CreateColor(0.30, 0.90, 0.30, 0.8),
                CreateColor(0.30, 0.90, 0.30, 0.0))
        end
        local bBot = appToast:CreateTexture(nil, "OVERLAY"); bBot:SetHeight(1)
        bBot:SetPoint("BOTTOMLEFT"); bBot:SetPoint("BOTTOMRIGHT")
        bBot:SetColorTexture(0.30, 0.90, 0.30, 0.2)
        local bLeft = appToast:CreateTexture(nil, "OVERLAY"); bLeft:SetWidth(1)
        bLeft:SetPoint("TOPLEFT"); bLeft:SetPoint("BOTTOMLEFT")
        bLeft:SetColorTexture(0.30, 0.90, 0.30, 0.3)
        local bRight = appToast:CreateTexture(nil, "OVERLAY"); bRight:SetWidth(1)
        bRight:SetPoint("TOPRIGHT"); bRight:SetPoint("BOTTOMRIGHT")
        bRight:SetColorTexture(0.30, 0.90, 0.30, 0.1)

        -- Icon
        local icon = appToast:CreateTexture(nil, "ARTWORK")
        icon:SetSize(22, 22); icon:SetPoint("LEFT", appToast, "LEFT", 10, 0)
        icon:SetTexture("Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        appToast._icon = icon

        -- Badge
        local badge = appToast:CreateFontString(nil, "OVERLAY")
        TrySetFont(badge, BODY_FONT, 10, "OUTLINE")
        badge:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        badge:SetText("Apply")
        badge:SetTextColor(0.30, 0.90, 0.30)
        appToast._badge = badge

        -- Title (player name + info)
        local titleFS = appToast:CreateFontString(nil, "OVERLAY")
        TrySetFont(titleFS, BODY_FONT, 11, "OUTLINE")
        titleFS:SetPoint("LEFT", badge, "RIGHT", 6, 0)
        titleFS:SetTextColor(0.94, 0.90, 0.80)
        titleFS:SetShadowColor(0, 0, 0, 0.8); titleFS:SetShadowOffset(1, -1)
        appToast._title = titleFS

        -- Review button
        local reviewBtn = CreateFrame("Button", nil, appToast)
        reviewBtn:SetSize(60, 26); reviewBtn:SetPoint("RIGHT", appToast, "RIGHT", -10, 0)
        local reviewBg = reviewBtn:CreateTexture(nil, "BACKGROUND")
        reviewBg:SetAllPoints(); reviewBg:SetColorTexture(0.15, 0.40, 0.15, 0.3)
        local reviewFS = reviewBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(reviewFS, BODY_FONT, 11, "OUTLINE"); reviewFS:SetPoint("CENTER")
        reviewFS:SetText("Review"); reviewFS:SetTextColor(0.30, 0.90, 0.30)

        local revT = reviewBtn:CreateTexture(nil, "OVERLAY"); revT:SetHeight(1)
        revT:SetPoint("TOPLEFT"); revT:SetPoint("TOPRIGHT"); revT:SetColorTexture(0.30, 0.90, 0.30, 0.3)
        local revB = reviewBtn:CreateTexture(nil, "OVERLAY"); revB:SetHeight(1)
        revB:SetPoint("BOTTOMLEFT"); revB:SetPoint("BOTTOMRIGHT"); revB:SetColorTexture(0.30, 0.90, 0.30, 0.3)
        local revL = reviewBtn:CreateTexture(nil, "OVERLAY"); revL:SetWidth(1)
        revL:SetPoint("TOPLEFT"); revL:SetPoint("BOTTOMLEFT"); revL:SetColorTexture(0.30, 0.90, 0.30, 0.3)
        local revR = reviewBtn:CreateTexture(nil, "OVERLAY"); revR:SetWidth(1)
        revR:SetPoint("TOPRIGHT"); revR:SetPoint("BOTTOMRIGHT"); revR:SetColorTexture(0.30, 0.90, 0.30, 0.3)

        reviewBtn:SetScript("OnEnter", function() reviewBg:SetColorTexture(0.20, 0.50, 0.20, 0.4) end)
        reviewBtn:SetScript("OnLeave", function() reviewBg:SetColorTexture(0.15, 0.40, 0.15, 0.3) end)
        appToast._reviewBtn = reviewBtn
    end

    -- Update content
    local r, g, b = GetClassColor(classFile)
    local displayText = "|cff" .. string.format("%02x%02x%02x", r*255, g*255, b*255) .. name .. "|r"
    if spec and spec ~= "" then displayText = displayText .. "  \194\183  " .. spec end
    if ilvl and ilvl > 0 then displayText = displayText .. "  \194\183  " .. ilvl .. " ilvl" end
    if mplus and mplus > 0 then displayText = displayText .. "  \194\183  |cff00c8ff" .. mplus .. " M+|r" end
    appToast._title:SetText(displayText)
    appToast._reviewBtn:SetScript("OnClick", function()
        appToast:Hide()
        Recruit.ShowReviewPanel()
    end)

    -- Fade in (matches M+ toast animation)
    appToast:Show()
    appToast:SetAlpha(0)
    local fadeIn = appToast:CreateAnimationGroup()
    local alphaIn = fadeIn:CreateAnimation("Alpha")
    alphaIn:SetFromAlpha(0); alphaIn:SetToAlpha(1); alphaIn:SetDuration(0.3)
    alphaIn:SetSmoothing("OUT")
    fadeIn:SetScript("OnFinished", function() appToast:SetAlpha(1) end)
    fadeIn:Play()

    if DB.settings and DB.settings.notifySound then
        pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
    end

    -- Auto-hide after 8 seconds with fade out
    C_Timer.After(8, function()
        if appToast and appToast:IsShown() then
            local fadeOut = appToast:CreateAnimationGroup()
            local alphaOut = fadeOut:CreateAnimation("Alpha")
            alphaOut:SetFromAlpha(1); alphaOut:SetToAlpha(0); alphaOut:SetDuration(0.5)
            alphaOut:SetSmoothing("IN")
            fadeOut:SetScript("OnFinished", function() appToast:Hide(); appToast:SetAlpha(0) end)
            fadeOut:Play()
        end
    end)
end

-- ============================================================================
-- §12  GUILD CHAT FALLBACK: !recruit message formatter
-- ============================================================================
function Recruit.FormatRecruitmentMessage()
    if not DB or not DB.config or not DB.config.enabled then return nil end
    local cfg = DB.config

    local guildName = ""
    if IsInGuild() then
        guildName = SafeCall(GetGuildInfo, "player") or ""
    end

    -- Build guild type tags
    local typeTags = {}
    for _, v in ipairs(cfg.guildType or {}) do
        for _, gt in ipairs(GUILD_TYPES) do
            if gt.key == v then typeTags[#typeTags + 1] = gt.label; break end
        end
    end

    -- Build role needs
    local roles = {}
    for _, rd in ipairs(ROLE_DEFS) do
        local r = cfg.roles[rd.key]
        if r and r.open then
            local pLabel = ""
            if r.priority == "HIGH" then pLabel = " (HIGH)"
            elseif r.priority == "LOW" then pLabel = " (LOW)" end

            local classNames = {}
            for _, cls in ipairs(r.classes or {}) do
                for _, def in ipairs(ALL_CLASSES) do
                    if def.file == cls then classNames[#classNames + 1] = def.name; break end
                end
            end

            local roleStr = rd.label .. pLabel
            if #classNames > 0 then
                roleStr = roleStr .. ": " .. table.concat(classNames, ", ")
            else
                roleStr = roleStr .. ": Open"
            end
            roles[#roles + 1] = roleStr
        end
    end

    if #roles == 0 then return nil end

    -- Build schedule
    local schedule = ""
    local dayLabels = {}
    for _, d in ipairs(RAID_DAYS) do
        for _, sel in ipairs(cfg.raidDays or {}) do
            if sel == d.key then dayLabels[#dayLabels + 1] = d.label; break end
        end
    end
    if #dayLabels > 0 then
        schedule = table.concat(dayLabels, "/")
        if cfg.raidTime and cfg.raidTime ~= "" then
            schedule = schedule .. " " .. cfg.raidTime
        end
        if cfg.timezone and cfg.timezone ~= "" then
            schedule = schedule .. " " .. cfg.timezone
        end
    end

    -- Assemble message
    local msg = "[MUI] " .. guildName
    if cfg.raidProgress and cfg.raidProgress ~= "" then
        msg = msg .. " (" .. cfg.raidProgress .. ")"
    end
    if cfg.realm and cfg.realm ~= "" then
        msg = msg .. " [" .. cfg.realm .. "]"
    end
    if #typeTags > 0 then
        msg = msg .. " " .. table.concat(typeTags, "/")
    end
    msg = msg .. " is recruiting! LF: " .. table.concat(roles, " | ")
    if schedule ~= "" then
        msg = msg .. " | " .. schedule
    end
    if cfg.minIlvl and cfg.minIlvl > 0 then
        msg = msg .. " | Min ilvl " .. cfg.minIlvl
    end
    msg = msg .. " | Whisper !apply"

    -- Truncate to WoW chat limit (255 chars)
    if #msg > 255 then msg = msg:sub(1, 252) .. "..." end

    return msg
end

-- ============================================================================
-- §13  SLASH COMMANDS
-- ============================================================================
SLASH_MUIRECRUIT1 = "/recruit"
SlashCmdList["MUIRECRUIT"] = function(arg)
    if not DB then return end
    local cmd = (arg or ""):lower():match("^(%S+)") or ""

    if cmd == "open" then
        if not CanManageRecruitment() then
            print("|cffff5555[Recruitment]|r You don't have permission.")
            return
        end
        DB.config.enabled = true
        DB.config.version = (DB.config.version or 0) + 1
        DB.config.lastUpdated = time()
        DB.config.updatedBy = SafeCall(UnitName, "player") or ""
        BroadcastConfig()
        Recruit.RefreshBadge()
        print("|cff40d940[Recruitment]|r Recruitment is now |cff40d940OPEN|r.")

    elseif cmd == "close" then
        if not CanManageRecruitment() then
            print("|cffff5555[Recruitment]|r You don't have permission.")
            return
        end
        DB.config.enabled = false
        DB.config.version = (DB.config.version or 0) + 1
        DB.config.lastUpdated = time()
        DB.config.updatedBy = SafeCall(UnitName, "player") or ""
        BroadcastClear()
        Recruit.RefreshBadge()
        print("|cff40d940[Recruitment]|r Recruitment is now |cffff4040CLOSED|r.")

    elseif cmd == "post" then
        if not CanManageRecruitment() then
            print("|cffff5555[Recruitment]|r You don't have permission.")
            return
        end
        local msg = Recruit.FormatRecruitmentMessage()
        if msg then
            pcall(SendChatMessage, msg, "CHANNEL", nil, GetChannelName("Trade"))
            print("|cff40d940[Recruitment]|r Posted to Trade Chat.")
        else
            print("|cffff5555[Recruitment]|r Recruitment is not configured or disabled.")
        end

    elseif cmd == "status" then
        if DB.config.enabled then
            local msg = Recruit.FormatRecruitmentMessage()
            print("|cff40d940[Recruitment]|r " .. (msg or "Enabled but no roles open"))
        else
            print("|cff40d940[Recruitment]|r Recruitment is currently |cffff4040CLOSED|r.")
        end

    elseif cmd == "config" then
        Recruit.ShowConfigOverlay()

    elseif cmd == "review" then
        Recruit.ShowReviewPanel()

    elseif cmd == "apply" then
        Recruit.ShowApplicationForm()

    elseif cmd == "find" or cmd == "finder" or cmd == "browse" then
        Recruit.ShowGuildFinder()

    else
        -- Default: toggle review panel if officer, config if GM, or show guild finder
        if CanManageRecruitment() then
            Recruit.ShowConfigOverlay()
        else
            Recruit.ShowGuildFinder()
        end
    end
end

-- ============================================================================
-- §19  FIND A GUILD PANEL (cross-guild discovery browser)
-- ============================================================================
local guildFinderPanel = nil
local finderState = {
    rows = {},
    filterFaction = nil,    -- nil = all, "Alliance", "Horde"
    filterType = nil,       -- nil = all, "RAID", "MYTHICPLUS", etc.
    filterRole = nil,       -- nil = all, "TANK", "HEALER", "DPS"
    searchText = "",
}

function Recruit.RefreshGuildFinder()
    if not guildFinderPanel or not guildFinderPanel:IsShown() then return end
    if not DB or not DB.listings then return end
    local C = GetThemeColors()

    -- Clear old rows
    for _, row in ipairs(finderState.rows) do row:Hide(); row:SetParent(nil) end
    finderState.rows = {}

    -- Collect and filter listings
    local listings = {}
    for key, listing in pairs(DB.listings) do
        local dominated = false

        -- Faction filter
        if finderState.filterFaction and listing.faction ~= finderState.filterFaction then dominated = true end

        -- Type filter
        if finderState.filterType and not dominated then
            local found = false
            for _, gt in ipairs(listing.guildType or {}) do
                if gt == finderState.filterType then found = true; break end
            end
            if not found then dominated = true end
        end

        -- Role filter
        if finderState.filterRole and not dominated then
            local r = listing.roles and listing.roles[finderState.filterRole]
            if not r or not r.open then dominated = true end
        end

        -- Search text
        if finderState.searchText ~= "" and not dominated then
            local lower = finderState.searchText:lower()
            local haystack = ((listing.guildName or "") .. " " .. (listing.realm or "") .. " " .. (listing.description or "")):lower()
            if not haystack:find(lower, 1, true) then dominated = true end
        end

        if not dominated then
            listing._key = key
            listings[#listings + 1] = listing
        end
    end

    -- Sort by receivedAt (newest first)
    table.sort(listings, function(a, b) return (a.receivedAt or 0) > (b.receivedAt or 0) end)

    local content = guildFinderPanel._content
    local PAD = 14
    local yOfs = -PAD

    -- Count display
    if guildFinderPanel._countFS then
        guildFinderPanel._countFS:SetText(#listings .. " guilds found")
    end

    if #listings == 0 then
        local emptyFS = content:CreateFontString(nil, "OVERLAY")
        TrySetFont(emptyFS, BODY_FONT, 12, "")
        emptyFS:SetPoint("TOP", content, "TOP", 0, -40)
        emptyFS:SetText("No guild listings received yet.\nListings appear as MidnightUI users\nbroadcast their recruitment.")
        emptyFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
        emptyFS:SetJustifyH("CENTER")

        local holder = CreateFrame("Frame", nil, content)
        holder:SetSize(1, 1); holder:SetPoint("CENTER")
        holder:SetScript("OnHide", function() emptyFS:Hide() end)
        finderState.rows[1] = holder
        content:SetHeight(120)
        return
    end

    for _, listing in ipairs(listings) do
        -- ── Guild Listing Card ──
        local card = CreateFrame("Frame", nil, content, "BackdropTemplate")
        card:SetHeight(90)
        card:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, yOfs)
        card:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
        card:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        card:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.4)
        card:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.12)

        -- Faction accent bar
        local fBar = card:CreateTexture(nil, "OVERLAY")
        fBar:SetWidth(3); fBar:SetPoint("TOPLEFT", 1, -1); fBar:SetPoint("BOTTOMLEFT", 1, 1)
        if listing.faction == "Alliance" then
            fBar:SetColorTexture(0.2, 0.4, 1.0, 0.6)
        elseif listing.faction == "Horde" then
            fBar:SetColorTexture(1.0, 0.2, 0.2, 0.6)
        else
            fBar:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.3)
        end

        -- Guild name
        local nameFS = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFS, BODY_FONT, 14, "OUTLINE")
        nameFS:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -8)
        nameFS:SetText(listing.guildName or "Unknown")
        nameFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

        -- Realm + Progress
        local metaFS = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(metaFS, BODY_FONT, 10, "")
        metaFS:SetPoint("LEFT", nameFS, "RIGHT", 8, 0)
        local metaText = "|cffaaaaaa" .. (listing.realm or "") .. "|r"
        if listing.raidProgress and listing.raidProgress ~= "" then
            metaText = metaText .. "  |cffffcc00" .. listing.raidProgress .. "|r"
        end
        metaFS:SetText(metaText)

        -- Guild type tags
        local tagStr = ""
        for _, gt in ipairs(listing.guildType or {}) do
            for _, def in ipairs(GUILD_TYPES) do
                if def.key == gt then tagStr = tagStr .. " " .. def.label; break end
            end
        end
        if tagStr ~= "" then
            local tagFS = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(tagFS, BODY_FONT, 9, "")
            tagFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -10)
            tagFS:SetText(tagStr:sub(2))
            tagFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3], 0.7)
        end

        -- Row 2: Roles needed
        local rolesStr = ""
        for _, rd in ipairs(ROLE_DEFS) do
            local r = listing.roles and listing.roles[rd.key]
            if r and r.open then
                local pc = PRIORITY_COLORS[r.priority] or PRIORITY_COLORS.LOW
                local colorHex = string.format("%02x%02x%02x", pc[1]*255, pc[2]*255, pc[3]*255)
                rolesStr = rolesStr .. "  |cff" .. colorHex .. rd.label .. "|r"
            end
        end
        if rolesStr ~= "" then
            local rolesFS = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(rolesFS, BODY_FONT, 11, "")
            rolesFS:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -28)
            rolesFS:SetText("LF:" .. rolesStr)
            rolesFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        end

        -- Row 3: Schedule
        local schedStr = ""
        if listing.raidDays and #listing.raidDays > 0 then
            local dayLabels = {}
            for _, d in ipairs(RAID_DAYS) do
                for _, sel in ipairs(listing.raidDays) do
                    if sel == d.key then dayLabels[#dayLabels + 1] = d.label; break end
                end
            end
            schedStr = table.concat(dayLabels, "/")
            if listing.raidTime and listing.raidTime ~= "" then
                schedStr = schedStr .. " " .. listing.raidTime
            end
            if listing.timezone and listing.timezone ~= "" then
                schedStr = schedStr .. " " .. listing.timezone
            end
        end
        if schedStr ~= "" then
            local schedFS = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(schedFS, BODY_FONT, 10, "")
            schedFS:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -46)
            schedFS:SetText(schedStr)
            schedFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
        end

        -- Description (truncated)
        if listing.description and listing.description ~= "" then
            local descFS = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(descFS, BODY_FONT, 9, "")
            descFS:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -62)
            descFS:SetPoint("RIGHT", card, "RIGHT", -90, 0)
            local desc = listing.description
            if #desc > 80 then desc = desc:sub(1, 77) .. "..." end
            descFS:SetText(desc)
            descFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.6)
        end

        -- Apply button
        local applyBtn = CreateFrame("Button", nil, card)
        applyBtn:SetSize(70, 26); applyBtn:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -10, 8)
        local applyBg = applyBtn:CreateTexture(nil, "BACKGROUND"); applyBg:SetAllPoints()
        applyBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
        local applyFS = applyBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(applyFS, BODY_FONT, 11, "OUTLINE"); applyFS:SetPoint("CENTER")
        applyFS:SetText("Apply"); applyFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
        -- Border
        for _, edge in ipairs({
            { "TOPLEFT", "TOPRIGHT", true }, { "BOTTOMLEFT", "BOTTOMRIGHT", true },
            { "TOPLEFT", "BOTTOMLEFT", false }, { "TOPRIGHT", "BOTTOMRIGHT", false }
        }) do
            local b = applyBtn:CreateTexture(nil, "OVERLAY")
            if edge[3] then b:SetHeight(1) else b:SetWidth(1) end
            b:SetPoint(edge[1]); b:SetPoint(edge[2])
            b:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.25)
        end
        applyBtn:SetScript("OnEnter", function() applyBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.35) end)
        applyBtn:SetScript("OnLeave", function() applyBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2) end)

        local capturedSender = listing.sender
        local capturedGuild = listing.guildName
        local capturedListing = listing
        applyBtn:SetScript("OnClick", function()
            local dbg = _G.MidnightUI_Debug or print
            dbg("|cff00c8ff[Recruit Apply]|r Clicked Apply for: " .. (capturedGuild or "nil") .. " | Sender: " .. (capturedSender or "nil"))
            dbg("|cff00c8ff[Recruit Apply]|r Listing realm: " .. (capturedListing and capturedListing.realm or "nil") .. " | Faction: " .. (capturedListing and capturedListing.faction or "nil"))
            dbg("|cff00c8ff[Recruit Apply]|r Calling ShowApplicationForm...")
            local ok, err = pcall(Recruit.ShowApplicationForm, {
                guildName = capturedGuild,
                sender = capturedSender,
                listing = capturedListing,
            })
            if not ok then
                dbg("|cffff5555[Recruit Apply]|r ERROR: " .. tostring(err))
            else
                dbg("|cff40d940[Recruit Apply]|r Form opened successfully")
            end
        end)

        card:Show()
        finderState.rows[#finderState.rows + 1] = card
        yOfs = yOfs - 98
    end

    content:SetHeight(math.abs(yOfs) + PAD)
end

function Recruit.ShowGuildFinder()
    local C = GetThemeColors()

    if guildFinderPanel and guildFinderPanel:IsShown() then
        guildFinderPanel:Hide()
        return
    end

    if guildFinderPanel then
        Recruit.RefreshGuildFinder()
        guildFinderPanel:Show()
        return
    end

    local PAD = 16
    local OVL_W, OVL_H = 620, 700

    guildFinderPanel = CreateFrame("Frame", "MidnightUI_GuildFinder", UIParent, "BackdropTemplate")
    guildFinderPanel:SetSize(OVL_W, OVL_H)
    guildFinderPanel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    guildFinderPanel:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    guildFinderPanel:SetBackdropColor(0.020, 0.022, 0.038, 0.98)
    guildFinderPanel:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.18)
    guildFinderPanel:SetFrameStrata("HIGH")
    guildFinderPanel:SetFrameLevel(200)
    guildFinderPanel:EnableMouse(true); guildFinderPanel:SetMovable(true); guildFinderPanel:SetClampedToScreen(true)

    -- Drop shadow
    for i = 1, 8 do
        local s = guildFinderPanel:CreateTexture(nil, "BACKGROUND", nil, -1)
        local off = i * 2.5
        s:SetColorTexture(0, 0, 0, 0.22 - (i * 0.024))
        s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
    end

    -- Top accent bar
    local topBar = guildFinderPanel:CreateTexture(nil, "OVERLAY", nil, 4)
    topBar:SetHeight(3); topBar:SetPoint("TOPLEFT", 1, -1); topBar:SetPoint("TOPRIGHT", -1, -1)
    topBar:SetTexture(W8)
    if topBar.SetGradient and CreateColor then
        topBar:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.9),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.1))
    end

    -- Ambient glow
    local ambGlow = guildFinderPanel:CreateTexture(nil, "BACKGROUND", nil, 1)
    ambGlow:SetHeight(80); ambGlow:SetPoint("TOPLEFT", 1, -4); ambGlow:SetPoint("TOPRIGHT", -1, -4)
    ambGlow:SetTexture(W8)
    if ambGlow.SetGradient and CreateColor then
        ambGlow:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.06))
    end

    -- ── Header (draggable) ──
    local headerBar = CreateFrame("Frame", nil, guildFinderPanel)
    headerBar:SetHeight(48); headerBar:SetPoint("TOPLEFT", 0, 0); headerBar:SetPoint("TOPRIGHT", 0, 0)
    headerBar:EnableMouse(true); headerBar:RegisterForDrag("LeftButton")
    headerBar:SetScript("OnDragStart", function() guildFinderPanel:StartMoving() end)
    headerBar:SetScript("OnDragStop", function() guildFinderPanel:StopMovingOrSizing() end)

    local hdrLine = headerBar:CreateTexture(nil, "OVERLAY")
    hdrLine:SetHeight(1); hdrLine:SetPoint("BOTTOMLEFT", 1, 0); hdrLine:SetPoint("BOTTOMRIGHT", -1, 0)
    hdrLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.15)

    local titleFS = headerBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(titleFS, TITLE_FONT, 18, "OUTLINE")
    titleFS:SetPoint("LEFT", headerBar, "LEFT", PAD, 0)
    titleFS:SetText("Find a Guild")
    titleFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    titleFS:SetShadowColor(0, 0, 0, 0.6); titleFS:SetShadowOffset(1, -1)

    local closeBtn = CreateFrame("Button", nil, headerBar)
    closeBtn:SetSize(28, 28); closeBtn:SetPoint("RIGHT", headerBar, "RIGHT", -10, 0)
    local closeTx = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeTx, TITLE_FONT, 16, "OUTLINE"); closeTx:SetPoint("CENTER"); closeTx:SetText("X")
    closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)
    closeBtn:SetScript("OnEnter", function() closeTx:SetTextColor(1, 0.35, 0.35) end)
    closeBtn:SetScript("OnLeave", function() closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5) end)
    closeBtn:SetScript("OnClick", function() guildFinderPanel:Hide() end)

    -- ── Filter Bar ──
    local filterBar = CreateFrame("Frame", nil, guildFinderPanel)
    filterBar:SetHeight(36); filterBar:SetPoint("TOPLEFT", guildFinderPanel, "TOPLEFT", 0, -48)
    filterBar:SetPoint("TOPRIGHT", guildFinderPanel, "TOPRIGHT", 0, -48)

    local filterLine = filterBar:CreateTexture(nil, "OVERLAY")
    filterLine:SetHeight(1); filterLine:SetPoint("BOTTOMLEFT", 1, 0); filterLine:SetPoint("BOTTOMRIGHT", -1, 0)
    filterLine:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.1)

    -- Search box
    local searchBox = CreateFrame("EditBox", nil, filterBar, "BackdropTemplate")
    searchBox:SetSize(150, 22)
    searchBox:SetPoint("LEFT", filterBar, "LEFT", PAD, 0)
    searchBox:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    searchBox:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], 0.7)
    searchBox:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.2)
    searchBox:SetAutoFocus(false); searchBox:SetMaxLetters(40)
    TrySetFont(searchBox, BODY_FONT, 10, "")
    searchBox:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    searchBox:SetTextInsets(6, 6, 0, 0)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        finderState.searchText = self:GetText() or ""
        Recruit.RefreshGuildFinder()
    end)

    -- Search placeholder
    local searchPH = searchBox:CreateFontString(nil, "OVERLAY")
    TrySetFont(searchPH, BODY_FONT, 10, ""); searchPH:SetPoint("LEFT", 6, 0)
    searchPH:SetText("Search guilds..."); searchPH:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.4)
    searchBox:SetScript("OnEditFocusGained", function() searchPH:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function(self) if (self:GetText() or "") == "" then searchPH:Show() end end)
    searchBox:HookScript("OnTextChanged", function(self) if (self:GetText() or "") ~= "" then searchPH:Hide() else searchPH:Show() end end)

    -- Filter buttons helper
    local function MakeFilterBtn(parentFrame, x, label, filterKey, filterValue)
        local btn = CreateFrame("Button", nil, parentFrame)
        btn:SetSize(58, 20); btn:SetPoint("LEFT", parentFrame, "LEFT", x, 0)
        local bg = btn:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints()
        bg:SetColorTexture(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.3)
        local fs = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(fs, BODY_FONT, 9, "OUTLINE"); fs:SetPoint("CENTER"); fs:SetText(label)
        fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        btn:SetScript("OnClick", function()
            if finderState[filterKey] == filterValue then
                finderState[filterKey] = nil
            else
                finderState[filterKey] = filterValue
            end
            Recruit.RefreshGuildFinder()
        end)

        return { btn = btn, bg = bg, fs = fs, value = filterValue, key = filterKey }
    end

    -- Role filters
    guildFinderPanel._filterBtns = {}
    local fBtns = guildFinderPanel._filterBtns
    fBtns[#fBtns+1] = MakeFilterBtn(filterBar, 180, "Tank", "filterRole", "TANK")
    fBtns[#fBtns+1] = MakeFilterBtn(filterBar, 242, "Healer", "filterRole", "HEALER")
    fBtns[#fBtns+1] = MakeFilterBtn(filterBar, 304, "DPS", "filterRole", "DPS")

    -- Type filters
    fBtns[#fBtns+1] = MakeFilterBtn(filterBar, 376, "Raid", "filterType", "RAID")
    fBtns[#fBtns+1] = MakeFilterBtn(filterBar, 438, "M+", "filterType", "MYTHICPLUS")
    fBtns[#fBtns+1] = MakeFilterBtn(filterBar, 500, "PvP", "filterType", "PVP")

    -- Count display
    local countFS = guildFinderPanel:CreateFontString(nil, "OVERLAY")
    TrySetFont(countFS, BODY_FONT, 9, "")
    countFS:SetPoint("RIGHT", filterBar, "RIGHT", -PAD, 0)
    countFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
    guildFinderPanel._countFS = countFS

    -- ── Scrollable content ──
    local scroll = CreateFrame("ScrollFrame", nil, guildFinderPanel, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", guildFinderPanel, "TOPLEFT", 1, -86)
    scroll:SetPoint("BOTTOMRIGHT", guildFinderPanel, "BOTTOMRIGHT", -20, 4)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetWidth(OVL_W - 22)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    scroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then content:SetWidth(w) end end)
    if scroll.ScrollBar then
        local sb = scroll.ScrollBar
        if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.15); sb.ThumbTexture:SetWidth(3) end
        if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
        if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
    end

    guildFinderPanel._content = content
    guildFinderPanel._scroll = scroll

    -- Register for ESC to close
    tinsert(UISpecialFrames, "MidnightUI_GuildFinder")
    guildFinderPanel:SetScript("OnShow", function()
        -- Refresh filter button visuals
        for _, fb in ipairs(guildFinderPanel._filterBtns) do
            if finderState[fb.key] == fb.value then
                fb.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
                fb.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            else
                fb.bg:SetColorTexture(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.3)
                fb.fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
            end
        end
        Recruit.RefreshGuildFinder()
    end)

    -- Also refresh filter visuals on filter click
    local origRefresh = Recruit.RefreshGuildFinder
    Recruit.RefreshGuildFinder = function()
        if guildFinderPanel and guildFinderPanel._filterBtns then
            for _, fb in ipairs(guildFinderPanel._filterBtns) do
                if finderState[fb.key] == fb.value then
                    fb.bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
                    fb.fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
                else
                    fb.bg:SetColorTexture(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.3)
                    fb.fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
                end
            end
        end
        origRefresh()
    end

    Recruit.RefreshGuildFinder()
    guildFinderPanel:Show()
end

-- /guildfinder slash command
SLASH_MUIGUILDFINDER1 = "/guildfinder"
SLASH_MUIGUILDFINDER2 = "/gf"
SlashCmdList["MUIGUILDFINDER"] = function()
    Recruit.ShowGuildFinder()
end

-- ============================================================================
-- §20  ROSTER CACHE (tracks guild members for departure detection)
-- ============================================================================
local rosterCache = {}          -- current: { ["Name-Realm"] = { name, realm, class, rank, officerNote, level } }
local previousRosterCache = {}  -- previous snapshot for diffing

local function RefreshRosterCache()
    previousRosterCache = rosterCache
    rosterCache = {}
    local numMembers = SafeCall(GetNumGuildMembers) or 0
    for i = 1, numMembers do
        local gName, rankName, rankIndex, level, _, _, publicNote, officerNote, _, _, classFile, _, _, _, _, _, guid =
            SafeCall(GetGuildRosterInfo, i)
        if gName and classFile then
            local shortName = gName:match("^([^%-]+)") or gName
            rosterCache[gName] = {
                name = shortName,
                fullName = gName,
                realm = gName:match("%-(.+)$") or (SafeCall(GetRealmName) or ""),
                class = classFile,
                rank = rankName or "",
                rankIndex = rankIndex or 99,
                officerNote = officerNote or "",
                publicNote = publicNote or "",
                level = level or 0,
            }
        end
    end
end

-- Guild member set for quick lookups (short names)
local function IsGuildMember(shortName)
    for _, data in pairs(rosterCache) do
        if data.name == shortName then return true end
    end
    return false
end

-- ============================================================================
-- §21  MEMBER DOSSIER SYSTEM (institutional memory)
-- ============================================================================
local function CreateDossier(name, realm, leftHow, removedBy)
    if not DB or not DB.dossiers then return end
    local key = name .. "-" .. (realm or "")
    if key == name .. "-" then key = name end

    -- Look up class from previous roster cache or MessengerDB
    local classFile = ""
    for _, data in pairs(previousRosterCache) do
        if data.name == name then
            classFile = data.class or ""
            break
        end
    end
    if classFile == "" and _G.MessengerDB and _G.MessengerDB.ContactClasses then
        classFile = _G.MessengerDB.ContactClasses[name] or ""
    end

    -- Capture officer note from previous cache (before roster update removed them)
    local officerNote = ""
    for _, data in pairs(previousRosterCache) do
        if data.name == name then
            officerNote = data.officerNote or ""
            break
        end
    end

    -- Check if dossier already exists (returning leaver)
    local existing = DB.dossiers[key]
    if existing then
        -- Append to encounters log
        existing.encounters = existing.encounters or {}
        existing.encounters[#existing.encounters + 1] = { date = time(), action = leftHow or "left" }
        existing.leftAt = time()
        existing.leftHow = leftHow or "left"
        existing.removedBy = removedBy or ""
        existing.officerNote = officerNote
        existing.class = classFile ~= "" and classFile or existing.class
    else
        -- Look up application history
        local appHistory = DB.history and DB.history[key]
        local appNotes = {}
        if appHistory and appHistory.officerNotes then
            for _, note in ipairs(appHistory.officerNotes) do
                appNotes[#appNotes + 1] = { officer = note.officer, note = note.note, time = note.time }
            end
        end

        DB.dossiers[key] = {
            name = name,
            realm = realm or "",
            class = classFile,
            joinedAt = 0,  -- unknown unless tracked
            leftAt = time(),
            leftHow = leftHow or "left",
            removedBy = removedBy or "",
            officerNote = officerNote,
            appOfficerNotes = appNotes,
            departureReason = "",
            encounters = { { date = time(), action = leftHow or "left" } },
        }
    end
end

local function CheckDossierOnApply(appName, appRealm)
    if not DB or not DB.dossiers then return nil end
    local key = appName .. "-" .. (appRealm or "")
    if DB.dossiers[key] then return DB.dossiers[key] end
    -- Try name-only match (cross-realm)
    for dk, dv in pairs(DB.dossiers) do
        if dv.name == appName then return dv end
    end
    return nil
end

-- Dossier toast (orange accent for returning players)
function Recruit.ShowDossierToast(name, dossier)
    if not dossier then return end

    local toastFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    toastFrame:SetHeight(55)
    local messengerFrame = _G.MyMessengerFrame
    if messengerFrame then
        toastFrame:SetPoint("BOTTOMLEFT", messengerFrame, "TOPLEFT", 0, 55)
        toastFrame:SetPoint("BOTTOMRIGHT", messengerFrame, "TOPRIGHT", 0, 55)
    else
        toastFrame:SetSize(450, 55)
        toastFrame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 280)
    end
    toastFrame:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    toastFrame:SetBackdropColor(0.04, 0.03, 0.02, 0.95)
    toastFrame:SetBackdropBorderColor(1.0, 0.65, 0.15, 0.3)
    toastFrame:SetFrameStrata("FULLSCREEN_DIALOG"); toastFrame:SetFrameLevel(500)

    -- Orange accent bar
    local accent = toastFrame:CreateTexture(nil, "OVERLAY")
    accent:SetHeight(2); accent:SetPoint("TOPLEFT"); accent:SetPoint("TOPRIGHT")
    accent:SetColorTexture(1.0, 0.65, 0.15, 0.6)

    -- Icon
    local icon = toastFrame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22); icon:SetPoint("LEFT", toastFrame, "LEFT", 10, 0)
    icon:SetTexture("Interface\\Icons\\INV_Misc_Book_09")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Info text
    local infoFS = toastFrame:CreateFontString(nil, "OVERLAY")
    TrySetFont(infoFS, BODY_FONT, 11, "")
    infoFS:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -2)
    infoFS:SetPoint("RIGHT", toastFrame, "RIGHT", -80, 0)
    infoFS:SetWordWrap(true)

    local howText = dossier.leftHow == "removed" and "was removed" or dossier.leftHow == "kicked" and "was kicked" or "left"
    local dateText = dossier.leftAt and dossier.leftAt > 0 and date("%b %d, %Y", dossier.leftAt) or "unknown date"
    local reasonText = (dossier.departureReason and dossier.departureReason ~= "") and (" Reason: " .. dossier.departureReason) or ""

    infoFS:SetText("|cffffaa00Returning Player:|r " .. name .. " " .. howText .. " on " .. dateText .. "." .. reasonText)
    infoFS:SetTextColor(0.90, 0.85, 0.75)

    -- Review button
    local reviewBtn = CreateFrame("Button", nil, toastFrame)
    reviewBtn:SetSize(60, 26); reviewBtn:SetPoint("RIGHT", toastFrame, "RIGHT", -10, 0)
    local reviewBg = reviewBtn:CreateTexture(nil, "BACKGROUND"); reviewBg:SetAllPoints()
    reviewBg:SetColorTexture(1.0, 0.65, 0.15, 0.2)
    local reviewFS = reviewBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(reviewFS, BODY_FONT, 10, "OUTLINE"); reviewFS:SetPoint("CENTER")
    reviewFS:SetText("Review"); reviewFS:SetTextColor(1.0, 0.65, 0.15)
    reviewBtn:SetScript("OnClick", function() toastFrame:Hide(); Recruit.ShowConfigOverlay() end)
    reviewBtn:SetScript("OnEnter", function() reviewBg:SetColorTexture(1.0, 0.65, 0.15, 0.35) end)
    reviewBtn:SetScript("OnLeave", function() reviewBg:SetColorTexture(1.0, 0.65, 0.15, 0.2) end)

    toastFrame:Show()
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
    C_Timer.After(12, function() if toastFrame then toastFrame:Hide() end end)
end

-- ============================================================================
-- §22  MESSAGE TEMPLATES (placeholder substitution)
-- ============================================================================
local function ApplyTemplatePlaceholders(templateText, targetPlayer)
    local guildName = ""
    if IsInGuild() then guildName = SafeCall(GetGuildInfo, "player") or "" end
    local progress = (DB and DB.config and DB.config.raidProgress) or ""
    local schedule = ""
    if DB and DB.config then
        local dayLabels = {}
        for _, d in ipairs(RAID_DAYS) do
            for _, sel in ipairs(DB.config.raidDays or {}) do
                if sel == d.key then dayLabels[#dayLabels + 1] = d.label; break end
            end
        end
        if #dayLabels > 0 then
            schedule = table.concat(dayLabels, "/")
            if DB.config.raidTime and DB.config.raidTime ~= "" then
                schedule = schedule .. " " .. DB.config.raidTime
            end
            if DB.config.timezone and DB.config.timezone ~= "" then
                schedule = schedule .. " " .. DB.config.timezone
            end
        end
    end

    local result = templateText
    result = result:gsub("{player}", targetPlayer or "")
    result = result:gsub("{guild}", guildName)
    result = result:gsub("{progress}", progress)
    result = result:gsub("{schedule}", schedule)
    return result
end

function Recruit.GetTemplate(category)
    if not DB or not DB.config or not DB.config.templates then return nil end
    for name, tmpl in pairs(DB.config.templates) do
        if tmpl.category == category and tmpl.text and tmpl.text ~= "" then
            return tmpl
        end
    end
    return nil
end

function Recruit.SendTemplate(category, targetPlayer, chatType, chatTarget)
    local tmpl = Recruit.GetTemplate(category)
    if not tmpl then return false end
    local filled = ApplyTemplatePlaceholders(tmpl.text, targetPlayer)
    if #filled > 255 then filled = filled:sub(1, 252) .. "..." end
    pcall(SendChatMessage, filled, chatType or "WHISPER", nil, chatTarget or targetPlayer)
    return true
end

-- ============================================================================
-- §23  PROSPECT RADAR (passive LFG channel scanner)
-- ============================================================================
local PROSPECT_PATTERNS = {
    "looking for[%s%a]*guild",
    "lfg guild", "lf guild", "lf a guild",
    "any guilds recruiting", "guilds recruiting",
    "returning player looking for",
    "coming back to wow",
    "lf raid team", "lf mythic team", "lf raiding guild",
    "need a guild", "want to join a guild",
    "any good guilds", "guild recommendations",
    "lf[%s]+m%+ guild", "lf[%s]+pvp guild",
}

local prospectCooldowns = {}  -- { ["PlayerName"] = lastAlertTimestamp }

local function ScanForProspect(message, sender, channelName)
    if not DB or not DB.config or not DB.config.enabled then return end
    if not DB.config.prospectRadar then return end
    if not CanManageRecruitment() then return end

    local shortSender = sender and sender:match("^([^%-]+)") or sender or ""
    if shortSender == "" then return end

    -- Skip guild members
    if IsGuildMember(shortSender) then return end

    -- Skip self
    local playerName = SafeCall(UnitName, "player") or ""
    if shortSender == playerName then return end

    -- Cooldown check
    local now = time()
    local cooldown = (DB.settings and DB.settings.prospectCooldown) or 600
    if prospectCooldowns[shortSender] and (now - prospectCooldowns[shortSender]) < cooldown then return end

    -- Pattern matching
    local lower = message:lower()
    local matched = false
    for _, pattern in ipairs(PROSPECT_PATTERNS) do
        if lower:find(pattern) then matched = true; break end
    end
    if not matched then return end

    prospectCooldowns[shortSender] = now

    -- Show prospect toast
    local snippet = #message > 60 and (message:sub(1, 57) .. "...") or message
    Recruit.ShowProspectToast(shortSender, snippet, channelName)
end

function Recruit.ShowProspectToast(senderName, snippet, channelName)
    local C = GetThemeColors()

    local toastFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    toastFrame:SetHeight(50)
    local messengerFrame = _G.MyMessengerFrame
    if messengerFrame then
        toastFrame:SetPoint("BOTTOMLEFT", messengerFrame, "TOPLEFT", 0, 4)
        toastFrame:SetPoint("BOTTOMRIGHT", messengerFrame, "TOPRIGHT", 0, 4)
    else
        toastFrame:SetSize(450, 50)
        toastFrame:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 230)
    end
    toastFrame:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    toastFrame:SetBackdropColor(0.03, 0.04, 0.08, 0.95)
    toastFrame:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)
    toastFrame:SetFrameStrata("FULLSCREEN_DIALOG"); toastFrame:SetFrameLevel(500)

    -- Blue accent bar
    local accent = toastFrame:CreateTexture(nil, "OVERLAY")
    accent:SetHeight(2); accent:SetPoint("TOPLEFT"); accent:SetPoint("TOPRIGHT")
    accent:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.5)

    -- Icon
    local icon = toastFrame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22); icon:SetPoint("LEFT", toastFrame, "LEFT", 10, 0)
    icon:SetTexture("Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    -- Info text
    local infoFS = toastFrame:CreateFontString(nil, "OVERLAY")
    TrySetFont(infoFS, BODY_FONT, 10, "")
    infoFS:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -2)
    infoFS:SetPoint("RIGHT", toastFrame, "RIGHT", -140, 0)
    infoFS:SetWordWrap(true)
    infoFS:SetText("|cff00c8ffProspect:|r |cffffff00" .. senderName .. "|r in " .. (channelName or "Chat") .. "\n|cffaaaaaa\"" .. snippet .. "\"|r")
    infoFS:SetTextColor(0.85, 0.87, 0.90)

    -- Whisper button
    local whisperBtn = CreateFrame("Button", nil, toastFrame)
    whisperBtn:SetSize(65, 26); whisperBtn:SetPoint("RIGHT", toastFrame, "RIGHT", -75, 0)
    local whisperBg = whisperBtn:CreateTexture(nil, "BACKGROUND"); whisperBg:SetAllPoints()
    whisperBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2)
    local whisperFS = whisperBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(whisperFS, BODY_FONT, 10, "OUTLINE"); whisperFS:SetPoint("CENTER")
    whisperFS:SetText("Whisper"); whisperFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    whisperBtn:SetScript("OnEnter", function() whisperBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.35) end)
    whisperBtn:SetScript("OnLeave", function() whisperBg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.2) end)

    local capturedName = senderName
    whisperBtn:SetScript("OnClick", function()
        -- Try to use a prospect template
        if not Recruit.SendTemplate("prospect", capturedName, "WHISPER", capturedName) then
            -- No template — open default whisper
            if ChatFrame_SendTell then
                pcall(ChatFrame_SendTell, capturedName)
            end
        end
        toastFrame:Hide()
    end)

    -- Dismiss button
    local dismissBtn = CreateFrame("Button", nil, toastFrame)
    dismissBtn:SetSize(55, 26); dismissBtn:SetPoint("RIGHT", toastFrame, "RIGHT", -8, 0)
    local dismissFS = dismissBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(dismissFS, BODY_FONT, 10, ""); dismissFS:SetPoint("CENTER")
    dismissFS:SetText("Dismiss"); dismissFS:SetTextColor(0.5, 0.5, 0.5, 0.6)
    dismissBtn:SetScript("OnClick", function() toastFrame:Hide() end)
    dismissBtn:SetScript("OnEnter", function() dismissFS:SetTextColor(1, 0.3, 0.3) end)
    dismissBtn:SetScript("OnLeave", function() dismissFS:SetTextColor(0.5, 0.5, 0.5, 0.6) end)

    toastFrame:Show()
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
    C_Timer.After(12, function() if toastFrame then toastFrame:Hide() end end)
end

-- ============================================================================
-- §24  AUTO-WELCOME (randomized welcome on guild join)
-- ============================================================================
local lastWelcomeTime = 0
local lastWelcomeIndices = {}  -- track last 3 indices to avoid repeats

local function PickWelcomeMessage()
    if not DB or not DB.config then return nil end
    local pool = DB.config.welcomeMessages or {}
    local available = {}
    for i, msg in ipairs(pool) do
        if msg and msg ~= "" and not lastWelcomeIndices[i] then
            available[#available + 1] = i
        end
    end
    if #available == 0 then
        -- Reset tracking and try again
        lastWelcomeIndices = {}
        for i, msg in ipairs(pool) do
            if msg and msg ~= "" then available[#available + 1] = i end
        end
    end
    if #available == 0 then return nil end
    local pick = available[math.random(1, #available)]
    lastWelcomeIndices[pick] = true
    -- Keep only 3 tracked
    local count = 0
    for _ in pairs(lastWelcomeIndices) do count = count + 1 end
    if count > 3 then
        for k in pairs(lastWelcomeIndices) do
            lastWelcomeIndices[k] = nil
            break
        end
    end
    return pool[pick]
end

local function OnGuildJoinDetected(playerName)
    if not DB or not DB.config or not DB.config.autoWelcome then return end
    if not CanManageRecruitment() then return end

    -- Cooldown
    local now = time()
    local cooldown = (DB.settings and DB.settings.welcomeCooldown) or 30
    if now - lastWelcomeTime < cooldown then return end

    -- Don't welcome yourself
    local myName = SafeCall(UnitName, "player") or ""
    if playerName == myName then return end

    lastWelcomeTime = now

    C_Timer.After(2, function()
        local msg = PickWelcomeMessage()
        if msg then
            msg = ApplyTemplatePlaceholders(msg, playerName)
            if #msg > 255 then msg = msg:sub(1, 252) .. "..." end
            pcall(SendChatMessage, msg, "GUILD")
        end
    end)
end

-- ============================================================================
-- §25  RAIDERIO ENRICHMENT (snapshot on application receive)
-- ============================================================================
local function EnrichWithRaiderIO(app)
    if not _G.RaiderIO then return end
    local ok, profile = pcall(function()
        return RaiderIO.GetProfile(app.name, app.realm)
    end)
    if not ok or not profile then return end

    app.raiderIO = {
        snapshotAt = time(),
    }

    pcall(function()
        if profile.mythicKeystoneProfile then
            app.raiderIO.mplusScore = profile.mythicKeystoneProfile.currentScore or 0
            if profile.mythicKeystoneProfile.sortedDungeons and profile.mythicKeystoneProfile.sortedDungeons[1] then
                app.raiderIO.highestKey = profile.mythicKeystoneProfile.sortedDungeons[1].level or 0
            end
        end
        if profile.raidProfile and profile.raidProfile.progress then
            for _, raid in ipairs(profile.raidProfile.progress) do
                if raid.raid and (raid.raid:lower():find("undermine") or raid.raid:lower():find("nerub")) then
                    app.raiderIO.raidProgress = ""
                    for _, diff in ipairs(raid.progress or {}) do
                        if diff.difficulty == 3 then -- Mythic
                            app.raiderIO.raidProgress = diff.kills .. "/" .. diff.total .. "M"
                        elseif diff.difficulty == 2 and not app.raiderIO.raidProgress:find("M") then -- Heroic
                            app.raiderIO.raidProgress = diff.kills .. "/" .. diff.total .. "H"
                        end
                    end
                    break
                end
            end
        end
    end)
end

-- ============================================================================
-- §26  WHISPER CONTEXT (MessengerDB lookup for applications)
-- ============================================================================
local function GetWhisperHistory(playerName)
    if not _G.MessengerDB then return nil end
    local directBucket = MessengerDB.History and MessengerDB.History["Direct"]
    if not directBucket or not directBucket.messages then return nil end

    local matches = {}
    local lowerName = playerName:lower()
    for _, msg in ipairs(directBucket.messages) do
        local author = msg.author or ""
        if author:lower() == lowerName then
            matches[#matches + 1] = msg
        end
    end

    if #matches == 0 then return nil end

    -- Return last 10 messages
    local start = math.max(1, #matches - 9)
    local result = {}
    for i = start, #matches do
        result[#result + 1] = matches[i]
    end
    return result
end

-- ============================================================================
-- §28  BNET PROPAGATION (cross-realm listing spread via Battle.net friends)
-- ============================================================================
-- Silently sends guild listings to BNet friends who have MidnightUI.
-- Their addon receives it, stores it, and relays it to their local realm channel.
-- This bridges the realm gap without any external server.

local BNET_PREFIX = "MUI_RCRT"  -- same prefix, BNet uses separate event
local bnetPropagationDone = false  -- only propagate once per session

-- Send a listing to all online BNet friends via BNSendGameData
local function PropagateToBNetFriends(payload)
    if not BNSendGameData then return end
    if not BNGetNumFriends then return end

    local ok, numFriends = pcall(BNGetNumFriends)
    if not ok or not numFriends or numFriends == 0 then return end

    local sent = 0
    for i = 1, numFriends do
        local friendInfo = nil
        if C_BattleNet and C_BattleNet.GetFriendAccountInfo then
            local okInfo, info = pcall(C_BattleNet.GetFriendAccountInfo, i)
            if okInfo and info then friendInfo = info end
        end

        if friendInfo then
            -- Check if this friend is online and playing WoW
            local gameInfo = friendInfo.gameAccountInfo
            if gameInfo and gameInfo.isOnline and gameInfo.clientProgram == "WoW" then
                local presenceID = friendInfo.bnetAccountID
                if presenceID then
                    -- BNSendGameData: silent, invisible, cross-realm
                    pcall(BNSendGameData, presenceID, BNET_PREFIX, payload)
                    sent = sent + 1
                end
            end
        end
    end
end

-- Propagate own guild's listing to BNet friends (called on Save & Broadcast)
local function PropagateOwnListing()
    if not DB or not DB.config or not DB.config.enabled then return end
    if not recruitChannelId then return end

    local cfg = DB.config
    local guildName = ""
    if IsInGuild() then guildName = SafeCall(GetGuildInfo, "player") or "" end
    if guildName == "" then return end

    local function serializeRole(role)
        local r = cfg.roles[role] or {}
        local openStr = r.open and "1" or "0"
        local prio = r.priority or "NONE"
        local classes = table.concat(r.classes or {}, ",")
        if classes == "" then classes = "NONE" end
        return openStr .. "~" .. prio .. "~" .. classes
    end

    local gtStr = table.concat(cfg.guildType or {}, ",")
    if gtStr == "" then gtStr = "NONE" end
    local dayStr = table.concat(cfg.raidDays or {}, ",")
    if dayStr == "" then dayStr = "NONE" end

    local payload = "GLISTING"
        .. "|" .. guildName
        .. "|" .. (cfg.realm or "")
        .. "|" .. (cfg.faction or "")
        .. "|" .. (cfg.region or "")
        .. "|" .. gtStr
        .. "|" .. (cfg.raidProgress or "")
        .. "|" .. dayStr
        .. "|" .. (cfg.raidTime or "")
        .. "|" .. (cfg.timezone or "")
        .. "|" .. serializeRole("TANK")
        .. "|" .. serializeRole("HEALER")
        .. "|" .. serializeRole("DPS")
        .. "|" .. (cfg.minIlvl or 0)
        .. "|" .. (cfg.minMplus or 0)
        .. "|" .. (cfg.description or "")

    PropagateToBNetFriends(payload)
end

-- Propagate all cached listings to BNet friends (called on login for cross-realm seeding)
local function PropagateAllCachedListings()
    if not DB or not DB.listings then return end
    if bnetPropagationDone then return end
    bnetPropagationDone = true

    local myGuild = ""
    if IsInGuild() then myGuild = SafeCall(GetGuildInfo, "player") or "" end
    local myRealm = SafeCall(GetRealmName) or ""

    local now = time()
    local idx = 0
    for key, l in pairs(DB.listings) do
        if l.guildName ~= myGuild and (now - (l.receivedAt or 0)) < LISTING_TTL then
            -- Only propagate listings from OTHER realms (same-realm listings spread via channel)
            if l.realm and l.realm ~= myRealm then
                idx = idx + 1
                if idx > 10 then break end  -- cap at 10 per login to avoid BNet flood
                local function serializeRole(r)
                    if not r then return "0~NONE~NONE" end
                    local openStr = r.open and "1" or "0"
                    local prio = r.priority or "NONE"
                    local classes = table.concat(r.classes or {}, ",")
                    if classes == "" then classes = "NONE" end
                    return openStr .. "~" .. prio .. "~" .. classes
                end

                local gtStr = table.concat(l.guildType or {}, ",")
                if gtStr == "" then gtStr = "NONE" end
                local dayStr = table.concat(l.raidDays or {}, ",")
                if dayStr == "" then dayStr = "NONE" end

                local payload = "GLISTING"
                    .. "|" .. (l.guildName or "")
                    .. "|" .. (l.realm or "")
                    .. "|" .. (l.faction or "")
                    .. "|" .. (l.region or "")
                    .. "|" .. gtStr
                    .. "|" .. (l.raidProgress or "")
                    .. "|" .. dayStr
                    .. "|" .. (l.raidTime or "")
                    .. "|" .. (l.timezone or "")
                    .. "|" .. serializeRole(l.roles and l.roles.TANK)
                    .. "|" .. serializeRole(l.roles and l.roles.HEALER)
                    .. "|" .. serializeRole(l.roles and l.roles.DPS)
                    .. "|" .. (l.minIlvl or 0)
                    .. "|" .. (l.minMplus or 0)
                    .. "|" .. (l.description or "")

                C_Timer.After(0.5 * idx, function()
                    PropagateToBNetFriends(payload)
                end)
            end
        end
    end
end

-- Listen for BNet addon messages (cross-realm listings arriving from friends)
local bnetEvf = CreateFrame("Frame")
bnetEvf:RegisterEvent("BN_CHAT_MSG_ADDON")
bnetEvf:SetScript("OnEvent", function(_, event, prefix, message, _, sender)
    if event ~= "BN_CHAT_MSG_ADDON" then return end
    if prefix ~= BNET_PREFIX then return end
    if not DB then return end

    -- Process the message (same handler as channel messages)
    local fullMsg = ProcessChunk(tostring(sender), message)
    if not fullMsg then return end

    local cmd = fullMsg:match("^(%a+)|") or fullMsg:match("^(%a+)$")
    if cmd == "GLISTING" then
        HandleGLISTING(fullMsg, tostring(sender))
        -- Also relay to local realm channel so other players on this realm get it
        if recruitChannelId then
            C_Timer.After(1, function()
                SendChunked(fullMsg, "CHANNEL", tostring(recruitChannelId))
            end)
        end
    elseif cmd == "GAPPLY" then
        HandleGAPPLY(fullMsg, tostring(sender))
    elseif cmd == "AACK" then
        HandleAACK(fullMsg, tostring(sender))
    end
end)

-- ============================================================================
-- §27  INTELLIGENCE EVENT HANDLER (dossier + prospect + welcome)
-- ============================================================================
local recruitIntelEvf = CreateFrame("Frame")
recruitIntelEvf:RegisterEvent("CHAT_MSG_SYSTEM")
recruitIntelEvf:RegisterEvent("CHAT_MSG_CHANNEL")
recruitIntelEvf:RegisterEvent("GUILD_ROSTER_UPDATE")
recruitIntelEvf:SetScript("OnEvent", function(_, event, ...)
    if not DB then return end

    if event == "GUILD_ROSTER_UPDATE" then
        RefreshRosterCache()

    elseif event == "CHAT_MSG_SYSTEM" then
        local msg = ...
        if not msg then return end
        local lower = msg:lower()

        -- Departure detection
        local leftPlayer = msg:match("(.+) has left the guild")
        if leftPlayer then
            CreateDossier(leftPlayer, SafeCall(GetRealmName) or "", "left", "")
            return
        end

        local removedPlayer, removedBy = msg:match("(.+) has been removed from the guild by (.+)")
        if removedPlayer and removedBy then
            CreateDossier(removedPlayer, SafeCall(GetRealmName) or "", "removed", removedBy)
            return
        end

        -- Join detection (for dossier encounter tracking + auto-welcome)
        local joinedPlayer = msg:match("(.+) has joined the guild")
        if joinedPlayer then
            -- Update dossier if exists (returning member)
            local key = joinedPlayer .. "-" .. (SafeCall(GetRealmName) or "")
            if DB.dossiers and DB.dossiers[key] then
                local d = DB.dossiers[key]
                d.encounters = d.encounters or {}
                d.encounters[#d.encounters + 1] = { date = time(), action = "joined" }
                d.joinedAt = time()
            end
            -- Auto-welcome
            OnGuildJoinDetected(joinedPlayer)
        end

    elseif event == "CHAT_MSG_CHANNEL" then
        local msg, sender, _, _, _, _, _, channelName = ...
        ScanForProspect(msg or "", sender or "", channelName or "")
    end
end)

-- ============================================================================
-- §14  PUBLIC API EXPORTS
-- ============================================================================
Recruit.CanManageRecruitment = CanManageRecruitment
Recruit.IsBanned = IsBanned
Recruit.BanPlayer = BanPlayer
Recruit.UnbanPlayer = UnbanPlayer
Recruit.ApplyTemplatePlaceholders = ApplyTemplatePlaceholders
Recruit.GetWhisperHistory = GetWhisperHistory
Recruit.CheckDossierOnApply = CheckDossierOnApply

_G.MidnightUI_GuildRecruitAPI = Recruit

-- ============================================================================
-- §15  INITIALIZATION (ADDON_LOADED + delayed sync)
-- ============================================================================
local initEvf = CreateFrame("Frame")
initEvf:RegisterEvent("ADDON_LOADED")
initEvf:RegisterEvent("PLAYER_ENTERING_WORLD")
initEvf:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitDB()

        -- Clean up expired bans
        if DB and DB.banned then
            local now = time()
            for key, ban in pairs(DB.banned) do
                if type(ban) == "table" and ban.expiresAt and ban.expiresAt > 0 and now > ban.expiresAt then
                    DB.banned[key] = nil
                end
            end
        end

        -- Clean up expired applications
        if DB and DB.applications then
            local now = time()
            local expiryDays = (DB.settings and DB.settings.expiryDays) or 14
            local expirySec = expiryDays * 86400
            for key, app in pairs(DB.applications) do
                if (now - (app.appliedAt or 0)) > expirySec then
                    app.status = "EXPIRED"
                    app.archivedAt = now
                    DB.history[key] = app
                    DB.applications[key] = nil
                end
            end
        end

        -- Clean up old history
        if DB and DB.history then
            local now = time()
            local retDays = (DB.settings and DB.settings.historyRetentionDays) or 90
            local retSec = retDays * 86400
            for key, app in pairs(DB.history) do
                if (now - (app.archivedAt or app.appliedAt or 0)) > retSec then
                    DB.history[key] = nil
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if not DB then InitDB() end
        ResolveSpecIcons()

        -- Join the shared recruitment channel (hidden from chat, addon messages only)
        C_Timer.After(5, function()
            local chanId = GetChannelName(RECRUIT_CHANNEL)
            if chanId == 0 then
                JoinTemporaryChannel(RECRUIT_CHANNEL)
                C_Timer.After(2, function()
                    recruitChannelId = GetChannelName(RECRUIT_CHANNEL)
                    -- Hide the channel from chat frames so players don't see it
                    if recruitChannelId and recruitChannelId > 0 then
                        for i = 1, NUM_CHAT_WINDOWS do
                            local cf = _G["ChatFrame" .. i]
                            if cf then pcall(ChatFrame_RemoveChannel, cf, RECRUIT_CHANNEL) end
                        end
                    end
                end)
            else
                recruitChannelId = chanId
            end
        end)

        -- Delayed sync request (guild-internal)
        C_Timer.After(8, function()
            if IsInGuild() then
                RequestSync()
                C_Timer.After(2, function()
                    if CanGuildInviteCheck() then
                        pcall(C_ChatInfo.SendAddonMessage, RCRT_PREFIX, "ASYNC", "GUILD")
                    end
                end)
            end
        end)

        -- Periodic channel broadcast (every 5 minutes if recruitment is active)
        C_Timer.NewTicker(CHANNEL_BROADCAST_INTERVAL, function()
            if DB and DB.config and DB.config.enabled and CanManageRecruitment() then
                BroadcastListing()
            end
        end)

        -- Start retry timer for undelivered outbound applications
        if DB and DB.pendingOutbound then
            local hasPending = false
            for _, pending in pairs(DB.pendingOutbound) do
                if not pending.delivered then hasPending = true; break end
            end
            if hasPending then
                StartRetryTimer()
            end
        end

        -- Cross-realm seed: relay stored listings to local channel + BNet friends on login
        C_Timer.After(15, function()
            if DB and DB.listings and recruitChannelId then
                local count = 0
                for _ in pairs(DB.listings) do count = count + 1 end
                if count > 0 then
                    lastRelayTime = 0
                    RelayListings()
                end
            end
            -- Also push cached cross-realm listings to BNet friends
            PropagateAllCachedListings()
            -- If this character is an officer with active recruitment, push own listing too
            if DB and DB.config and DB.config.enabled and CanManageRecruitment() then
                C_Timer.After(5, function()
                    PropagateOwnListing()
                end)
            end
        end)

        -- Periodic relay of cached listings (every 10 minutes, all players)
        C_Timer.NewTicker(RELAY_INTERVAL, function()
            if DB and DB.listings then
                local count = 0
                for _ in pairs(DB.listings) do count = count + 1 end
                if count > 0 then
                    RelayListings()
                end
            end
        end)

        -- Clean up stale listings (older than LISTING_TTL)
        C_Timer.NewTicker(300, function()
            if not DB or not DB.listings then return end
            local now = time()
            for key, listing in pairs(DB.listings) do
                if now - (listing.receivedAt or 0) > LISTING_TTL then
                    DB.listings[key] = nil
                end
            end
        end)
    end
end)

-- ============================================================================
-- §16  TEST COMMANDS
-- ============================================================================
-- /rtest — simulate receiving an application
SLASH_RECRUITTEST1 = "/rtest"
SlashCmdList["RECRUITTEST"] = function(arg)
    if not DB then return end
    local names = { "Firebrand", "Moonguard", "Shadowstep", "Ironbark", "Frostweave" }
    local classes = { "MAGE", "DRUID", "ROGUE", "WARRIOR", "PRIEST" }
    local specs = { "Fire", "Restoration", "Subtlety", "Protection", "Holy" }
    local ilvls = { 625, 618, 630, 622, 615 }
    local mplus = { 2400, 1800, 2600, 2100, 1500 }
    local idx = tonumber(arg) or math.random(1, #names)
    idx = math.max(1, math.min(#names, idx))

    local testMsg = "APPLY|" .. names[idx] .. "|TestRealm|" .. classes[idx] .. "|" .. specs[idx]
        .. "|80|" .. ilvls[idx] .. "|" .. mplus[idx] .. "|25000|DPS|Tues/Thurs 8-11pm"
    HandleAPPLY(testMsg, "TestSender")

    local dbg = _G.MidnightUI_Debug or print
    dbg("|cff40d940[Recruit Test]|r Simulated application from: " .. names[idx])
end

-- /gftest — simulate receiving guild listings for testing the finder
SLASH_GFTEST1 = "/gftest"
SlashCmdList["GFTEST"] = function()
    if not DB then return end
    local testGuilds = {
        { name = "Eternal Flames", realm = "Sargeras", faction = "Horde", region = "US",
          types = { "RAID", "MYTHICPLUS" }, progress = "6/8M", days = { "TUE", "THU" },
          raidTime = "8:00 PM - 11:00 PM", tz = "EST", desc = "CE-focused guild looking for dedicated raiders.",
          tank = { open = true, priority = "HIGH", classes = { "WARRIOR", "DEATHKNIGHT" } },
          healer = { open = false, priority = "NONE", classes = {} },
          dps = { open = true, priority = "LOW", classes = { "MAGE", "WARLOCK", "HUNTER" } } },
        { name = "Moonlight Syndicate", realm = "Area 52", faction = "Horde", region = "US",
          types = { "RAID", "SOCIAL" }, progress = "8/8H", days = { "WED", "SUN" },
          raidTime = "7:00 PM - 10:00 PM", tz = "CST", desc = "Friendly AOTC guild. All skill levels welcome!",
          tank = { open = true, priority = "LOW", classes = {} },
          healer = { open = true, priority = "HIGH", classes = { "PRIEST", "SHAMAN" } },
          dps = { open = true, priority = "LOW", classes = {} } },
        { name = "Phantom Legion", realm = "Stormrage", faction = "Alliance", region = "US",
          types = { "MYTHICPLUS", "PVP" }, progress = "", days = { "FRI", "SAT" },
          raidTime = "9:00 PM - 12:00 AM", tz = "PST", desc = "High key pushers and rated BG team.",
          tank = { open = false, priority = "NONE", classes = {} },
          healer = { open = true, priority = "HIGH", classes = { "EVOKER", "DRUID" } },
          dps = { open = true, priority = "HIGH", classes = { "ROGUE", "DEMONHUNTER" } } },
        { name = "The Wanderers", realm = "Wyrmrest Accord", faction = "Alliance", region = "US",
          types = { "RP", "SOCIAL" }, progress = "", days = { "MON", "WED", "FRI" },
          raidTime = "6:00 PM - 9:00 PM", tz = "PST", desc = "Heavy RP guild with weekly events and storylines.",
          tank = { open = true, priority = "LOW", classes = {} },
          healer = { open = true, priority = "LOW", classes = {} },
          dps = { open = true, priority = "LOW", classes = {} } },
        { name = "Ragnaros Reborn", realm = "Illidan", faction = "Horde", region = "US",
          types = { "RAID", "HARDCORE" }, progress = "3/8M", days = { "TUE", "WED", "THU" },
          raidTime = "9:00 PM - 12:00 AM", tz = "EST", desc = "Progressing mythic. Need strong DPS for roster.",
          tank = { open = false, priority = "NONE", classes = {} },
          healer = { open = false, priority = "NONE", classes = {} },
          dps = { open = true, priority = "HIGH", classes = { "MAGE", "WARLOCK", "EVOKER", "HUNTER" } } },
    }

    for _, g in ipairs(testGuilds) do
        local key = g.name .. "-" .. g.realm
        DB.listings[key] = {
            guildName = g.name, realm = g.realm, faction = g.faction, region = g.region,
            guildType = g.types, raidProgress = g.progress, raidDays = g.days,
            raidTime = g.raidTime, timezone = g.tz, description = g.desc,
            roles = { TANK = g.tank, HEALER = g.healer, DPS = g.dps },
            minIlvl = 0, minMplus = 0, sender = "TestOfficer",
            receivedAt = time(),
        }
    end

    local dbg = _G.MidnightUI_Debug or print
    dbg("|cff40d940[Guild Finder Test]|r Added " .. #testGuilds .. " test guild listings.")
    Recruit.ShowGuildFinder()
end
