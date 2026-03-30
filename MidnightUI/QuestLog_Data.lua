-- =============================================================================
-- FILE PURPOSE:     Quest data engine. Collects quest metadata from WoW API, buckets
--                   quests into "now/next/later/turnIn/expiring" categories, resolves
--                   objectives, and manages a row-widget object pool shared with
--                   QuestLog_Panel.lua. Pure data layer — no UI code, no frame creation,
--                   no references to Runtime or the map frame state.
-- LOAD ORDER:       Loads after QuestLog_Config.lua, before QuestLog_Panel.lua. Contains same early-exit guard.
-- DEFINES:          Addon.QuestData (table QuestData) with:
--                   QuestData._pools{} — pooled row widgets: headers, quests, objectives,
--                     bucketHeaders, focusHeaders, zoneBanners, etc.
--                   QuestData._metaCache{} — questID → metadata cache (cleared on refresh).
--                   QuestData._collapseState{} — zone header collapse state by key.
--                   QuestData._bucketCollapseState{} — bucket collapse state.
--                   QuestData._expandedQuests{} — set of expanded questIDs.
--                   QuestData.CollectAll() — main entry: returns bucketed quest list.
--                   QuestData.AcquireRow(poolKey) / ReleaseRow(poolKey, row) — pooling API.
-- READS:            C_QuestLog.GetAllCompletedQuests, C_QuestLog.GetQuestObjectives,
--                   C_QuestLog.GetQuestInfo, C_QuestLog.IsQuestWatched, etc.
--                   QLC (Addon.QuestLogConfig) — bucket thresholds, tag IDs, colors.
-- WRITES:           QuestData._metaCache — populated during CollectAll, cleared each call.
--                   QuestData._pools — acquire inserts widgets; release returns them.
-- DEPENDS ON:       Addon.QuestLogConfig (QLC) — bucket/timing constants.
-- USED BY:          QuestLog_Panel.lua — calls QuestData.CollectAll() to get the bucketed
--                   quest list, then calls Acquire/Release for row widgets.
--                   Map.lua — reads quest data to render quest pins on the map.
-- GOTCHAS:
--   Object pool: ResetQuestListPooledRow() stops any running animation groups before
--   returning a row to the pool — failing to stop animations can cause frame corruption
--   when the row is reused with new data.
--   _bucketCollapseState: "later" bucket starts collapsed by default (true = collapsed)
--   to reduce visual noise in long quest lists.
--   Time-sensitive classification: quests with QLC.TIME_SENSITIVE_TAG_IDS tags are forced
--   into "expiring" bucket if within EXPIRING_EXTRACT_THRESHOLD, regardless of time remaining.
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

local QLC = Addon.QuestLogConfig
if type(QLC) ~= "table" then return end

local QuestData = {}
QuestData._metaCache = {}

-- ============================================================================
-- POOL MANAGEMENT
-- ============================================================================

QuestData._pools = {
    headers = {},
    quests = {},
    objectives = {},
    empty = {},
    bucketHeaders = {},
    focusHeaders = {},
    zoneBanners = {},
    zoneSubHeaders = {},
    comboBoxes = {},
    abandonButtons = {},
}

QuestData._collapseState = {}
QuestData._bucketCollapseState = { now = false, next = false, later = true, turnIn = false, expiring = false }
QuestData._expandedQuests = {}  -- NEW: track which questIDs are expanded

local function StopQuestListAnimationGroup(animGroup)
    if not animGroup or type(animGroup.IsPlaying) ~= "function" or type(animGroup.Stop) ~= "function" then
        return
    end
    local okPlaying, isPlaying = pcall(animGroup.IsPlaying, animGroup)
    if okPlaying and isPlaying then
        pcall(animGroup.Stop, animGroup)
    end
end

local function ResetQuestListPooledRow(row)
    if not row then
        return
    end

    StopQuestListAnimationGroup(row._pulseGroup)
    StopQuestListAnimationGroup(row._upgradePulse)

    if type(row.SetAlpha) == "function" then
        row:SetAlpha(1)
    end
    if type(row.ClearAllPoints) == "function" then
        row:ClearAllPoints()
    end
    if type(row.Hide) == "function" then
        row:Hide()
    end
end

-- ============================================================================
-- POOL ACQUIRE / RELEASE
-- ============================================================================

function QuestData.QuestListAcquireFromPool(poolKey, createFunc, parent)
    local pool = QuestData._pools[poolKey]
    if type(pool) ~= "table" then
        pool = {}
        QuestData._pools[poolKey] = pool
    end

    for i = 1, #pool do
        local row = pool[i]
        if row and not row._muiQuestListInUse then
            row._muiQuestListInUse = true
            if parent and type(row.SetParent) == "function" then
                local currentParent = (type(row.GetParent) == "function") and row:GetParent() or nil
                if currentParent ~= parent then
                    row:SetParent(parent)
                end
            end
            if type(row.SetAlpha) == "function" then
                row:SetAlpha(1)
            end
            if type(row.Show) == "function" then
                row:Show()
            end
            return row
        end
    end

    if type(createFunc) ~= "function" then
        return nil
    end

    local okCreate, row = pcall(createFunc, parent)
    if not okCreate or not row then
        return nil
    end

    row._muiQuestListPoolKey = poolKey
    row._muiQuestListInUse = true
    pool[#pool + 1] = row

    if type(row.SetAlpha) == "function" then
        row:SetAlpha(1)
    end
    if type(row.Show) == "function" then
        row:Show()
    end

    return row
end

function QuestData.QuestListReleaseAllInPool(poolKey)
    local pool = QuestData._pools[poolKey]
    if type(pool) ~= "table" then
        return
    end

    for i = 1, #pool do
        local row = pool[i]
        if row then
            row._muiQuestListInUse = false
            ResetQuestListPooledRow(row)
        end
    end
end

-- ============================================================================
-- SHOULD SHOW QUEST OBJECTIVES IN LOG
-- ============================================================================

function QuestData.ShouldShowQuestObjectivesInLog()
    if type(GetCVarBool) == "function" then
        local ok, value = pcall(GetCVarBool, "showQuestObjectivesInLog")
        if ok and type(value) == "boolean" then
            return value
        end
    end
    return true
end

-- ============================================================================
-- EXTRACT FOCUSED QUEST FROM BUCKETS
-- ============================================================================

function QuestData.ExtractFocusedQuestFromBuckets(listData, focusedQuestID)
    if type(focusedQuestID) ~= "number" or type(listData) ~= "table" or type(listData.buckets) ~= "table" then
        return nil, nil
    end

    for i = 1, #QLC.BUCKET_ORDER do
        local bucketKey = QLC.BUCKET_ORDER[i]
        local quests = listData.buckets[bucketKey]
        if type(quests) == "table" then
            for questIndex = 1, #quests do
                local questData = quests[questIndex]
                if type(questData) == "table" and questData.questID == focusedQuestID then
                    table.remove(quests, questIndex)
                    return questData, bucketKey
                end
            end
        end
    end

    if type(C_QuestLog) == "table" and type(C_QuestLog.GetLogIndexForQuestID) == "function" then
        local okIndex, questLogIndex = pcall(C_QuestLog.GetLogIndexForQuestID, focusedQuestID)
        if okIndex and type(questLogIndex) == "number" and questLogIndex > 0 then
            return nil, nil
        end
    end

    return nil, nil
end

-- ============================================================================
-- DIFFICULTY COLOR
-- ============================================================================

function QuestData.GetQuestDifficultyColorMuted(questLevel, playerLevel)
    if type(questLevel) ~= "number" or questLevel <= 0 then
        return QLC.DIFFICULTY_COLORS.standard
    end
    if type(playerLevel) ~= "number" or playerLevel <= 0 then
        playerLevel = UnitLevel("player") or 1
    end
    local greenRange = type(GetQuestGreenRange) == "function" and GetQuestGreenRange() or 8
    local diff = questLevel - playerLevel
    if diff >= 5 then
        return QLC.DIFFICULTY_COLORS.impossible
    elseif diff >= 3 then
        return QLC.DIFFICULTY_COLORS.veryhard
    elseif diff >= -2 then
        return QLC.DIFFICULTY_COLORS.difficult
    elseif diff >= -greenRange - 1 then
        return QLC.DIFFICULTY_COLORS.standard
    else
        return QLC.DIFFICULTY_COLORS.trivial
    end
end

-- ============================================================================
-- COLLECT RAW QUEST ENTRIES
-- ============================================================================

function QuestData.CollectRawQuestEntries(searchFilter)
    local entries = {}
    if type(C_QuestLog) ~= "table" or type(C_QuestLog.GetNumQuestLogEntries) ~= "function"
        or type(C_QuestLog.GetInfo) ~= "function" then
        return entries
    end

    local okNum, numEntries = pcall(C_QuestLog.GetNumQuestLogEntries)
    if not okNum or type(numEntries) ~= "number" then
        return entries
    end

    local lowerFilter = nil
    if type(searchFilter) == "string" and searchFilter ~= "" then
        lowerFilter = searchFilter:lower()
    end

    local currentHeaderTitle = nil
    for i = 1, numEntries do
        local okInfo, info = pcall(C_QuestLog.GetInfo, i)
        if okInfo and type(info) == "table" and not info.isHidden and not info.isInternalOnly then
            if info.isHeader then
                currentHeaderTitle = info.title or ""
            elseif currentHeaderTitle and info.questID then
                local passesFilter = true
                if lowerFilter then
                    passesFilter = info.title and info.title:lower():find(lowerFilter, 1, true)
                end
                if passesFilter then
                    local objectives = {}
                    if type(C_QuestLog.GetQuestObjectives) == "function" then
                        local okObj, objs = pcall(C_QuestLog.GetQuestObjectives, info.questID)
                        if (not okObj or type(objs) ~= "table") and type(i) == "number" then
                            local okObjByIndex, objsByIndex = pcall(C_QuestLog.GetQuestObjectives, i)
                            if okObjByIndex and type(objsByIndex) == "table" then
                                okObj = true
                                objs = objsByIndex
                            end
                        end
                        if okObj and type(objs) == "table" then
                            objectives = objs
                        end
                    end

                    -- Gather quest tag for group/elite detection
                    local questTagInfo = nil
                    if type(C_QuestLog.GetQuestTagInfo) == "function" then
                        local okTag, tag = pcall(C_QuestLog.GetQuestTagInfo, info.questID)
                        if okTag and type(tag) == "table" then
                            questTagInfo = tag
                        end
                    end

                    -- Determine if quest is on the same map as the player
                    local questMapID = nil
                    if type(C_QuestLog.GetQuestAdditionalHighlights) == "function" then
                        -- not available on all builds; skip
                    end
                    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
                        -- we store the player map separately
                    end

                    -- Check if quest is shared in party
                    local isSharedInParty = false
                    if type(C_QuestLog.IsQuestSharedWithPlayerByPlayerName) == "function" then
                        -- This API doesn't exist; we use a different approach below
                    end

                    -- Enhanced completion detection
                    local isComplete = (info.isComplete == true)
                    if not isComplete and info.questID then
                        if type(C_QuestLog) == "table" and type(C_QuestLog.IsComplete) == "function" then
                            local okC, val = pcall(C_QuestLog.IsComplete, info.questID)
                            if okC and val == true then isComplete = true end
                        end
                        if not isComplete and type(C_QuestLog) == "table" and type(C_QuestLog.ReadyForTurnIn) == "function" then
                            local okR, val = pcall(C_QuestLog.ReadyForTurnIn, info.questID)
                            if okR and val == true then isComplete = true end
                        end
                    end

                    entries[#entries + 1] = {
                        title = info.title or "",
                        questID = info.questID,
                        questLogIndex = i,
                        level = info.level,
                        isComplete = isComplete,
                        frequency = info.frequency,
                        objectives = objectives,
                        headerTitle = currentHeaderTitle,
                        suggestedGroup = info.suggestedGroup,
                        isAutoComplete = info.isAutoComplete,
                        questTagInfo = questTagInfo,
                    }
                end
            end
        end
    end
    return entries
end

-- ============================================================================
-- GET PLAYER QUEST CONTEXT
-- ============================================================================

function QuestData.GetPlayerQuestContext()
    local ctx = {
        playerLevel = UnitLevel("player") or 1,
        zoneName = GetZoneText() or "",
        subZone = GetSubZoneText() or "",
        mapID = nil,
        continentID = nil,
        isInInstance = false,
        instanceName = nil,
        instanceID = nil,
        isInGroup = false,
        groupSize = 0,
        partyQuestIDs = {},
        maxQuests = 35,
        playerX = nil,
        playerY = nil,
        equippedIlvl = QuestData.GetPlayerEquippedIlvl(),
    }

    -- Instance detection
    local inInstance, instanceType = IsInInstance()
    ctx.isInInstance = (inInstance == true or inInstance == 1)
    if ctx.isInInstance then
        local name, _, _, _, _, _, _, instID = GetInstanceInfo()
        ctx.instanceName = name
        ctx.instanceID = instID
    end

    -- Current map
    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
        local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if okMap and type(mapID) == "number" then
            ctx.mapID = mapID
            -- Get continent
            if type(C_Map.GetMapInfo) == "function" then
                local okInfo, mapInfo = pcall(C_Map.GetMapInfo, mapID)
                if okInfo and type(mapInfo) == "table" then
                    ctx.continentID = mapInfo.parentMapID
                end
            end
            -- Get player position
            if type(C_Map.GetPlayerMapPosition) == "function" then
                local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
                if okPos and pos and type(pos.GetXY) == "function" then
                    ctx.playerX, ctx.playerY = pos:GetXY()
                end
            end
        end
    end

    -- Group info
    local numGroup = GetNumGroupMembers()
    if type(numGroup) == "number" and numGroup > 0 then
        ctx.isInGroup = true
        ctx.groupSize = numGroup
        -- Collect party members' quest IDs for co-op detection
        if type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestFlaggedCompleted) == "function" then
            for i = 1, numGroup - 1 do
                local unit = (IsInRaid() and ("raid" .. i)) or ("party" .. i)
                if UnitExists(unit) then
                    -- We can only detect shared quests via quest log flags
                end
            end
        end
    end

    -- Max quest capacity
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetMaxNumQuestsCanAccept) == "function" then
        local okMax, maxQ = pcall(C_QuestLog.GetMaxNumQuestsCanAccept)
        if okMax and type(maxQ) == "number" and maxQ > 0 then
            ctx.maxQuests = maxQ
        end
    elseif type(MAX_QUESTS) == "number" then
        ctx.maxQuests = MAX_QUESTS
    end

    return ctx
end

-- ============================================================================
-- METADATA FILTERS
-- ============================================================================

function QuestData.IsQuestInCurrentZone(quest, ctx)
    if not quest or not ctx then return false end
    -- Header title often matches zone name
    if type(quest.headerTitle) == "string" and type(ctx.zoneName) == "string" then
        if quest.headerTitle == ctx.zoneName then return true end
    end
    -- Check quest map ID if available
    if ctx.mapID and type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestAdditionalHighlights) ~= "function" then
        -- Fallback: check if quest has waypoint on current map
        if type(C_QuestLog.IsOnMap) == "function" then
            local okOnMap, onMap = pcall(C_QuestLog.IsOnMap, quest.questID)
            if okOnMap and onMap then return true end
        end
    end
    return false
end

-- Check if quest is elite/group type
function QuestData.IsGroupOrEliteQuest(quest)
    if not quest then return false end
    local tag = quest.questTagInfo
    if type(tag) == "table" then
        if tag.isElite then return true end
        if type(tag.tagID) == "number" then
            -- Group quest tag IDs: 1=Group, 41=PvP, 62=Raid, 81=Dungeon, 82=WorldEvent
            if tag.tagID == 1 or tag.tagID == 62 or tag.tagID == 81 then
                return true
            end
        end
    end
    if type(quest.suggestedGroup) == "number" and quest.suggestedGroup > 1 then
        return true
    end
    return false
end

-- Check if a quest is trivial (grey) or impossibly hard (red/skull)
function QuestData.IsQuestOutleveled(quest, playerLevel)
    if type(quest.level) ~= "number" or quest.level <= 0 then return false end
    local diff = quest.level - playerLevel
    local greenRange = type(GetQuestGreenRange) == "function" and GetQuestGreenRange() or 8
    if diff < -(greenRange + 1) then return true, "trivial" end
    if diff >= 10 then return true, "impossible" end
    return false
end

-- Calculate quest proximity score (lower = closer) using map coordinates
function QuestData.GetQuestProximityScore(quest, ctx)
    -- If we can get quest waypoints, compute distance
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetNextWaypointForMap) == "function"
        and ctx.mapID and ctx.playerX and ctx.playerY then
        local okWP, wpX, wpY = pcall(C_QuestLog.GetNextWaypointForMap, quest.questID, ctx.mapID)
        if okWP and type(wpX) == "number" and type(wpY) == "number" then
            local dx = wpX - ctx.playerX
            local dy = wpY - ctx.playerY
            return math.sqrt(dx * dx + dy * dy)
        end
    end
    -- Fallback: if quest is in current zone it's "close", otherwise far
    if QuestData.IsQuestInCurrentZone(quest, ctx) then
        return 0.5
    end
    return 100
end

-- Detect quests targeting the same NPC/keyword (Synergy Engine)
function QuestData.FindSynergyGroups(quests)
    -- Extract target keywords from objective text
    local keywordMap = {}  -- keyword -> { questIndices }
    for idx, quest in ipairs(quests) do
        if type(quest.objectives) == "table" then
            for _, obj in ipairs(quest.objectives) do
                if type(obj) == "table" and type(obj.text) == "string" then
                    -- Extract "Kill X" or "Slay X" target names
                    local target = obj.text:match("[Kk]ill%s+%d*%s*(.+)")
                        or obj.text:match("[Ss]lay%s+%d*%s*(.+)")
                        or obj.text:match("[Dd]efeat%s+%d*%s*(.+)")
                    if target then
                        target = target:gsub("%s*%d+/%d+%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if target ~= "" then
                            local key = target:lower()
                            if not keywordMap[key] then
                                keywordMap[key] = { keyword = target, questIndices = {} }
                            end
                            local indices = keywordMap[key].questIndices
                            -- Avoid duplicates
                            local found = false
                            for _, existing in ipairs(indices) do
                                if existing == idx then found = true; break end
                            end
                            if not found then
                                indices[#indices + 1] = idx
                            end
                        end
                    end
                end
            end
        end
    end

    -- Only keep groups with 2+ quests
    local groups = {}
    for _, data in pairs(keywordMap) do
        if #data.questIndices >= 2 then
            groups[#groups + 1] = data
        end
    end
    return groups
end

-- Check if party members share this quest (Co-Op Sync)
function QuestData.IsQuestSharedWithParty(quest, ctx)
    if not ctx.isInGroup then return false end
    -- Check if any party member is on the same quest
    if type(C_QuestLog) == "table" and type(C_QuestLog.IsUnitOnQuest) == "function" then
        for i = 1, ctx.groupSize - 1 do
            local unit = (IsInRaid() and ("raid" .. i)) or ("party" .. i)
            if UnitExists(unit) then
                local okOnQ, onQuest = pcall(C_QuestLog.IsUnitOnQuest, unit, quest.questID)
                if okOnQ and onQuest then return true end
            end
        end
    end
    return false
end

-- ============================================================================
-- METADATA FILTER 1: Campaign vs. Side-Quest Detection
-- Uses C_CampaignInfo.GetCampaignID(questID) -- returns campaignID or nil/0.
-- Campaign quests get pinned above side-quests in the NEXT bucket.
-- ============================================================================
function QuestData.IsCampaignQuest(questID)
    if type(questID) ~= "number" then return false end
    -- Primary: C_CampaignInfo.GetCampaignID (TWW+)
    if type(C_CampaignInfo) == "table" and type(C_CampaignInfo.GetCampaignID) == "function" then
        local okCamp, campID = pcall(C_CampaignInfo.GetCampaignID, questID)
        if okCamp and type(campID) == "number" and campID > 0 then
            return true
        end
    end
    -- Fallback: check quest tag for "Story" classification (tagID 270 = Story in TWW)
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestTagInfo) == "function" then
        local okTag, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)
        if okTag and type(tag) == "table" and type(tag.tagID) == "number" then
            -- 270 = Important/Story, 271 = Legendary
            if tag.tagID == 270 or tag.tagID == 271 then
                return true
            end
        end
    end
    return false
end

-- ============================================================================
-- METADATA FILTER 2: Reward iLvl Scanning
-- Compares quest reward item levels against the player's equipped average.
-- Returns (isUpgrade, maxRewardIlvl) where isUpgrade is true if any
-- reward item exceeds the player's current equipped ilvl for that slot.
-- ============================================================================
function QuestData.GetPlayerEquippedIlvl()
    if type(GetAverageItemLevel) == "function" then
        local okIlvl, avgEquipped = pcall(GetAverageItemLevel)
        if okIlvl and type(avgEquipped) == "number" and avgEquipped > 0 then
            return avgEquipped
        end
    end
    return 0
end

function QuestData.ScanQuestRewardUpgrade(questID, questLogIndex, equippedIlvl)
    if type(equippedIlvl) ~= "number" or equippedIlvl <= 0 then return false, 0 end

    if not QuestData._metaCache[questID] then QuestData._metaCache[questID] = {} end
    local cache = QuestData._metaCache[questID]
    if cache.upgradeScan and cache.equippedIlvl == equippedIlvl then
        return cache.isUpgrade, cache.maxRewardIlvl
    end

    local maxRewardIlvl = 0
    local isUpgrade = false

    local numRewards = 0
    if type(GetNumQuestLogRewards) == "function" then
        local okNum, n = pcall(GetNumQuestLogRewards, questID)
        if okNum and type(n) == "number" then numRewards = n end
    end

    for i = 1, numRewards do
        if type(GetQuestLogRewardInfo) == "function" then
            local okR, name, _, _, quality, _, itemID = pcall(GetQuestLogRewardInfo, i, questID)
            if okR and type(itemID) == "number" and itemID > 0 then
                if type(C_Item) == "table" and type(C_Item.GetDetailedItemLevelInfo) == "function" then
                    local okLvl, effectiveIlvl = pcall(C_Item.GetDetailedItemLevelInfo, itemID)
                    if okLvl and type(effectiveIlvl) == "number" and effectiveIlvl > 0 then
                        if effectiveIlvl > maxRewardIlvl then maxRewardIlvl = effectiveIlvl end
                        if effectiveIlvl > equippedIlvl then isUpgrade = true end
                    end
                end
            end
        end
    end

    local numChoices = 0
    if type(GetNumQuestLogChoices) == "function" then
        local okC, c = pcall(GetNumQuestLogChoices, questID)
        if okC and type(c) == "number" then numChoices = c end
    end

    for i = 1, numChoices do
        if type(GetQuestLogChoiceInfo) == "function" then
            local okC, name, _, _, quality, _, itemID = pcall(GetQuestLogChoiceInfo, i, questID)
            if okC and type(itemID) == "number" and itemID > 0 then
                if type(C_Item) == "table" and type(C_Item.GetDetailedItemLevelInfo) == "function" then
                    local okLvl, effectiveIlvl = pcall(C_Item.GetDetailedItemLevelInfo, itemID)
                    if okLvl and type(effectiveIlvl) == "number" and effectiveIlvl > 0 then
                        if effectiveIlvl > maxRewardIlvl then maxRewardIlvl = effectiveIlvl end
                        if effectiveIlvl > equippedIlvl then isUpgrade = true end
                    end
                end
            end
        end
    end

    cache.upgradeScan = true
    cache.equippedIlvl = equippedIlvl
    cache.isUpgrade = isUpgrade
    cache.maxRewardIlvl = maxRewardIlvl
    return isUpgrade, maxRewardIlvl
end

-- ============================================================================
-- METADATA FILTER 3: Time-Sensitive Priority Detection
-- Checks quest tag for time-limited flags (World Quests, Bonus Objectives,
-- Calling/Emissary quests, Threat quests) and quest expiration timers.
-- Returns a priority multiplier: 1.0 = normal, >1.0 = time-sensitive.
-- ============================================================================

function QuestData.GetTimeSensitivePriority(quest)
    local multiplier = 1.0
    local tag = quest.questTagInfo

    -- Check for known time-limited tag IDs
    if type(tag) == "table" and type(tag.tagID) == "number" then
        if QLC.TIME_SENSITIVE_TAG_IDS[tag.tagID] then
            multiplier = 2.0
        end
    end

    -- Check daily/weekly frequency (mild boost)
    if type(quest.frequency) == "number" then
        local daily = _G.LE_QUEST_FREQUENCY_DAILY
        local weekly = _G.LE_QUEST_FREQUENCY_WEEKLY
        if quest.frequency == daily then
            multiplier = math.max(multiplier, 1.5)
        elseif quest.frequency == weekly then
            multiplier = math.max(multiplier, 1.3)
        end
    end

    -- Check for quest expiration timer via C_TaskQuest (bonus/world quests)
    if type(C_TaskQuest) == "table" and type(C_TaskQuest.GetQuestTimeLeftSeconds) == "function" then
        local okTime, timeLeft = pcall(C_TaskQuest.GetQuestTimeLeftSeconds, quest.questID)
        if okTime and type(timeLeft) == "number" and timeLeft > 0 then
            quest._expiresInSeconds = timeLeft
            -- Expiring within 2 hours = urgent
            if timeLeft <= 7200 then
                multiplier = math.max(multiplier, 3.0)
                quest._isExpiringSoon = true
            -- Expiring within 8 hours = elevated
            elseif timeLeft <= 28800 then
                multiplier = math.max(multiplier, 2.0)
            end
        end
    end

    -- Check QuestLog timer (timed quests with embedded countdown)
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetTimeAllowed) == "function" then
        local okTA, totalTime, elapsedTime = pcall(C_QuestLog.GetTimeAllowed, quest.questID)
        if okTA and type(totalTime) == "number" and totalTime > 0
            and type(elapsedTime) == "number" then
            local remaining = totalTime - elapsedTime
            if remaining > 0 then
                quest._expiresInSeconds = quest._expiresInSeconds
                    and math.min(quest._expiresInSeconds, remaining) or remaining
                if remaining <= 600 then  -- <10 min
                    multiplier = math.max(multiplier, 4.0)
                    quest._isExpiringSoon = true
                elseif remaining <= 3600 then  -- <1 hr
                    multiplier = math.max(multiplier, 2.5)
                    quest._isExpiringSoon = true
                end
            end
        end
    end

    return multiplier
end

-- ============================================================================
-- METADATA FILTER 4: Flight Path Cluster Detection (NEXT Bucket)
-- Groups quests near discovered, connected taxi nodes so the player has a
-- logical travel route. Quests sharing a nearest flight node cluster together.
-- ============================================================================
function QuestData.GetNearestFlightNodeForQuest(quest, ctx)
    if not ctx.mapID or not ctx.continentID then return nil end
    if type(C_TaxiMap) ~= "table" or type(C_TaxiMap.GetAllTaxiNodes) ~= "function" then
        return nil
    end

    if not QuestData._metaCache[quest.questID] then QuestData._metaCache[quest.questID] = {} end
    if QuestData._metaCache[quest.questID].flightNodeScanned then
        return QuestData._metaCache[quest.questID].flightNode
    end

    local questX, questY = nil, nil
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetNextWaypointForMap) == "function" then
        local okWP, wpX, wpY = pcall(C_QuestLog.GetNextWaypointForMap, quest.questID, ctx.continentID)
        if okWP and type(wpX) == "number" and type(wpY) == "number" then
            questX, questY = wpX, wpY
        end
        if not questX then
            okWP, wpX, wpY = pcall(C_QuestLog.GetNextWaypointForMap, quest.questID, ctx.mapID)
            if okWP and type(wpX) == "number" and type(wpY) == "number" then
                questX, questY = wpX, wpY
            end
        end
    end

    if not questX or not questY then return nil end

    local okNodes, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, ctx.continentID)
    if not okNodes or type(nodes) ~= "table" then return nil end

    local bestNode = nil
    local bestDist = math.huge

    for _, node in ipairs(nodes) do
        if type(node) == "table" and node.position
            and (node.state == Enum.FlightPathState.Reachable or node.state == _G.TAXISTATE_CURRENT or node.state == 2 or node.state == 1) then
            local nx = node.position.x or 0
            local ny = node.position.y or 0
            local dx = nx - questX
            local dy = ny - questY
            local dist = dx * dx + dy * dy
            if dist < bestDist then
                bestDist = dist
                bestNode = {
                    nodeID = node.nodeID,
                    name = node.name or "Flight Point",
                    distance = math.sqrt(dist),
                }
            end
        end
    end

    QuestData._metaCache[quest.questID].flightNodeScanned = true
    QuestData._metaCache[quest.questID].flightNode = bestNode
    return bestNode
end

-- ============================================================================
-- COLLECT QUEST LIST DATA
-- ============================================================================

function QuestData.CollectQuestListData(searchFilter)
    local data = {
        campaign = nil,
        headers = {},  -- Legacy compat (kept for campaign fallback)
        zoneName = "",
        zoneQuestCount = 0,
        buckets = { now = {}, next = {}, later = {} },
        turnIn = {},
        expiring = {},
        synergyGroups = {},
        totalQuestCount = 0,
        maxQuests = 35,
    }

    -- Campaign progress (unchanged)
    if type(C_CampaignInfo) == "table" then
        local getCurrent = C_CampaignInfo.GetCurrentCampaignID
        if type(getCurrent) == "function" then
            local okCid, campaignID = pcall(getCurrent)
            if okCid and type(campaignID) == "number" and campaignID > 0 then
                local okInfo, info = pcall(C_CampaignInfo.GetCampaignInfo, campaignID)
                if okInfo and type(info) == "table" and info.name then
                    local completed = 0
                    local total = 0
                    local currentChapter = nil
                    if type(C_CampaignInfo.GetCampaignChapterInfo) == "function" then
                        local okCh, chapters = pcall(C_CampaignInfo.GetCampaignChapterInfo, campaignID)
                        if okCh and type(chapters) == "table" then
                            total = #chapters
                            for _, ch in ipairs(chapters) do
                                if ch.completed then
                                    completed = completed + 1
                                elseif not currentChapter and ch.name then
                                    currentChapter = ch.name
                                end
                            end
                        end
                    end
                    local campaignTotal = total
                    if campaignTotal < 1 then campaignTotal = 1 end
                    local campaignProgress = completed
                    if campaignProgress < 0 then campaignProgress = 0
                    elseif campaignProgress > campaignTotal then campaignProgress = campaignTotal end
                    data.campaign = {
                        name = info.name,
                        progress = campaignProgress,
                        total = campaignTotal,
                        chapterName = currentChapter,
                    }
                end
            end
        end
    end

    -- Gather raw entries
    local rawEntries = QuestData.CollectRawQuestEntries(searchFilter)
    local ctx = QuestData.GetPlayerQuestContext()
    data.zoneName = ctx.zoneName
    data.maxQuests = ctx.maxQuests
    data.totalQuestCount = #rawEntries

    -- Build legacy headers for campaign fallback
    local headerMap = {}
    for _, entry in ipairs(rawEntries) do
        local ht = entry.headerTitle or "Quests"
        if not headerMap[ht] then
            headerMap[ht] = { title = ht, quests = {} }
            data.headers[#data.headers + 1] = headerMap[ht]
        end
        headerMap[ht].quests[#headerMap[ht].quests + 1] = entry
    end

    -- Smart bucketing pass
    local nowQuests = {}
    local nextQuests = {}
    local laterQuests = {}
    local zoneQuestCount = 0

    for _, quest in ipairs(rawEntries) do
        local _, _, pct = QuestData.ResolveQuestObjectiveProgress(quest)
        quest._progressPct = pct or 0
        quest._isInCurrentZone = QuestData.IsQuestInCurrentZone(quest, ctx)
        quest._isGroupElite = QuestData.IsGroupOrEliteQuest(quest)
        quest._isSharedParty = QuestData.IsQuestSharedWithParty(quest, ctx)
        quest._proximityScore = QuestData.GetQuestProximityScore(quest, ctx)
        quest._difficultyColor = QuestData.GetQuestDifficultyColorMuted(quest.level, ctx.playerLevel)

        -- METADATA FILTER: Campaign detection
        quest._isCampaignQuest = QuestData.IsCampaignQuest(quest.questID)

        -- METADATA FILTER: Reward ilvl upgrade scanning
        quest._isUpgrade = false
        quest._rewardIlvl = 0
        if ctx.equippedIlvl > 0 then
            local isUp, maxIlvl = QuestData.ScanQuestRewardUpgrade(quest.questID, quest.questLogIndex, ctx.equippedIlvl)
            quest._isUpgrade = isUp
            quest._rewardIlvl = maxIlvl
        end

        -- METADATA FILTER: Time-sensitive priority multiplier
        quest._timePriority = QuestData.GetTimeSensitivePriority(quest)

        -- METADATA FILTER: Flight path cluster (computed for non-current-zone quests)
        quest._nearestFlightNode = nil
        if not quest._isInCurrentZone then
            quest._nearestFlightNode = QuestData.GetNearestFlightNodeForQuest(quest, ctx)
        end

        if quest._isInCurrentZone then
            zoneQuestCount = zoneQuestCount + 1
        end

        local bucket = nil

        -- LATER bucket checks (demote first)
        local outleveled, outlevelReason = QuestData.IsQuestOutleveled(quest, ctx.playerLevel)
        if outleveled then
            quest._laterReason = outlevelReason == "trivial" and "Outleveled (Trivial)" or "Outleveled (Too Hard)"
            bucket = "later"
        elseif quest._isGroupElite and not ctx.isInGroup then
            quest._laterReason = "Elite/Group (Solo)"
            bucket = "later"
        end

        -- NOW bucket: instance override
        if not bucket and ctx.isInInstance then
            -- Inside an instance: only quests for this instance go to NOW
            if quest._isInCurrentZone then
                bucket = "now"
            else
                bucket = "later"
                quest._laterReason = "Outside Instance"
            end
        end

        -- NOW bucket: completed quests ready for turn-in
        if not bucket and quest.isComplete then
            bucket = "now"
            quest._nowReason = "Ready for Turn-in"
        end

        -- NOW bucket: "One Kill Away" (>80% complete)
        if not bucket and quest._progressPct >= QLC.NEARLY_COMPLETE_THRESHOLD and quest._isInCurrentZone then
            bucket = "now"
            quest._nowReason = "Almost Done"
            quest._isNearlyComplete = true
        end

        -- NOW bucket: active in current zone
        if not bucket and quest._isInCurrentZone then
            bucket = "now"
        end

        -- NEXT bucket: everything else on this continent or nearby
        if not bucket then
            -- Completed quests not in current zone go to NEXT (turn-in elsewhere)
            if quest.isComplete then
                bucket = "next"
                quest._nextReason = "Turn-in Elsewhere"
            else
                bucket = "next"
            end
        end

        -- Co-Op bump: shared quests get priority boost within their bucket
        if quest._isSharedParty then
            quest._coopBump = true
        end

        if bucket == "now" then
            nowQuests[#nowQuests + 1] = quest
        elseif bucket == "next" then
            nextQuests[#nextQuests + 1] = quest
        else
            laterQuests[#laterQuests + 1] = quest
        end
    end

    -- Sort NOW bucket: time-sensitive -> upgrades -> nearly-complete -> completed -> co-op -> campaign -> progress
    table.sort(nowQuests, function(a, b)
        -- Time-sensitive global override (invisible multiplier-based priority)
        local aTP = a._timePriority or 1
        local bTP = b._timePriority or 1
        if aTP ~= bTP then return aTP > bTP end
        -- Upgrade rewards pin to top of their tier
        if a._isUpgrade and not b._isUpgrade then return true end
        if not a._isUpgrade and b._isUpgrade then return false end
        -- Nearly complete pins to top
        if a._isNearlyComplete and not b._isNearlyComplete then return true end
        if not a._isNearlyComplete and b._isNearlyComplete then return false end
        -- Completed next
        if a.isComplete and not b.isComplete then return true end
        if not a.isComplete and b.isComplete then return false end
        -- Co-op bump
        if a._coopBump and not b._coopBump then return true end
        if not a._coopBump and b._coopBump then return false end
        -- Campaign quests above side-quests
        if a._isCampaignQuest and not b._isCampaignQuest then return true end
        if not a._isCampaignQuest and b._isCampaignQuest then return false end
        -- Higher progress first
        return (a._progressPct or 0) > (b._progressPct or 0)
    end)

    -- Sort NEXT bucket: time-sensitive -> upgrades -> completed -> co-op -> campaign -> flight cluster -> proximity
    -- Group quests by nearest flight node for logical travel routing
    table.sort(nextQuests, function(a, b)
        -- Time-sensitive global override
        local aTP = a._timePriority or 1
        local bTP = b._timePriority or 1
        if aTP ~= bTP then return aTP > bTP end
        -- Upgrade rewards pin to top of their tier
        if a._isUpgrade and not b._isUpgrade then return true end
        if not a._isUpgrade and b._isUpgrade then return false end
        -- Completed (turn-in) first
        if a.isComplete and not b.isComplete then return true end
        if not a.isComplete and b.isComplete then return false end
        -- Co-op bump
        if a._coopBump and not b._coopBump then return true end
        if not a._coopBump and b._coopBump then return false end
        -- Campaign quests above side-quests in same zone
        if a._isCampaignQuest and not b._isCampaignQuest then return true end
        if not a._isCampaignQuest and b._isCampaignQuest then return false end
        -- Flight path cluster grouping: quests near the same flight node sort together
        local aNode = a._nearestFlightNode and a._nearestFlightNode.nodeID or 0
        local bNode = b._nearestFlightNode and b._nearestFlightNode.nodeID or 0
        if aNode ~= bNode then
            -- Sort by node ID to cluster, but prefer closer nodes first
            local aDist = a._nearestFlightNode and a._nearestFlightNode.distance or 999
            local bDist = b._nearestFlightNode and b._nearestFlightNode.distance or 999
            if math.abs(aDist - bDist) > 0.01 then return aDist < bDist end
            return aNode < bNode
        end
        -- Within same flight cluster: proximity to player
        return (a._proximityScore or 100) < (b._proximityScore or 100)
    end)

    -- Sort LATER bucket: outleveled last, elite/group next
    table.sort(laterQuests, function(a, b)
        -- Trivial always last
        local aT = (a._laterReason == "Outleveled (Trivial)") and 1 or 0
        local bT = (b._laterReason == "Outleveled (Trivial)") and 1 or 0
        if aT ~= bT then return aT < bT end
        return (a._progressPct or 0) > (b._progressPct or 0)
    end)

    -- Detect synergy groups in NOW bucket
    data.synergyGroups = QuestData.FindSynergyGroups(nowQuests)

    -- Mark synergy quests
    for _, group in ipairs(data.synergyGroups) do
        for _, idx in ipairs(group.questIndices) do
            if nowQuests[idx] then
                nowQuests[idx]._synergyKeyword = group.keyword
            end
        end
    end

    -- ── Conditional Smart Section Extraction ──────────────────────────
    -- Pull completed and expiring quests out of spatial buckets into
    -- cross-cutting sections that render above the spatial model.
    -- Order: TURN IN extracts first, EXPIRING extracts from remainder.
    local turnInQuests = {}
    local expiringQuests = {}
    local bucketArrays = { nowQuests, nextQuests, laterQuests }
    local bucketKeyNames = { "now", "next", "later" }

    -- Pass 1: Extract completed quests → TURN IN section
    for bi = 1, #bucketArrays do
        local arr = bucketArrays[bi]
        for i = #arr, 1, -1 do
            if arr[i].isComplete then
                local quest = table.remove(arr, i)
                quest._originalBucket = bucketKeyNames[bi]
                turnInQuests[#turnInQuests + 1] = quest
            end
        end
    end

    -- Pass 2: Extract expiring quests → EXPIRING section
    local expiringThreshold = QLC.EXPIRING_EXTRACT_THRESHOLD or 7200
    for bi = 1, #bucketArrays do
        local arr = bucketArrays[bi]
        for i = #arr, 1, -1 do
            local quest = arr[i]
            if quest._isExpiringSoon
                or (type(quest._expiresInSeconds) == "number"
                    and quest._expiresInSeconds > 0
                    and quest._expiresInSeconds <= expiringThreshold) then
                quest = table.remove(arr, i)
                quest._originalBucket = bucketKeyNames[bi]
                expiringQuests[#expiringQuests + 1] = quest
            end
        end
    end

    -- Sort TURN IN: current zone first → upgrades → campaign → proximity
    table.sort(turnInQuests, function(a, b)
        if a._isInCurrentZone and not b._isInCurrentZone then return true end
        if not a._isInCurrentZone and b._isInCurrentZone then return false end
        if a._isUpgrade and not b._isUpgrade then return true end
        if not a._isUpgrade and b._isUpgrade then return false end
        if a._isCampaignQuest and not b._isCampaignQuest then return true end
        if not a._isCampaignQuest and b._isCampaignQuest then return false end
        return (a._proximityScore or 100) < (b._proximityScore or 100)
    end)

    -- Sort EXPIRING: most urgent (least time remaining) first
    table.sort(expiringQuests, function(a, b)
        local aTime = a._expiresInSeconds or 999999
        local bTime = b._expiresInSeconds or 999999
        if aTime ~= bTime then return aTime < bTime end
        return (a._proximityScore or 100) < (b._proximityScore or 100)
    end)

    data.turnIn = turnInQuests
    data.expiring = expiringQuests
    data.buckets.now = nowQuests
    data.buckets.next = nextQuests
    data.buckets.later = laterQuests
    data.zoneQuestCount = zoneQuestCount

    return data
end

function QuestData.ResolveCampaignCardFallback(headers)
    if type(headers) ~= "table" then
        return nil
    end

    local firstHeaderTitle = nil
    local totalQuests = 0
    local completedQuests = 0
    for _, header in ipairs(headers) do
        if type(header) == "table" and type(header.quests) == "table" then
            if not firstHeaderTitle and type(header.title) == "string" and header.title ~= "" then
                firstHeaderTitle = header.title
            end
            for _, quest in ipairs(header.quests) do
                totalQuests = totalQuests + 1
                if type(quest) == "table" and quest.isComplete then
                    completedQuests = completedQuests + 1
                end
            end
        end
    end

    if totalQuests < 1 then
        return nil
    end

    local name = firstHeaderTitle or "Campaign"
    local chapterName = string.format("%d Active Quests", totalQuests)
    return {
        name = name,
        chapterName = chapterName,
        progress = completedQuests,
        total = totalQuests,
    }
end

-- ============================================================================
-- OBJECTIVE RESOLUTION HELPERS
-- ============================================================================

function QuestData.CoerceObjectiveFlag(value)
    local valueType = type(value)
    if valueType == "boolean" then
        return value
    end
    if valueType == "number" then
        return value ~= 0
    end
    if valueType == "string" then
        local lowered = value:lower()
        if lowered == "1" or lowered == "true" or lowered == "yes" then
            return true
        end
        if lowered == "0" or lowered == "false" or lowered == "no" then
            return false
        end
    end
    return nil
end

function QuestData.NormalizeQuestObjectiveText(text)
    if type(text) ~= "string" then return nil end
    local compact = text:gsub("\r", " "):gsub("\n", " ")
    compact = compact:gsub("%s+", " ")
    compact = compact:gsub("^%s+", ""):gsub("%s+$", "")
    if compact == "" then
        return nil
    end
    return compact
end

function QuestData.ParseObjectiveFractionFromText(text)
    if type(text) ~= "string" then
        return nil, nil
    end

    local lhs, rhs = text:match("([%d,]+)%s*/%s*([%d,]+)")
    if lhs and rhs then
        local fulfilled = tonumber((lhs:gsub(",", "")))
        local required = tonumber((rhs:gsub(",", "")))
        if type(fulfilled) == "number" and type(required) == "number" and required > 0 then
            return fulfilled, required
        end
    end

    lhs, rhs = text:match("([%d,]+)%s+[oO][fF]%s+([%d,]+)")
    if lhs and rhs then
        local fulfilled = tonumber((lhs:gsub(",", "")))
        local required = tonumber((rhs:gsub(",", "")))
        if type(fulfilled) == "number" and type(required) == "number" and required > 0 then
            return fulfilled, required
        end
    end

    return nil, nil
end

function QuestData.ResolveSingleObjectiveProgress(objective)
    if type(objective) ~= "table" then
        return nil
    end

    local done = QuestData.CoerceObjectiveFlag(objective.finished)
    if done == nil then
        done = QuestData.CoerceObjectiveFlag(objective.isCompleted)
    end
    if done == nil then
        done = QuestData.CoerceObjectiveFlag(objective.completed)
    end
    if done == nil then
        done = QuestData.CoerceObjectiveFlag(objective.isFinished)
    end

    local text = QuestData.NormalizeQuestObjectiveText(objective.text)
    local fulfilled = objective.numFulfilled
    local required = objective.numRequired
    if type(fulfilled) ~= "number" then
        fulfilled = objective.fulfilled
    end
    if type(required) ~= "number" then
        required = objective.required
    end
    if type(required) ~= "number" then
        required = objective.numNeeded
    end

    if type(fulfilled) ~= "number" or type(required) ~= "number" or required <= 0 then
        local parsedFulfilled, parsedRequired = QuestData.ParseObjectiveFractionFromText(text)
        if type(parsedFulfilled) == "number" and type(parsedRequired) == "number" and parsedRequired > 0 then
            fulfilled = parsedFulfilled
            required = parsedRequired
        else
            fulfilled = nil
            required = nil
        end
    end

    local fraction = nil
    if type(fulfilled) == "number" and type(required) == "number" and required > 0 then
        fraction = fulfilled / required
        if fraction < 0 then
            fraction = 0
        elseif fraction > 1 then
            fraction = 1
        end
        if done == nil then
            done = fulfilled >= required
        end
    elseif done ~= nil then
        fraction = done and 1 or 0
    end

    local normalizedText = text
    if not normalizedText and type(fulfilled) == "number" and type(required) == "number" and required > 0 then
        normalizedText = "Objective"
    end

    -- Force 100% fill when objective is marked complete
    if done == true then
        fraction = 1
    end

    if done == nil and fraction == nil and not normalizedText then
        return nil
    end

    return {
        done = done,
        fraction = fraction,
        text = normalizedText,
        fulfilled = fulfilled,
        required = required,
    }
end

-- ============================================================================
-- OBJECTIVE DISPLAY ROWS & PROGRESS
-- ============================================================================

function QuestData.BuildQuestObjectiveDisplayRows(questData)
    local rows = {}
    local objectives = questData and questData.objectives
    if type(objectives) ~= "table" then
        return rows
    end

    for _, objective in ipairs(objectives) do
        local state = QuestData.ResolveSingleObjectiveProgress(objective)
        if state and state.text then
            local progressText = nil
            if type(state.fulfilled) == "number" and type(state.required) == "number" and state.required > 0 then
                local displayFulfilled = state.fulfilled
                if displayFulfilled < 0 then
                    displayFulfilled = 0
                elseif displayFulfilled > state.required then
                    displayFulfilled = state.required
                end
                local hasInlineProgress = QuestData.ParseObjectiveFractionFromText(state.text)
                if hasInlineProgress == nil then
                    progressText = string.format("%d/%d", displayFulfilled, state.required)
                end
            end
            rows[#rows + 1] = {
                text = state.text,
                finished = (state.done == true),
                progressText = progressText,
            }
        end
    end

    return rows
end

function QuestData.ResolveQuestObjectiveProgress(questData)
    -- Short-circuit: quest flagged complete -> 100%
    if questData and questData.isComplete then
        return 1, 1, 1.0
    end

    local objectives = questData and questData.objectives
    if type(objectives) ~= "table" or #objectives == 0 then
        return 0, 1, 0.0
    end

    local completed = 0
    local total = 0
    local summedFraction = 0.0

    for _, objective in ipairs(objectives) do
        local state = QuestData.ResolveSingleObjectiveProgress(objective)
        if state then
            total = total + 1
            local f = 0.0
            if state.done == true then
                completed = completed + 1
                f = 1.0
            elseif type(state.fraction) == "number" then
                f = state.fraction
                if f < 0 then f = 0 end
                if f > 1 then f = 1 end
            end
            summedFraction = summedFraction + f
        end
    end

    if total < 1 then
        return 0, 1, 0.0
    end

    local progressPct = summedFraction / total
    if progressPct < 0 then progressPct = 0.0 end
    if progressPct > 1 then progressPct = 1.0 end

    return completed, total, progressPct
end

-- ============================================================================
-- REGISTER MODULE
-- ============================================================================

Addon.QuestData = QuestData
