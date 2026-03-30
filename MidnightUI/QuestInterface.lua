-- =============================================================================
-- FILE PURPOSE:     Custom quest dialogue replacement. Replaces Blizzard's QuestFrame
--                   and GossipFrame with a cinematic panel: full-screen NPC 3D model on
--                   the left, typewriter-animated quest text on the right, reward grids,
--                   and objective progress. Handles quest detail, progress, completion,
--                   greeting selection, item rewards, and gossip option lists.
-- LOAD ORDER:       Loads after Map.lua, before AchievementsPanel.lua. Contains the same
--                   early-exit guard (useBlizzardQuestingInterface).
-- DEFINES:          CFG{} — all frame dimensions, typewriter settings, color palette.
--                   Main quest frame ("MidnightQuestFrame") and all sub-frames.
--                   Typewriter animation system (charIndex, timer, skip-on-click).
--                   Gossip option list builder and NPC 3D model control.
-- READS:            MidnightUISettings.General.useBlizzardQuestingInterface (early-exit gate).
--                   Quest API via _G at call time: _G.GetTitleText, _G.GetQuestText,
--                   _G.GetNumQuestRewards, _G.GetQuestItemInfo, etc.
--                   Gossip API: _G.GetNumGossipOptions, _G.GetGossipOptions, etc.
-- WRITES:           Hides/shows Blizzard QuestFrame and GossipFrame (SetAlpha 0 + SetShown).
--                   Advances NPC model SetModel, SetUnit per QUEST_DETAIL/GOSSIP_SHOW.
-- DEPENDS ON:       Blizzard_QuestUI (demand-loaded addon — NEVER upvalue its functions).
--                   All quest API calls use _G.FunctionName at call time; if Blizzard_QuestUI
--                   hasn't loaded yet when the event fires, the function may be nil.
-- USED BY:          Nothing — pure event handler. QuestFrame and GossipFrame hooks are
--                   installed at file load time.
-- KEY FLOWS:
--   QUEST_DETAIL     → ShowQuestDetail: typewriter-animate quest text, show Accept/Decline
--   QUEST_PROGRESS   → ShowQuestProgress: show objective progress, enable/disable Complete
--   QUEST_COMPLETE   → ShowQuestReward: build reward grid, show Choose/Done button
--   QUEST_GREETING   → ShowGreeting: render option list with gossip text header
--   GOSSIP_SHOW      → ShowGossip: render gossip option rows, NPC model
--   QUEST_FINISHED / GOSSIP_CLOSED → HideFrame (fade out)
-- GOTCHAS:
--   CRITICAL: Quest API functions (GetTitleText, AcceptQuest, GetQuestItemInfo, etc.)
--   are defined by Blizzard_QuestUI which is DEMAND-LOADED. They MUST be resolved
--   through _G at the moment of use — never upvalue them at file scope. The §1 UPVALUES
--   block intentionally omits all quest API to enforce this.
--   Typewriter animation: charIndex advances on C_Timer.After chain. Click anywhere on
--   the text area to skip remaining characters and show full text instantly.
--   NPC model: SetUnit("questnpc") + SetAnimation(0) on each quest show; the model
--   persists until the frame hides so the NPC stays "present" during the conversation.
-- NAVIGATION:
--   CFG{}                — all dimensions and timing (line ~63)
--   ShowQuestDetail()    — primary quest entry point (search "function ShowQuestDetail")
--   ShowQuestReward()    — reward grid builder (search "function ShowQuestReward")
--   ShowGossip()         — gossip option renderer (search "function ShowGossip")
-- =============================================================================

local ADDON_NAME = "MidnightUI"

-- ────────────────────────────────────────────────────────────────────────────
-- §1  UPVALUES
-- ────────────────────────────────────────────────────────────────────────────
local _G            = _G
local CreateFrame   = CreateFrame
local UIParent      = UIParent
local C_Timer       = C_Timer
local GetTime       = GetTime
local pcall         = pcall
local pairs         = pairs
local ipairs        = ipairs
local type          = type
local tostring      = tostring
local tonumber      = tonumber
local math          = math
local string        = string
local table         = table
local select        = select
local unpack        = unpack

-- IMPORTANT: Quest API functions (GetTitleText, AcceptQuest, etc.) are defined
-- by Blizzard_QuestUI which is DEMAND-LOADED.  They do NOT exist at file scope.
-- All quest API calls MUST resolve through _G at call time — never upvalue them.
local UnitExists            = UnitExists
local UnitName              = UnitName
local InCombatLockdown      = InCombatLockdown
local PlaySound             = PlaySound
local GameTooltip           = GameTooltip

-- ────────────────────────────────────────────────────────────────────────────
-- §2  EARLY EXIT — honour the Blizzard fallback toggle
-- ────────────────────────────────────────────────────────────────────────────
do
    local s = _G.MidnightUISettings
    if type(s) == "table" and type(s.General) == "table"
       and s.General.useBlizzardQuestingInterface == true then
        return
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- §3  CONFIGURATION & COLOR PALETTE
-- ────────────────────────────────────────────────────────────────────────────
local WHITE8X8    = "Interface\\Buttons\\WHITE8X8"
local TITLE_FONT  = "Fonts\\FRIZQT__.TTF"
local BODY_FONT   = "Fonts\\FRIZQT__.TTF"

local CFG = {
    -- Frame dimensions
    frameWidth       = 780,
    frameHeight      = 560,
    modelWidth       = 300,
    contentPadding   = 22,
    titleSize        = 24,
    bodySize         = 14,
    objectiveSize    = 13,
    sectionSize      = 15,
    buttonHeight     = 32,
    buttonWidth      = 155,
    rewardIconSize   = 40,
    rewardRowHeight  = 48,
    scrollWheelStep  = 40,
    greetingRowH     = 28,

    -- Typewriter
    typewriterRate   = 38,   -- visible chars per second
    typewriterDelay  = 0.15, -- delay before typewriter starts (seconds)

    -- Animation
    fadeInDuration   = 0.25,
    fadeOutDuration  = 0.18,
    modelFacing      = 0.00, -- radians, straight-on facing avoids side bias clipping

    -- Model lighting: warm, dramatic
    -- SetLight(enabled, omni, dirX, dirY, dirZ, ambI, ambR, ambG, ambB, dirI, dirR, dirG, dirB)
    modelLight = { true, false, -0.4, 0.8, -0.5, 0.95, 0.82, 0.72, 0.58, 0.7, 1.0, 0.94, 0.84 },

    -- Reward pool sizes
    maxRewardSlots   = 20,
    maxGreetingRows  = 24,
}

-- Warm parchment palette (harmonised with Map_Config.MAP_THEME_COLORS)
local C = {
    frameBg         = { 0.10, 0.08, 0.05, 0.97 },
    modelBg         = { 0.05, 0.04, 0.02, 1.00 },
    contentBg       = { 0.12, 0.10, 0.06, 0.97 },
    border          = { 0.76, 0.67, 0.46, 1.00 },  -- gold
    borderDim       = { 0.50, 0.42, 0.28, 0.70 },
    titleText       = { 0.96, 0.87, 0.58 },         -- bright gold
    bodyText        = { 0.94, 0.90, 0.80 },          -- warm cream
    mutedText       = { 0.71, 0.62, 0.44 },
    objectiveText   = { 0.86, 0.80, 0.64 },
    objectiveDone   = { 0.40, 0.80, 0.45 },
    sectionText     = { 0.90, 0.78, 0.48 },          -- section headers
    hoverBg         = { 0.20, 0.17, 0.12, 0.60 },
    buttonBg        = { 0.14, 0.12, 0.08, 0.95 },
    buttonBorder    = { 0.62, 0.54, 0.36, 1.00 },
    buttonText      = { 0.94, 0.86, 0.56 },
    buttonHover     = { 0.22, 0.19, 0.13, 0.95 },
    selectionGlow   = { 0.90, 0.75, 0.30, 0.55 },
    qualityCommon   = { 0.65, 0.65, 0.65 },
    qualityUncommon = { 0.12, 0.80, 0.12 },
    qualityRare     = { 0.00, 0.44, 0.87 },
    qualityEpic     = { 0.64, 0.21, 0.93 },
    questAvail      = { 1.00, 0.82, 0.20 },         -- yellow ! icon
    questActive     = { 0.75, 0.75, 0.75 },          -- gray ?
    questReady      = { 1.00, 0.82, 0.20 },         -- yellow ?
    glowAmbient     = { 0.85, 0.70, 0.35, 0.18 },
    scrollThumb     = { 0.60, 0.52, 0.35, 0.45 },
    scrollTrack     = { 0.20, 0.17, 0.12, 0.30 },
    divider         = { 0.60, 0.52, 0.35, 0.50 },
}

-- Quality color lookup
local QUALITY_COLORS = {
    [0] = C.qualityCommon,  -- Poor
    [1] = C.qualityCommon,  -- Common
    [2] = C.qualityUncommon,
    [3] = C.qualityRare,
    [4] = C.qualityEpic,
    [5] = { 1.00, 0.50, 0.00 },  -- Legendary
    [6] = { 0.90, 0.80, 0.50 },  -- Artifact
    [7] = { 0.00, 0.80, 1.00 },  -- Heirloom
}

-- ────────────────────────────────────────────────────────────────────────────
-- §4  MODULE STATE
-- ────────────────────────────────────────────────────────────────────────────
local State = {
    initialized        = false,
    currentMode        = nil,    -- "detail", "progress", "complete", "greeting", "gossip"
    chosenReward       = 0,      -- index of selected choice-reward (1-based), 0 = none
    typewriterAtoms    = nil,    -- parsed atom table
    typewriterVisTotal = 0,      -- total visible characters
    typewriterVisCur   = 0,      -- currently revealed count
    typewriterDone     = true,
    typewriterTimer    = 0,
    typewriterDelay    = 0,
    talkAnimWanted     = false,  -- keep NPC talk looping while typewriter is active
    talkAnimRetry      = 0,      -- retry timer for SetAnimation while model streams in
    talkAnimID         = nil,    -- resolved per-model talk animation ID
    talkAnimIndex      = 1,      -- current index in talk animation candidate list
    talkAnimNoState    = false,  -- true when model cannot report/support talk state reliably
    talkAnimRefreshes  = 0,      -- no-state refresh counter (used for soft rotation pacing)
    talkAnimApplied    = false,  -- true once talk animation has been applied this line
    scrollTarget       = 0,      -- smooth scroll target
    scrollCurrent      = 0,      -- current scroll position
    fadeAlpha          = 0,
    fadeDir            = 0,      -- 1 = fading in, -1 = fading out, 0 = idle
    fadeDone           = nil,    -- callback when fade-out completes
    modelDrift         = 0,      -- accumulated time for model sway
    questItemPending   = false,
    suppressClose      = false,
    lastGossipText     = "",     -- most recent non-empty gossip body text
    lastGossipNpc      = nil,    -- npc name tied to lastGossipText
    lastGossipTextAt   = 0,      -- GetTime() when lastGossipText was captured
    gossipRefreshNonce = 0,      -- cancels stale delayed gossip refresh timers
}

-- ────────────────────────────────────────────────────────────────────────────
-- §5  UTILITY FUNCTIONS
-- ────────────────────────────────────────────────────────────────────────────
local function UseBlizzardQuestingInterface()
    local s = _G.MidnightUISettings
    return type(s) == "table"
        and type(s.General) == "table"
        and s.General.useBlizzardQuestingInterface == true
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    -- Preserve multi-return APIs (e.g., GetQuestItemInfo) instead of truncating.
    local ok, r1, r2, r3, r4, r5, r6, r7, r8 = pcall(fn, ...)
    if not ok then
        return nil
    end
    return r1, r2, r3, r4, r5, r6, r7, r8
end

local function TrySetFont(fs, font, size, flags)
    if not fs or not fs.SetFont then return end
    pcall(fs.SetFont, fs, font or TITLE_FONT, size or 12, flags or "")
end

local function GetQualityColor(quality)
    return QUALITY_COLORS[quality] or C.qualityCommon
end

local function FormatMoney(copper)
    if not copper or copper <= 0 then return nil end
    local gold   = math.floor(copper / 10000)
    local silver = math.floor((copper % 10000) / 100)
    local cop    = copper % 100
    local parts = {}
    if gold > 0 then parts[#parts+1] = "|cffffd700" .. gold .. "g|r" end
    if silver > 0 then parts[#parts+1] = "|cffc7c7cf" .. silver .. "s|r" end
    if cop > 0 then parts[#parts+1] = "|cffeda55f" .. cop .. "c|r" end
    return table.concat(parts, " ")
end

local function Smoothstep(t)
    if t <= 0 then return 0 end
    if t >= 1 then return 1 end
    return t * t * (3 - 2 * t)
end

-- ────────────────────────────────────────────────────────────────────────────
-- §6  TYPEWRITER ENGINE
-- ────────────────────────────────────────────────────────────────────────────
-- Parses quest text into "atoms" so the typewriter never splits a WoW
-- colour escape sequence (|cFFRRGGBB … |r) mid-byte.

local Typewriter = {}

function Typewriter.Parse(text)
    if type(text) ~= "string" or text == "" then return {}, 0 end
    local atoms = {}
    local visCount = 0
    local i = 1
    local len = #text
    while i <= len do
        local ch = text:sub(i, i)
        if ch == "|" and i < len then
            local nc = text:sub(i + 1, i + 1)
            if nc == "c" and i + 9 <= len then
                -- |cFFRRGGBB — colour code prefix (10 bytes, invisible)
                atoms[#atoms + 1] = { v = false, t = text:sub(i, i + 9) }
                i = i + 10
            elseif nc == "r" then
                -- |r — colour reset (invisible)
                atoms[#atoms + 1] = { v = false, t = "|r" }
                i = i + 2
            elseif nc == "n" then
                -- |n — newline (visible)
                atoms[#atoms + 1] = { v = true, t = "\n" }
                visCount = visCount + 1
                i = i + 2
            elseif nc == "|" then
                -- || — escaped pipe (visible)
                atoms[#atoms + 1] = { v = true, t = "||" }
                visCount = visCount + 1
                i = i + 2
            elseif nc == "H" then
                -- |Hlink:...|h[text]|h — hyperlink; treat whole thing as opaque
                local linkEnd = text:find("|h", i + 2, true)
                if linkEnd then
                    local closeH = text:find("|h", linkEnd + 2, true)
                    if closeH then
                        local linkText = text:sub(i, closeH + 1)
                        atoms[#atoms + 1] = { v = true, t = linkText }
                        visCount = visCount + 1
                        i = closeH + 2
                    else
                        atoms[#atoms + 1] = { v = true, t = ch }
                        visCount = visCount + 1
                        i = i + 1
                    end
                else
                    atoms[#atoms + 1] = { v = true, t = ch }
                    visCount = visCount + 1
                    i = i + 1
                end
            else
                atoms[#atoms + 1] = { v = true, t = ch }
                visCount = visCount + 1
                i = i + 1
            end
        else
            atoms[#atoms + 1] = { v = true, t = ch }
            visCount = visCount + 1
            i = i + 1
        end
    end
    return atoms, visCount
end

function Typewriter.Build(atoms, visLimit)
    local parts = {}
    local vis = 0
    local inColor = false
    for _, atom in ipairs(atoms) do
        if atom.v then
            vis = vis + 1
            if vis > visLimit then break end
        end
        parts[#parts + 1] = atom.t
        if not atom.v then
            if atom.t:sub(1, 2) == "|c" then
                inColor = true
            elseif atom.t == "|r" then
                inColor = false
            end
        end
    end
    if inColor then
        parts[#parts + 1] = "|r"
    end
    return table.concat(parts)
end

-- ────────────────────────────────────────────────────────────────────────────
-- §7  MAIN FRAME CONSTRUCTION
-- ────────────────────────────────────────────────────────────────────────────
local QI = CreateFrame("Frame", "MidnightUI_QuestInterface", UIParent, "BackdropTemplate")
QI:SetSize(CFG.frameWidth, CFG.frameHeight)
QI:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
QI:SetFrameStrata("DIALOG")
QI:SetFrameLevel(100)
QI:Hide()
QI:EnableMouse(true)
QI:SetMovable(true)
QI:RegisterForDrag("LeftButton")
QI:SetScript("OnDragStart", function(self) self:StartMoving() end)
QI:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
QI:SetClampedToScreen(true)

-- Main backdrop: dark warm brown
QI:SetBackdrop({
    bgFile   = WHITE8X8,
    edgeFile = WHITE8X8,
    edgeSize = 2,
    insets   = { left = 2, right = 2, top = 2, bottom = 2 },
})
QI:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], C.frameBg[4])
QI:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], C.border[4])

-- Outer drop shadow (4 edge textures)
local function CreateShadowEdge(parent, point1, point2, w, h, isVertical)
    local tex = parent:CreateTexture(nil, "BACKGROUND", nil, -8)
    tex:SetTexture(WHITE8X8)
    tex:SetVertexColor(0, 0, 0, 0.45)
    if point1 and point2 then
        tex:SetPoint(point1[1], parent, point1[2], point1[3], point1[4])
        tex:SetPoint(point2[1], parent, point2[2], point2[3], point2[4])
    end
    if w then tex:SetWidth(w) end
    if h then tex:SetHeight(h) end
    return tex
end
-- Top shadow
CreateShadowEdge(QI,
    {"BOTTOMLEFT", "TOPLEFT", 4, 6}, {"BOTTOMRIGHT", "TOPRIGHT", -4, 6}, nil, 6)
-- Bottom shadow
CreateShadowEdge(QI,
    {"TOPLEFT", "BOTTOMLEFT", 4, -6}, {"TOPRIGHT", "BOTTOMRIGHT", -4, -6}, nil, 6)
-- Left shadow
CreateShadowEdge(QI,
    {"TOPRIGHT", "TOPLEFT", -6, -4}, {"BOTTOMRIGHT", "BOTTOMLEFT", -6, 4}, 6, nil)
-- Right shadow
CreateShadowEdge(QI,
    {"TOPLEFT", "TOPRIGHT", 6, -4}, {"BOTTOMLEFT", "BOTTOMRIGHT", 6, 4}, 6, nil)

-- Ambient background art (midnight campaign parchment, very subtle)
-- Atlas default: 770x598; stretched to fill, tinted dark & low alpha for mood
local ambientBg = QI:CreateTexture(nil, "BACKGROUND", nil, 1)
ambientBg:SetAtlas("completiondialog-midnightcampaign-background", false)
ambientBg:SetAllPoints(QI)
ambientBg:SetVertexColor(0.55, 0.48, 0.38, 0.12)
ambientBg:SetBlendMode("ADD")

-- Inner accent line at top (thin gold stripe)
local topAccent = QI:CreateTexture(nil, "ARTWORK", nil, 1)
topAccent:SetTexture(WHITE8X8)
topAccent:SetPoint("TOPLEFT", 3, -3)
topAccent:SetPoint("TOPRIGHT", -3, -3)
topAccent:SetHeight(1)
topAccent:SetVertexColor(C.border[1], C.border[2], C.border[3], 0.6)

-- ────────────────────────────────────────────────────────────────────────────
-- §7a  CLOSE BUTTON
-- ────────────────────────────────────────────────────────────────────────────
local closeBtn = CreateFrame("Button", nil, QI)
closeBtn:SetSize(28, 28)
closeBtn:SetPoint("TOPRIGHT", QI, "TOPRIGHT", -6, -6)
closeBtn:SetFrameLevel(QI:GetFrameLevel() + 10)

local closeTex = closeBtn:CreateFontString(nil, "OVERLAY")
TrySetFont(closeTex, TITLE_FONT, 18, "OUTLINE")
closeTex:SetPoint("CENTER", 0, 1)
closeTex:SetText("×")
closeTex:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.8)

closeBtn:SetScript("OnEnter", function()
    closeTex:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3], 1)
end)
closeBtn:SetScript("OnLeave", function()
    closeTex:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.8)
end)
closeBtn:SetScript("OnClick", function()
    local closed = false
    if State.currentMode == "gossip" then
        if type(C_GossipInfo) == "table" and type(C_GossipInfo.CloseGossip) == "function" then
            closed = pcall(C_GossipInfo.CloseGossip)
        elseif type(CloseGossip) == "function" then
            closed = pcall(CloseGossip)
        end
    end
    if not closed then
        closed = SafeCall(CloseQuest) and true or false
    end
    -- Always honor explicit X close even if server-side close API is delayed/no-op.
    if QI:IsShown() then
        QI:Hide()
        QI:SetAlpha(0)
    end
end)

-- ────────────────────────────────────────────────────────────────────────────
-- §8  MODEL PANEL (left side)
-- ────────────────────────────────────────────────────────────────────────────
local modelPanel = CreateFrame("Frame", nil, QI, "BackdropTemplate")
modelPanel:SetPoint("TOPLEFT", QI, "TOPLEFT", 4, -4)
modelPanel:SetPoint("BOTTOMLEFT", QI, "BOTTOMLEFT", 4, 4)
modelPanel:SetWidth(CFG.modelWidth)
modelPanel:SetBackdrop({
    bgFile = WHITE8X8,
    edgeFile = WHITE8X8,
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
})
modelPanel:SetBackdropColor(C.modelBg[1], C.modelBg[2], C.modelBg[3], C.modelBg[4])
modelPanel:SetBackdropBorderColor(C.borderDim[1], C.borderDim[2], C.borderDim[3], 0.35)

-- Ambient glow behind model (radial feel via layered textures)
local glowCenter = modelPanel:CreateTexture(nil, "BACKGROUND", nil, 1)
glowCenter:SetTexture(WHITE8X8)
glowCenter:SetPoint("CENTER", modelPanel, "CENTER", 0, 20)
glowCenter:SetSize(180, 220)
glowCenter:SetVertexColor(C.glowAmbient[1], C.glowAmbient[2], C.glowAmbient[3], C.glowAmbient[4])
glowCenter:SetBlendMode("ADD")
-- Prevent hard-edged square artifacts from the centre glow layer.
glowCenter:Hide()

-- Use the Blizzard radial glow texture for a softer halo
local glowSoft = modelPanel:CreateTexture(nil, "BACKGROUND", nil, 2)
glowSoft:SetTexture("Interface\\COMMON\\RingBorder")
glowSoft:SetPoint("CENTER", modelPanel, "CENTER", 0, 10)
glowSoft:SetSize(240, 280)
glowSoft:SetVertexColor(0.80, 0.65, 0.30, 0.08)
glowSoft:SetBlendMode("ADD")
glowSoft:Hide()

-- 3D NPC model
local npcModel = CreateFrame("PlayerModel", nil, modelPanel)
npcModel:SetPoint("TOPLEFT", modelPanel, "TOPLEFT", 6, -6)
npcModel:SetPoint("BOTTOMRIGHT", modelPanel, "BOTTOMRIGHT", -6, 6)
npcModel:SetFrameLevel(modelPanel:GetFrameLevel() + 2)

local NPC_ANIM_IDLE = 0
local NPC_ANIM_TALK_CANDIDATES = { 64, 60, 65 } -- start on stronger talk, soft-fallback to subtler variants
local NPC_ANIM_APPLY_RETRY_SECONDS = 0.10 -- rapid retries only until talk applies
local NPC_ANIM_STATE_POLL_SECONDS = 0.20 -- check state without restarting every frame
local NPC_ANIM_NOSTATE_WARMUP_SECONDS = 0.90 -- first no-state follow-up starts early but not instant
local NPC_ANIM_NOSTATE_REAPPLY_SECONDS = 2.85 -- give one-shot talk sequence time to finish before restart

local function GetNPCAnimationSafe()
    if not npcModel or not npcModel:IsShown() then
        return nil, "model_hidden"
    end
    if type(npcModel.GetAnimation) ~= "function" then
        return nil, "no_GetAnimation"
    end
    local ok, animID = pcall(npcModel.GetAnimation, npcModel)
    if not ok then
        return nil, "get_error:" .. tostring(animID)
    end
    return animID, nil
end

local function ResolveNPCTalkAnimation()
    if not npcModel or type(npcModel.HasAnimation) ~= "function" then
        return NPC_ANIM_TALK_CANDIDATES[1], 1, false
    end
    for i = 1, #NPC_ANIM_TALK_CANDIDATES do
        local animID = NPC_ANIM_TALK_CANDIDATES[i]
        local ok, hasAnim = pcall(npcModel.HasAnimation, npcModel, animID)
        if ok and hasAnim then
            return animID, i, true
        end
    end
    return NPC_ANIM_TALK_CANDIDATES[1], 1, false
end

local function SetNPCAnimationSafe(animID, source)
    if not npcModel or not npcModel:IsShown() or type(npcModel.SetAnimation) ~= "function" then
        return false
    end
    local ok, err = pcall(npcModel.SetAnimation, npcModel, animID, 0)
    if not ok then
        ok, err = pcall(npcModel.SetAnimation, npcModel, animID)
    end
    if not ok then
        return false
    end
    return true
end

local function IsNPCTalkAnimationActive()
    if not npcModel or not npcModel:IsShown() then
        return false, nil, "model_hidden"
    end
    local currentAnimID, reason = GetNPCAnimationSafe()
    if reason then
        if reason == "no_GetAnimation" then
            -- Unknown state API; keep previous fallback behavior but expose reason.
            return State.talkAnimApplied and true or false, nil, reason
        end
        return false, nil, reason
    end
    if currentAnimID == State.talkAnimID then
        return true, currentAnimID, "match"
    end
    return false, currentAnimID, "mismatch"
end

-- Right-edge gradient overlay (model blends into content area)
local modelFade = modelPanel:CreateTexture(nil, "OVERLAY", nil, 7)
modelFade:SetTexture(WHITE8X8)
modelFade:SetPoint("TOPRIGHT", modelPanel, "TOPRIGHT", 0, 0)
modelFade:SetPoint("BOTTOMRIGHT", modelPanel, "BOTTOMRIGHT", 0, 0)
modelFade:SetWidth(40)
modelFade:SetGradient("HORIZONTAL",
    CreateColor(C.modelBg[1], C.modelBg[2], C.modelBg[3], 0),
    CreateColor(C.contentBg[1], C.contentBg[2], C.contentBg[3], 0.7))

-- NPC name under the model
local npcNameText = modelPanel:CreateFontString(nil, "OVERLAY")
TrySetFont(npcNameText, TITLE_FONT, 13, "OUTLINE")
npcNameText:SetPoint("BOTTOM", modelPanel, "BOTTOM", 0, 12)
npcNameText:SetWidth(CFG.modelWidth - 20)
npcNameText:SetJustifyH("CENTER")
npcNameText:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.9)
npcNameText:Hide()

-- ────────────────────────────────────────────────────────────────────────────
-- §9  CONTENT PANEL (right side)
-- ────────────────────────────────────────────────────────────────────────────
local contentPanel = CreateFrame("Frame", nil, QI, "BackdropTemplate")
contentPanel:SetPoint("TOPLEFT", modelPanel, "TOPRIGHT", 0, 0)
contentPanel:SetPoint("BOTTOMRIGHT", QI, "BOTTOMRIGHT", -4, 4)
contentPanel:SetBackdrop({
    bgFile = WHITE8X8,
    edgeFile = WHITE8X8,
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
})
contentPanel:SetBackdropColor(C.contentBg[1], C.contentBg[2], C.contentBg[3], C.contentBg[4])
contentPanel:SetBackdropBorderColor(C.borderDim[1], C.borderDim[2], C.borderDim[3], 0.2)

-- Subtle top glow inside content panel (warm light wash)
local contentTopGlow = contentPanel:CreateTexture(nil, "BACKGROUND", nil, 1)
contentTopGlow:SetTexture(WHITE8X8)
contentTopGlow:SetPoint("TOPLEFT", 2, -2)
contentTopGlow:SetPoint("TOPRIGHT", -2, -2)
contentTopGlow:SetHeight(50)
contentTopGlow:SetVertexColor(0.18, 0.15, 0.10, 0.35)

-- ── Title ──
local titleText = contentPanel:CreateFontString(nil, "OVERLAY")
TrySetFont(titleText, TITLE_FONT, CFG.titleSize, "OUTLINE")
titleText:SetPoint("TOPLEFT", contentPanel, "TOPLEFT", CFG.contentPadding, -CFG.contentPadding)
titleText:SetPoint("TOPRIGHT", contentPanel, "TOPRIGHT", -CFG.contentPadding - 30, -CFG.contentPadding)
titleText:SetJustifyH("LEFT")
titleText:SetWordWrap(true)
titleText:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
titleText:SetShadowColor(0, 0, 0, 0.7)
titleText:SetShadowOffset(1, -1)

-- ── Divider under title ──
local titleDivider = contentPanel:CreateTexture(nil, "ARTWORK", nil, 2)
titleDivider:SetTexture(WHITE8X8)
titleDivider:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -12)
titleDivider:SetPoint("RIGHT", contentPanel, "RIGHT", -CFG.contentPadding, 0)
titleDivider:SetHeight(1)
titleDivider:SetVertexColor(C.divider[1], C.divider[2], C.divider[3], C.divider[4])

-- Ornamental accent dot on divider left
local dividerDot = contentPanel:CreateTexture(nil, "ARTWORK", nil, 3)
dividerDot:SetTexture(WHITE8X8)
dividerDot:SetPoint("LEFT", titleDivider, "LEFT", -2, 0)
dividerDot:SetSize(5, 5)
dividerDot:SetVertexColor(C.border[1], C.border[2], C.border[3], 0.7)

-- ────────────────────────────────────────────────────────────────────────────
-- §10  SCROLL AREA (for quest body, objectives, rewards)
-- ────────────────────────────────────────────────────────────────────────────
local BUTTON_BAR_HEIGHT = CFG.buttonHeight + 28  -- space reserved at bottom

local scrollFrame = CreateFrame("ScrollFrame", nil, contentPanel)
scrollFrame:SetPoint("TOPLEFT", titleDivider, "BOTTOMLEFT", 0, -14)
scrollFrame:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT",
    -CFG.contentPadding, BUTTON_BAR_HEIGHT)
scrollFrame:EnableMouseWheel(true)

local scrollContent = CreateFrame("Frame", nil, scrollFrame)
-- NOTE: scrollFrame:GetWidth() is 0 at file scope (not yet laid out).
-- We set a fallback width here; OnSizeChanged corrects it once layout runs.
scrollContent:SetWidth(1)
scrollFrame:SetScrollChild(scrollContent)

-- Dynamically size scrollContent width on parent resize
scrollFrame:SetScript("OnSizeChanged", function(self, w)
    if w and w > 0 then
        scrollContent:SetWidth(w)
    end
end)

-- Mouse wheel handler
scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local maxScroll = self:GetVerticalScrollRange()
    if maxScroll <= 0 then return end
    State.scrollTarget = State.scrollTarget - (delta * CFG.scrollWheelStep)
    State.scrollTarget = math.max(0, math.min(maxScroll, State.scrollTarget))
end)

-- Click-to-skip typewriter: clicking the scroll area completes the text
scrollFrame:SetScript("OnMouseDown", function()
    if not State.typewriterDone then
        State.typewriterVisCur = State.typewriterVisTotal
        State.typewriterDone = true
        State.talkAnimWanted = false
        State.talkAnimRetry = 0
        State.talkAnimID = nil
        State.talkAnimIndex = 1
        State.talkAnimNoState = false
        State.talkAnimRefreshes = 0
        State.talkAnimApplied = false
        -- Stop talk animation immediately
        if npcModel:IsShown() then
            SetNPCAnimationSafe(NPC_ANIM_IDLE, "skip")
        end
    end
end)

-- Minimal scroll position indicator (thin vertical bar on the right)
local scrollTrack = scrollFrame:CreateTexture(nil, "OVERLAY", nil, 1)
scrollTrack:SetTexture(WHITE8X8)
scrollTrack:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -1, 0)
scrollTrack:SetPoint("BOTTOMRIGHT", scrollFrame, "BOTTOMRIGHT", -1, 0)
scrollTrack:SetWidth(3)
scrollTrack:SetVertexColor(C.scrollTrack[1], C.scrollTrack[2], C.scrollTrack[3], C.scrollTrack[4])

local scrollThumb = scrollFrame:CreateTexture(nil, "OVERLAY", nil, 2)
scrollThumb:SetTexture(WHITE8X8)
scrollThumb:SetWidth(3)
scrollThumb:SetVertexColor(C.scrollThumb[1], C.scrollThumb[2], C.scrollThumb[3], C.scrollThumb[4])

-- ────────────────────────────────────────────────────────────────────────────
-- §11  SCROLL CONTENT ELEMENTS
-- ────────────────────────────────────────────────────────────────────────────
-- Quest body text (typewriter target)
local bodyTextFS = scrollContent:CreateFontString(nil, "OVERLAY")
TrySetFont(bodyTextFS, BODY_FONT, CFG.bodySize, "")
bodyTextFS:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 0, 0)
bodyTextFS:SetPoint("TOPRIGHT", scrollContent, "TOPRIGHT", -8, 0)
bodyTextFS:SetJustifyH("LEFT")
bodyTextFS:SetWordWrap(true)
bodyTextFS:SetSpacing(4)
bodyTextFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

-- Objectives section header
local objHeaderFS = scrollContent:CreateFontString(nil, "OVERLAY")
TrySetFont(objHeaderFS, TITLE_FONT, CFG.sectionSize, "OUTLINE")
objHeaderFS:SetPoint("TOPLEFT", bodyTextFS, "BOTTOMLEFT", 0, -16)
objHeaderFS:SetJustifyH("LEFT")
objHeaderFS:SetTextColor(C.sectionText[1], C.sectionText[2], C.sectionText[3])
objHeaderFS:SetText("Objectives")
objHeaderFS:Hide()

-- Objective divider
local objDivider = scrollContent:CreateTexture(nil, "ARTWORK")
objDivider:SetTexture(WHITE8X8)
objDivider:SetPoint("TOPLEFT", objHeaderFS, "BOTTOMLEFT", 0, -4)
objDivider:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
objDivider:SetHeight(1)
objDivider:SetVertexColor(C.divider[1], C.divider[2], C.divider[3], 0.3)
objDivider:Hide()

-- Objective text lines (simple FontString — objectives are usually short)
local objTextFS = scrollContent:CreateFontString(nil, "OVERLAY")
TrySetFont(objTextFS, BODY_FONT, CFG.objectiveSize, "")
objTextFS:SetPoint("TOPLEFT", objDivider, "BOTTOMLEFT", 4, -6)
objTextFS:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
objTextFS:SetJustifyH("LEFT")
objTextFS:SetWordWrap(true)
objTextFS:SetSpacing(4)
objTextFS:SetTextColor(C.objectiveText[1], C.objectiveText[2], C.objectiveText[3])
objTextFS:Hide()

-- Required items section header (for QUEST_PROGRESS)
local reqHeaderFS = scrollContent:CreateFontString(nil, "OVERLAY")
TrySetFont(reqHeaderFS, TITLE_FONT, CFG.sectionSize, "OUTLINE")
reqHeaderFS:SetJustifyH("LEFT")
reqHeaderFS:SetTextColor(C.sectionText[1], C.sectionText[2], C.sectionText[3])
reqHeaderFS:SetText("Required Items")
reqHeaderFS:Hide()

-- Rewards section header
local rewardHeaderFS = scrollContent:CreateFontString(nil, "OVERLAY")
TrySetFont(rewardHeaderFS, TITLE_FONT, CFG.sectionSize, "OUTLINE")
rewardHeaderFS:SetJustifyH("LEFT")
rewardHeaderFS:SetTextColor(C.sectionText[1], C.sectionText[2], C.sectionText[3])
rewardHeaderFS:Hide()

local rewardDivider = scrollContent:CreateTexture(nil, "ARTWORK")
rewardDivider:SetTexture(WHITE8X8)
rewardDivider:SetHeight(1)
rewardDivider:SetVertexColor(C.divider[1], C.divider[2], C.divider[3], 0.3)
rewardDivider:Hide()

-- Money & XP text (kept as fallback, normally hidden)
local moneyXPFS = scrollContent:CreateFontString(nil, "OVERLAY")
TrySetFont(moneyXPFS, BODY_FONT, CFG.objectiveSize, "")
moneyXPFS:SetJustifyH("LEFT")
moneyXPFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
moneyXPFS:Hide()

-- Sub-section labels (text only, no divider lines)
local function CreateSubLabel(parent)
    local lbl = parent:CreateFontString(nil, "OVERLAY")
    TrySetFont(lbl, BODY_FONT, 11, "")
    lbl:SetJustifyH("LEFT")
    lbl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
    lbl:Hide()
    return lbl
end

local lootSubLabel    = CreateSubLabel(scrollContent)
local currencySubLabel = CreateSubLabel(scrollContent)
local repSubLabel     = CreateSubLabel(scrollContent)

-- ────────────────────────────────────────────────────────────────────────────
-- §12  REWARD ITEM FRAME POOL
-- ────────────────────────────────────────────────────────────────────────────
local rewardPool = {}

local function SetRewardIconBorder(frame, r, g, b, a)
    if not frame or not frame._qBorderParts then return end
    local alpha = a or 1
    for i = 1, #frame._qBorderParts do
        local part = frame._qBorderParts[i]
        if part and part.SetVertexColor then
            part:SetVertexColor(r, g, b, alpha)
        end
    end
end

local EQUIP_LOC_TO_INVENTORY_SLOTS = {
    INVTYPE_HEAD = { 1 },
    INVTYPE_NECK = { 2 },
    INVTYPE_SHOULDER = { 3 },
    INVTYPE_BODY = { 4 },
    INVTYPE_CHEST = { 5 },
    INVTYPE_ROBE = { 5 },
    INVTYPE_WAIST = { 6 },
    INVTYPE_LEGS = { 7 },
    INVTYPE_FEET = { 8 },
    INVTYPE_WRIST = { 9 },
    INVTYPE_HAND = { 10 },
    INVTYPE_FINGER = { 11, 12 },
    INVTYPE_TRINKET = { 13, 14 },
    INVTYPE_CLOAK = { 15 },
    INVTYPE_WEAPON = { 16, 17 },
    INVTYPE_SHIELD = { 17 },
    INVTYPE_HOLDABLE = { 17 },
    INVTYPE_2HWEAPON = { 16 },
    INVTYPE_WEAPONMAINHAND = { 16 },
    INVTYPE_WEAPONOFFHAND = { 17 },
    INVTYPE_RANGED = { 16 },
    INVTYPE_RANGEDRIGHT = { 16 },
}

local function GetItemLevelFromLink(itemLink)
    if not itemLink then return nil end
    local level = nil
    if C_Item and C_Item.GetDetailedItemLevelInfo then
        level = SafeCall(C_Item.GetDetailedItemLevelInfo, itemLink)
    elseif GetDetailedItemLevelInfo then
        level = SafeCall(GetDetailedItemLevelInfo, itemLink)
    end
    if type(level) ~= "number" or level <= 0 then
        return nil
    end
    return math.floor(level + 0.5)
end

local function GetQuestItemLevel(itemType, index)
    return GetItemLevelFromLink(SafeCall(GetQuestItemLink, itemType, index))
end

-- Get the effective item level for an equipped slot, accounting for
-- Timewalking/level-scaling items where GetDetailedItemLevelInfo returns
-- the item's original ilvl (e.g. 655) instead of the scaled ilvl (e.g. 102).
local function GetEquippedSlotItemLevel(slotID)
    -- Prefer C_Item.GetCurrentItemLevel which returns the actual effective ilvl
    if C_Item and C_Item.GetCurrentItemLevel then
        local itemLoc = ItemLocation:CreateFromEquipmentSlot(slotID)
        if itemLoc and C_Item.DoesItemExist(itemLoc) then
            local effectiveLevel = SafeCall(C_Item.GetCurrentItemLevel, itemLoc)
            if type(effectiveLevel) == "number" and effectiveLevel > 0 then
                return math.floor(effectiveLevel + 0.5)
            end
        end
    end
    -- Fallback to link-based lookup
    local equippedLink = SafeCall(GetInventoryItemLink, "player", slotID)
    return GetItemLevelFromLink(equippedLink)
end

local function GetEquippedItemLevelForEquipLoc(equipLoc)
    local slots = EQUIP_LOC_TO_INVENTORY_SLOTS[equipLoc]
    if not slots then return nil end

    -- For multi-slot categories (rings/trinkets/1H weapons), compare against the
    -- lowest equipped ilvl slot to reflect the most likely replacement.
    local lowest = nil
    for i = 1, #slots do
        local equippedLevel = GetEquippedSlotItemLevel(slots[i])
        if equippedLevel and (not lowest or equippedLevel < lowest) then
            lowest = equippedLevel
        end
    end
    return lowest
end

local function GetQuestItemLevelDelta(itemType, index, rewardItemLevel)
    if type(rewardItemLevel) ~= "number" then return nil end
    local link = SafeCall(GetQuestItemLink, itemType, index)
    if not link then return nil end
    local _, _, _, equipLoc = SafeCall(GetItemInfoInstant, link)
    if type(equipLoc) ~= "string" or equipLoc == "" then
        return nil
    end
    local equippedItemLevel = GetEquippedItemLevelForEquipLoc(equipLoc)
    if type(equippedItemLevel) ~= "number" then
        return nil
    end
    return rewardItemLevel - equippedItemLevel
end

local function SetRewardItemLevelLine(frame, itemType, index)
    if not frame or not frame._ilvl then return end
    -- Only show ilvl for equippable gear (Weapon classID=2, Armor classID=4)
    local link = SafeCall(GetQuestItemLink, itemType, index)
    if not link then frame._ilvl:SetText(""); frame._ilvl:Hide(); return end
    local _, _, _, equipLoc, _, classID = SafeCall(GetItemInfoInstant, link)
    if not classID or (classID ~= 2 and classID ~= 4) then
        frame._ilvl:SetText("")
        frame._ilvl:Hide()
        return
    end
    -- Also require a valid equip slot
    if type(equipLoc) ~= "string" or equipLoc == "" or not EQUIP_LOC_TO_INVENTORY_SLOTS[equipLoc] then
        frame._ilvl:SetText("")
        frame._ilvl:Hide()
        return
    end
    local itemLevel = GetItemLevelFromLink(link)
    if not itemLevel then
        frame._ilvl:SetText("")
        frame._ilvl:Hide()
        return
    end

    local text = "iLvl " .. tostring(itemLevel)
    local diff = GetQuestItemLevelDelta(itemType, index, itemLevel)
    if type(diff) == "number" then
        if diff > 0 then
            text = text .. " (|cff33ff66+" .. tostring(diff) .. "|r)"
        elseif diff < 0 then
            text = text .. " (|cffff5555" .. tostring(diff) .. "|r)"
        else
            text = text .. " (|cffb0b0b00|r)"
        end
    end

    frame._ilvl:SetText(text)
    frame._ilvl:Show()
end

local function CreateRewardFrame(parent)
    local f = CreateFrame("Button", nil, parent, "BackdropTemplate")
    f:SetSize(200, CFG.rewardRowHeight)
    f:SetBackdrop({
        bgFile   = WHITE8X8,
        edgeFile = WHITE8X8,
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(0, 0, 0, 0)
    f:SetBackdropBorderColor(0, 0, 0, 0)

    -- Item icon
    local icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(CFG.rewardIconSize, CFG.rewardIconSize)
    icon:SetPoint("LEFT", f, "LEFT", 4, 0)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- slight inset to remove border
    f._icon = icon

    -- Quality border on icon (edge-only; never covers icon fill)
    local borderThickness = 2
    local qTop = f:CreateTexture(nil, "OVERLAY")
    qTop:SetTexture(WHITE8X8)
    qTop:SetPoint("TOPLEFT", icon, "TOPLEFT", -borderThickness, borderThickness)
    qTop:SetPoint("TOPRIGHT", icon, "TOPRIGHT", borderThickness, borderThickness)
    qTop:SetHeight(borderThickness)
    local qBottom = f:CreateTexture(nil, "OVERLAY")
    qBottom:SetTexture(WHITE8X8)
    qBottom:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", -borderThickness, -borderThickness)
    qBottom:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", borderThickness, -borderThickness)
    qBottom:SetHeight(borderThickness)
    local qLeft = f:CreateTexture(nil, "OVERLAY")
    qLeft:SetTexture(WHITE8X8)
    qLeft:SetPoint("TOPLEFT", icon, "TOPLEFT", -borderThickness, borderThickness)
    qLeft:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", -borderThickness, -borderThickness)
    qLeft:SetWidth(borderThickness)
    local qRight = f:CreateTexture(nil, "OVERLAY")
    qRight:SetTexture(WHITE8X8)
    qRight:SetPoint("TOPRIGHT", icon, "TOPRIGHT", borderThickness, borderThickness)
    qRight:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", borderThickness, -borderThickness)
    qRight:SetWidth(borderThickness)
    f._qBorderParts = { qTop, qBottom, qLeft, qRight }
    SetRewardIconBorder(f, C.borderDim[1], C.borderDim[2], C.borderDim[3], 0.5)

    -- Item name
    local name = f:CreateFontString(nil, "OVERLAY")
    TrySetFont(name, BODY_FONT, 13, "")
    name:SetPoint("BOTTOMLEFT", icon, "RIGHT", 14, 2)
    name:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    f._name = name

    -- Item level line (shown when an equippable reward has ilvl data)
    local ilvl = f:CreateFontString(nil, "OVERLAY")
    TrySetFont(ilvl, BODY_FONT, 11, "")
    ilvl:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
    ilvl:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    ilvl:SetJustifyH("LEFT")
    ilvl:SetWordWrap(false)
    ilvl:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.95)
    ilvl:Hide()
    f._ilvl = ilvl

    -- Item count (bottom-right of icon)
    local count = f:CreateFontString(nil, "OVERLAY")
    TrySetFont(count, BODY_FONT, 11, "OUTLINE")
    count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -2, 2)
    count:SetJustifyH("RIGHT")
    count:SetTextColor(1, 1, 1, 1)
    f._count = count

    -- Selection glow (hidden by default)
    local glow = f:CreateTexture(nil, "BACKGROUND")
    glow:SetTexture(WHITE8X8)
    glow:SetAllPoints(f)
    glow:SetVertexColor(C.selectionGlow[1], C.selectionGlow[2], C.selectionGlow[3], C.selectionGlow[4])
    glow:Hide()
    f._glow = glow

    -- Hover effect
    f:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.hoverBg[1], C.hoverBg[2], C.hoverBg[3], C.hoverBg[4])
        self:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 0.6)
        -- Show tooltip
        if self._tooltipType and self._tooltipIndex then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self._tooltipType == "reward" then
                GameTooltip:SetQuestItem(self._tooltipType, self._tooltipIndex)
            elseif self._tooltipType == "choice" then
                GameTooltip:SetQuestItem(self._tooltipType, self._tooltipIndex)
            elseif self._tooltipType == "required" then
                GameTooltip:SetQuestItem(self._tooltipType, self._tooltipIndex)
            elseif self._tooltipType == "currency" then
                if GameTooltip.SetQuestCurrency then
                    GameTooltip:SetQuestCurrency("reward", self._tooltipIndex)
                elseif self._currencyID and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
                    local info = C_CurrencyInfo.GetCurrencyInfo(self._currencyID)
                    if info then
                        GameTooltip:SetText(info.name or "Currency", 1, 1, 1)
                        if info.description and info.description ~= "" then
                            GameTooltip:AddLine(info.description, 0.7, 0.7, 0.7, true)
                        end
                    end
                end
            end
            GameTooltip:Show()
        end
    end)
    f:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0)
        self:SetBackdropBorderColor(0, 0, 0, 0)
        GameTooltip:Hide()
    end)

    f:Hide()
    return f
end

-- Pre-create reward slots
for i = 1, CFG.maxRewardSlots do
    rewardPool[i] = CreateRewardFrame(scrollContent)
end

-- ────────────────────────────────────────────────────────────────────────────
-- §13  GREETING QUEST LIST POOL
-- ────────────────────────────────────────────────────────────────────────────
local greetingPool = {}
local GOSSIP_OPTION_ICON_ATLASES = {
    "communities-icon-chat",
    "transmog-icon-chat",
}
local QUEST_AVAILABLE_ICON_ATLAS = "QuestLog-tab-icon-quest"

local function CreateGreetingRow(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetHeight(CFG.greetingRowH)

    -- Hover highlight
    local hl = f:CreateTexture(nil, "BACKGROUND")
    hl:SetTexture(WHITE8X8)
    hl:SetAllPoints(f)
    hl:SetVertexColor(C.hoverBg[1], C.hoverBg[2], C.hoverBg[3], 0)
    f._hl = hl

    -- Icon (! or ?)
    local icon = f:CreateFontString(nil, "OVERLAY")
    TrySetFont(icon, TITLE_FONT, 16, "OUTLINE")
    icon:SetPoint("LEFT", f, "LEFT", 4, 0)
    icon:SetWidth(20)
    f._icon = icon

    -- Atlas marker used by gossip conversation options.
    local iconAtlas = f:CreateTexture(nil, "OVERLAY")
    iconAtlas:SetPoint("CENTER", icon, "CENTER", 0, 0)
    iconAtlas:SetSize(16, 16)
    local atlasApplied = false
    if iconAtlas.SetAtlas then
        for _, atlasName in ipairs(GOSSIP_OPTION_ICON_ATLASES) do
            atlasApplied = pcall(iconAtlas.SetAtlas, iconAtlas, atlasName, false)
            if atlasApplied then
                break
            end
        end
    end
    if atlasApplied then
        -- Additive blend suppresses dark atlas backing pixels and keeps only the bright glyph.
        iconAtlas:SetBlendMode("ADD")
        iconAtlas:SetVertexColor(1, 1, 1, 0.95)
    else
        iconAtlas:SetBlendMode("BLEND")
        iconAtlas:SetTexture("Interface\\Buttons\\WHITE8X8")
        iconAtlas:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.9)
    end
    iconAtlas:Hide()
    f._iconAtlas = iconAtlas

    -- Quest title
    local title = f:CreateFontString(nil, "OVERLAY")
    TrySetFont(title, BODY_FONT, CFG.bodySize, "")
    title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    title:SetPoint("RIGHT", f, "RIGHT", -8, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(true)
    title:SetMaxLines(0)
    f._title = title

    f:SetScript("OnEnter", function(self)
        self._hl:SetVertexColor(C.hoverBg[1], C.hoverBg[2], C.hoverBg[3], C.hoverBg[4])
        self._title:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    end)
    f:SetScript("OnLeave", function(self)
        self._hl:SetVertexColor(C.hoverBg[1], C.hoverBg[2], C.hoverBg[3], 0)
        self._title:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    end)

    f:Hide()
    return f
end

-- Resize a greeting row to fit its wrapped title text.
local function FitGreetingRowHeight(row)
    if not row or not row._title then return end
    local textHeight = row._title:GetStringHeight() or 0
    local minH = CFG.greetingRowH
    row:SetHeight(math.max(minH, textHeight + 8))
end

local function SetRowAtlasIcon(row, atlasSource, size, blendMode, rgba, fallbackText, fallbackColor)
    if not row or not row._icon then return end
    local atlasTex = row._iconAtlas
    local applied = false

    if atlasTex and atlasTex.SetAtlas then
        if type(atlasSource) == "table" then
            for i = 1, #atlasSource do
                local atlasName = atlasSource[i]
                if type(atlasName) == "string" and atlasName ~= "" then
                    applied = pcall(atlasTex.SetAtlas, atlasTex, atlasName, false)
                    if applied then break end
                end
            end
        elseif type(atlasSource) == "string" and atlasSource ~= "" then
            applied = pcall(atlasTex.SetAtlas, atlasTex, atlasSource, false)
        end
    end

    if applied and atlasTex then
        row._icon:SetText("")
        row._icon:Hide()
        atlasTex:SetSize(size or 16, size or 16)
        if blendMode and atlasTex.SetBlendMode then
            atlasTex:SetBlendMode(blendMode)
        end
        if rgba then
            atlasTex:SetVertexColor(rgba[1], rgba[2], rgba[3], rgba[4] or 1)
        else
            atlasTex:SetVertexColor(1, 1, 1, 1)
        end
        atlasTex:Show()
        return
    end

    row._icon:Show()
    if atlasTex then atlasTex:Hide() end
    row._icon:SetText(fallbackText or "")
    if fallbackColor then
        row._icon:SetTextColor(fallbackColor[1], fallbackColor[2], fallbackColor[3], fallbackColor[4] or 1)
    end
end

local function SetRowAvailableQuestIcon(row)
    SetRowAtlasIcon(
        row,
        QUEST_AVAILABLE_ICON_ATLAS,
        16,
        "BLEND",
        { 1, 1, 1, 1 },
        "!",
        C.questAvail
    )
end

local function SetRowGossipOptionIcon(row)
    SetRowAtlasIcon(
        row,
        GOSSIP_OPTION_ICON_ATLASES,
        16,
        "ADD",
        { 1, 1, 1, 0.95 },
        ">",
        C.mutedText
    )
end

for i = 1, CFG.maxGreetingRows do
    greetingPool[i] = CreateGreetingRow(scrollContent)
end

-- ────────────────────────────────────────────────────────────────────────────
-- §14  ACTION BUTTONS (Accept / Decline / Complete / Continue / Goodbye)
-- ────────────────────────────────────────────────────────────────────────────
local function CreateQuestButton(parent, text, isPrimary)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(CFG.buttonWidth, CFG.buttonHeight)
    btn:SetBackdrop({
        bgFile   = WHITE8X8,
        edgeFile = WHITE8X8,
        edgeSize = 1,
        insets   = { left = 1, right = 1, top = 1, bottom = 1 },
    })

    if isPrimary then
        btn:SetBackdropColor(0.18, 0.15, 0.10, 0.95)
        btn:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 0.9)
    else
        btn:SetBackdropColor(C.buttonBg[1], C.buttonBg[2], C.buttonBg[3], C.buttonBg[4])
        btn:SetBackdropBorderColor(C.buttonBorder[1], C.buttonBorder[2], C.buttonBorder[3], 0.5)
    end

    local label = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(label, TITLE_FONT, 14, isPrimary and "OUTLINE" or "")
    label:SetPoint("CENTER", 0, 1)
    label:SetText(text)
    if isPrimary then
        label:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    else
        label:SetTextColor(C.buttonText[1], C.buttonText[2], C.buttonText[3])
    end
    btn._label = label
    btn._isPrimary = isPrimary

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.buttonHover[1], C.buttonHover[2], C.buttonHover[3], C.buttonHover[4])
        self:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1.0)
        self._label:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    end)
    btn:SetScript("OnLeave", function(self)
        if self._isPrimary then
            self:SetBackdropColor(0.18, 0.15, 0.10, 0.95)
            self:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 0.9)
        else
            self:SetBackdropColor(C.buttonBg[1], C.buttonBg[2], C.buttonBg[3], C.buttonBg[4])
            self:SetBackdropBorderColor(C.buttonBorder[1], C.buttonBorder[2], C.buttonBorder[3], 0.5)
        end
        if not self._isPrimary then
            self._label:SetTextColor(C.buttonText[1], C.buttonText[2], C.buttonText[3])
        else
            self._label:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
        end
    end)

    btn:Hide()
    return btn
end

-- Create the action buttons
local btnAccept   = CreateQuestButton(contentPanel, "Accept Quest", true)
local btnDecline  = CreateQuestButton(contentPanel, "Decline", false)
local btnContinue = CreateQuestButton(contentPanel, "Continue", true)
local btnComplete = CreateQuestButton(contentPanel, "Complete Quest", true)
local btnGoodbye  = CreateQuestButton(contentPanel, "Goodbye", false)
local ShowQuestAcceptedBanner
local ShowQuestCompleteBanner

-- Position buttons at bottom of content panel
btnAccept:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT", -CFG.contentPadding, 14)
btnDecline:SetPoint("RIGHT", btnAccept, "LEFT", -10, 0)
btnContinue:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT", -CFG.contentPadding, 14)
btnComplete:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT", -CFG.contentPadding, 14)
btnGoodbye:SetPoint("RIGHT", btnContinue, "LEFT", -10, 0)

local function TriggerQuestAcceptedBanner(questName)
    if type(ShowQuestAcceptedBanner) ~= "function" then
        return
    end

    if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
        pcall(C_Timer.After, 0.05, function()
            pcall(ShowQuestAcceptedBanner, questName)
        end)
        return
    end

    pcall(ShowQuestAcceptedBanner, questName)
end

-- Button actions
btnAccept:SetScript("OnClick", function()
    -- Capture quest name before AcceptQuest clears the data
    local questName = SafeCall(GetTitleText) or ""
    SafeCall(AcceptQuest)
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_OPEN or 844)
    -- Banner is shown after a tiny delay so the frame can start closing first.
    TriggerQuestAcceptedBanner(questName)
end)
btnDecline:SetScript("OnClick", function()
    State.declining = true
    SafeCall(DeclineQuest)
end)
btnContinue:SetScript("OnClick", function()
    SafeCall(CompleteQuest)
end)
btnComplete:SetScript("OnClick", function()
    if State.currentMode == "complete" then
        local numChoices = SafeCall(GetNumQuestChoices) or 0
        if numChoices > 1 and State.chosenReward < 1 then
            -- Flash the reward items to prompt selection
            for i = 1, numChoices do
                local rf = rewardPool[i]
                if rf and rf:IsShown() and rf._glow then
                    rf._glow:Show()
                    C_Timer.After(0.4, function()
                        if rf._glow then rf._glow:Hide() end
                    end)
                end
            end
            return
        end
        -- Capture quest name before GetQuestReward clears it
        local questName = SafeCall(GetTitleText) or ""
        SafeCall(GetQuestReward, State.chosenReward > 0 and State.chosenReward or nil)
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            pcall(C_Timer.After, 0.05, function()
                pcall(ShowQuestCompleteBanner, questName)
            end)
        else
            pcall(ShowQuestCompleteBanner, questName)
        end
    end
end)
btnGoodbye:SetScript("OnClick", function()
    if State.currentMode == "gossip" then
        if type(C_GossipInfo) == "table" and type(C_GossipInfo.CloseGossip) == "function" then
            pcall(C_GossipInfo.CloseGossip)
        elseif type(CloseGossip) == "function" then
            pcall(CloseGossip)
        else
            SafeCall(CloseQuest)
        end
        return
    end
    SafeCall(CloseQuest)
end)

-- Decline button also serves as Goodbye for progress
local function HideAllButtons()
    btnAccept:Hide()
    btnDecline:Hide()
    btnContinue:Hide()
    btnComplete:Hide()
    btnGoodbye:Hide()
end

-- ────────────────────────────────────────────────────────────────────────────
-- §15  CONTENT POPULATION HELPERS
-- ────────────────────────────────────────────────────────────────────────────

-- Hide all dynamic content elements
local function ResetContent()
    bodyTextFS:SetText("")
    objHeaderFS:Hide()
    objDivider:Hide()
    objTextFS:Hide()
    objTextFS:SetText("")
    reqHeaderFS:Hide()
    rewardHeaderFS:Hide()
    rewardDivider:Hide()
    moneyXPFS:Hide()
    moneyXPFS:SetText("")
    lootSubLabel:Hide()
    currencySubLabel:Hide()
    repSubLabel:Hide()
    State.chosenReward = 0

    for i = 1, CFG.maxRewardSlots do
        rewardPool[i]:Hide()
        rewardPool[i]._glow:Hide()
        rewardPool[i]._tooltipType = nil
        rewardPool[i]._tooltipIndex = nil
        rewardPool[i]:SetScript("OnClick", nil)
    end
    for i = 1, CFG.maxGreetingRows do
        greetingPool[i]:Hide()
        greetingPool[i]:SetScript("OnClick", nil)
    end

    -- Reset scroll
    State.scrollTarget = 0
    State.scrollCurrent = 0
    scrollFrame:SetVerticalScroll(0)
end

-- Set up the NPC model display
local function SetupModel()
    npcModel:ClearModel()
    npcNameText:SetText("")

    local hasQuestNPC = UnitExists("questnpc")
    local hasNPC      = UnitExists("npc")

    if hasQuestNPC or hasNPC then
        local unit = hasQuestNPC and "questnpc" or "npc"
        npcModel:SetUnit(unit)
        -- Reset to a neutral baseline: center X, slight upward lift, moderate zoom.
        npcModel:SetPortraitZoom(0.58)
        npcModel:SetFacing(CFG.modelFacing)
        npcModel:SetPosition(0.00, 0.00, 0.10)
        npcModel:SetCamDistanceScale(1.10)

        -- Apply warm dramatic lighting
        local L = CFG.modelLight
        pcall(npcModel.SetLight, npcModel,
            L[1], L[2], L[3], L[4], L[5],
            L[6], L[7], L[8], L[9],
            L[10], L[11], L[12], L[13])

        npcNameText:SetText("")
        modelPanel:Show()
        npcModel:Show()
    else
        modelPanel:Hide()
        npcModel:Hide()
        -- Expand content panel to fill the full width
        contentPanel:SetPoint("TOPLEFT", QI, "TOPLEFT", 4, -4)
    end
    State.modelDrift = 0
end

-- Restore content panel anchoring after model is visible
local function RestoreContentAnchors()
    contentPanel:ClearAllPoints()
    if modelPanel:IsShown() then
        contentPanel:SetPoint("TOPLEFT", modelPanel, "TOPRIGHT", 0, 0)
    else
        contentPanel:SetPoint("TOPLEFT", QI, "TOPLEFT", 4, -4)
    end
    contentPanel:SetPoint("BOTTOMRIGHT", QI, "BOTTOMRIGHT", -4, 4)
end

-- Start typewriter effect for the given text
local function StartTypewriter(text)
    local atoms, total = Typewriter.Parse(text or "")
    State.typewriterAtoms = atoms
    State.typewriterVisTotal = total
    State.typewriterVisCur = 0
    State.typewriterDone = (total == 0)
    State.typewriterTimer = 0
    State.typewriterDelay = CFG.typewriterDelay
    State.talkAnimWanted = (total > 0)
    State.talkAnimRetry = 0
    State.talkAnimID = nil
    State.talkAnimIndex = 1
    State.talkAnimNoState = false
    State.talkAnimRefreshes = 0
    State.talkAnimApplied = false

    if total == 0 then
        bodyTextFS:SetText(text or "")
    else
        bodyTextFS:SetText("")
    end

    -- Trigger the NPC's talk animation while text is being revealed.
    -- Candidate order is 64/65/60 to keep no-state models visibly animated.
    -- When typewriter finishes we
    -- return to idle in the OnUpdate tick.
    if total > 0 and npcModel:IsShown() then
        local resolvedID, resolvedIndex, resolvedSupported = ResolveNPCTalkAnimation()
        State.talkAnimID = resolvedID
        State.talkAnimIndex = resolvedIndex or 1
        State.talkAnimNoState = not resolvedSupported
        local applied = SetNPCAnimationSafe(State.talkAnimID, "start")
        State.talkAnimApplied = applied and true or false
        local _, currentReason = GetNPCAnimationSafe()
        if State.talkAnimApplied then
            if State.talkAnimNoState or currentReason == "no_GetAnimation" then
                State.talkAnimRetry = NPC_ANIM_NOSTATE_WARMUP_SECONDS
            else
                State.talkAnimRetry = NPC_ANIM_STATE_POLL_SECONDS
            end
        else
            State.talkAnimRetry = NPC_ANIM_APPLY_RETRY_SECONDS
        end
    elseif npcModel:IsShown() then
        SetNPCAnimationSafe(NPC_ANIM_IDLE, "start-empty")
    end
end

-- Populate objectives text from GetObjectiveText()
local function PopulateObjectives(anchorBelow)
    local objText = SafeCall(GetObjectiveText)
    if not objText or objText == "" then
        objHeaderFS:Hide()
        objDivider:Hide()
        objTextFS:Hide()
        return anchorBelow
    end

    objHeaderFS:ClearAllPoints()
    objHeaderFS:SetPoint("TOPLEFT", anchorBelow, "BOTTOMLEFT", 0, -20)
    objHeaderFS:Show()
    objDivider:ClearAllPoints()
    objDivider:SetPoint("TOPLEFT", objHeaderFS, "BOTTOMLEFT", 0, -6)
    objDivider:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
    objDivider:Show()

    -- Parse objectives — each line is typically one objective
    objTextFS:ClearAllPoints()
    objTextFS:SetPoint("TOPLEFT", objDivider, "BOTTOMLEFT", 4, -6)
    objTextFS:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
    objTextFS:SetText(objText)
    objTextFS:Show()
    return objTextFS
end

-- Populate required items (QUEST_PROGRESS)
local function PopulateRequiredItems(anchorBelow)
    local numReq = SafeCall(GetNumQuestItems) or 0
    if numReq <= 0 then
        reqHeaderFS:Hide()
        return anchorBelow
    end

    reqHeaderFS:ClearAllPoints()
    reqHeaderFS:SetPoint("TOPLEFT", anchorBelow, "BOTTOMLEFT", 0, -20)
    reqHeaderFS:Show()

    local lastAnchor = reqHeaderFS
    local col = 0
    local perRow = 2
    local slotW = 200

    for i = 1, numReq do
        local name, texture, numItems = SafeCall(GetQuestItemInfo, "required", i)
        if name then
            local rf = rewardPool[i]
            if not rf then break end

            rf._icon:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
            rf._name:SetText(name or "???")
            rf._name:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
            if rf._ilvl then
                rf._ilvl:SetText("")
                rf._ilvl:Hide()
            end
            rf._count:SetText(numItems and numItems > 1 and numItems or "")
            SetRewardIconBorder(rf, C.borderDim[1], C.borderDim[2], C.borderDim[3], 0.5)
            rf._glow:Hide()
            rf._tooltipType = "required"
            rf._tooltipIndex = i

            rf:ClearAllPoints()
            if col == 0 then
                rf:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -8)
            else
                rf:SetPoint("LEFT", rewardPool[i - 1], "RIGHT", 8, 0)
            end
            rf:Show()

            col = col + 1
            if col >= perRow then
                col = 0
                lastAnchor = rf
            end
        end
    end

    local lastShown = rewardPool[numReq]
    return lastShown and lastShown:IsShown() and lastShown or reqHeaderFS
end

-- ────────────────────────────────────────────────────────────────────────────
-- §13  REWARDS (clean structured layout)
-- ────────────────────────────────────────────────────────────────────────────

-- Helper: configure a reward slot with icon, text, border, and anchor it
local function SetupRewardSlot(rf, icon, name, nameR, nameG, nameB, count, borderR, borderG, borderB, tipType, tipIdx)
    rf._icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    rf._name:SetText(name or "")
    rf._name:SetTextColor(nameR or 0.94, nameG or 0.90, nameB or 0.80)
    if rf._ilvl then rf._ilvl:SetText(""); rf._ilvl:Hide() end
    rf._count:SetText(count or "")
    SetRewardIconBorder(rf, borderR or 0.50, borderG or 0.42, borderB or 0.28, 0.7)
    rf._glow:Hide()
    rf._tooltipType = tipType
    rf._tooltipIndex = tipIdx
    rf:SetScript("OnClick", nil)
end

local function PopulateRewards(anchorBelow, mode)
    local numRewards = SafeCall(GetNumQuestRewards) or 0
    local numChoices = SafeCall(GetNumQuestChoices) or 0
    local money      = SafeCall(GetRewardMoney) or 0
    local xp         = SafeCall(GetRewardXP) or 0

    -- Count currency rewards, separating reputation tokens from true currencies
    local currencyList = {}
    local currencyRepList = {}  -- rep-type currencies (faction rep delivered as currency)
    if C_QuestOffer and C_QuestOffer.GetQuestRewardCurrencyInfo then
        local idx = 1
        while idx <= 12 do
            local ok, info = pcall(C_QuestOffer.GetQuestRewardCurrencyInfo, "reward", idx)
            if not ok or not info or not info.name or info.name == "" then break end
            -- Check if this currency is actually a reputation token
            local isRep = false
            local cID = info.currencyID
            if cID then
                if C_CurrencyInfo and C_CurrencyInfo.GetFactionGrantedByCurrency then
                    local fID = SafeCall(C_CurrencyInfo.GetFactionGrantedByCurrency, cID)
                    if fID and fID > 0 then isRep = true end
                end
            end
            if isRep then
                currencyRepList[#currencyRepList + 1] = info
            else
                currencyList[#currencyList + 1] = info
            end
            idx = idx + 1
        end
    end

    -- Count major faction rep rewards
    local repList = {}
    if C_QuestOffer and C_QuestOffer.GetQuestOfferMajorFactionReputationRewards then
        local repRewards = SafeCall(C_QuestOffer.GetQuestOfferMajorFactionReputationRewards)
        if type(repRewards) == "table" then
            for _, entry in ipairs(repRewards) do
                if entry then
                    local factionID = entry.factionID or entry.majorFactionID
                    local rewardAmount = entry.rewardAmount or entry.reward or 0
                    local factionName, factionIcon
                    if factionID then
                        if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
                            local data = SafeCall(C_MajorFactions.GetMajorFactionData, factionID)
                            if data then factionName = data.name end
                        end
                        if not factionName and C_Reputation and C_Reputation.GetFactionDataByID then
                            local data = SafeCall(C_Reputation.GetFactionDataByID, factionID)
                            if data then factionName = data.name; factionIcon = data.icon end
                        end
                        if not factionName and GetFactionInfoByID then
                            factionName = SafeCall(GetFactionInfoByID, factionID)
                        end
                    end
                    if factionName then
                        repList[#repList + 1] = { name = factionName, icon = factionIcon, amount = rewardAmount }
                    end
                end
            end
        end
    end

    local hasAnything = (numRewards > 0) or (numChoices > 0) or (money > 0) or (xp > 0)
        or (#currencyList > 0) or (#currencyRepList > 0) or (#repList > 0)
    if not hasAnything then
        rewardHeaderFS:Hide()
        rewardDivider:Hide()
        moneyXPFS:Hide()
        return anchorBelow
    end

    -- ── Section header ──────────────────────────────────────────────────
    rewardHeaderFS:ClearAllPoints()
    rewardHeaderFS:SetPoint("TOPLEFT", anchorBelow, "BOTTOMLEFT", 0, -22)
    if numChoices > 1 then
        rewardHeaderFS:SetText("Choose a Reward")
    elseif numChoices == 1 then
        rewardHeaderFS:SetText("Reward")
    else
        rewardHeaderFS:SetText("You will receive")
    end
    rewardHeaderFS:Show()

    rewardDivider:ClearAllPoints()
    rewardDivider:SetPoint("TOPLEFT", rewardHeaderFS, "BOTTOMLEFT", 0, -4)
    rewardDivider:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
    rewardDivider:Show()

    local lastAnchor = rewardDivider
    local col = 0
    local perRow = 2
    local slotIndex = 0
    local contentW = scrollContent:GetWidth()
    if contentW < 100 then contentW = 380 end  -- fallback
    local rightInset = 10  -- keep slots clear of the scroll track
    local gap = 6
    local slotW = math.floor((contentW - rightInset - gap) / perRow)

    local rowStartAnchor = nil  -- tracks the col-0 slot of the current row

    -- Helper: place a reward frame in the grid
    local function PlaceSlot(rf, forceNewRow)
        if forceNewRow and col ~= 0 then
            col = 0
            lastAnchor = rowStartAnchor or rewardPool[slotIndex - 1] or lastAnchor
        end
        rf:ClearAllPoints()
        rf:SetWidth(slotW)
        if col == 0 then
            rf:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -6)
            rowStartAnchor = rf
        else
            rf:SetPoint("LEFT", rewardPool[slotIndex - 1], "RIGHT", gap, 0)
        end
        rf:Show()
        col = col + 1
        if col >= perRow then
            col = 0
            lastAnchor = rowStartAnchor or rf
        end
    end

    -- ── 1. Choice rewards ───────────────────────────────────────────────
    for i = 1, numChoices do
        slotIndex = slotIndex + 1
        local rf = rewardPool[slotIndex]
        if not rf then break end

        local name, texture, numItems, quality, isUsable = SafeCall(GetQuestItemInfo, "choice", i)
        local qc = GetQualityColor(quality or 1)

        SetupRewardSlot(rf, texture, name or "Loading...", qc[1], qc[2], qc[3],
            numItems and numItems > 1 and numItems or "", qc[1], qc[2], qc[3], "choice", i)
        SetRewardItemLevelLine(rf, "choice", i)
        PlaceSlot(rf)

        if numChoices > 1 then
            local choiceIdx = i
            rf:SetScript("OnClick", function()
                State.chosenReward = choiceIdx
                for j = 1, numChoices do
                    local rr = rewardPool[j]
                    if j == choiceIdx then
                        rr._glow:Show()
                        rr:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 0.6)
                    else
                        rr._glow:Hide()
                        rr:SetBackdropBorderColor(0, 0, 0, 0)
                    end
                end
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_SELECT or 856)
            end)
        elseif numChoices == 1 then
            State.chosenReward = 1
        end
    end

    -- ── Helper: place a sub-section label ─────────────────────────────
    local function PlaceSubLabel(labelFS, text)
        if col ~= 0 then
            col = 0
            lastAnchor = rowStartAnchor or rewardPool[slotIndex] or lastAnchor
        elseif rowStartAnchor then
            lastAnchor = rowStartAnchor
        end
        labelFS:ClearAllPoints()
        labelFS:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -10)
        labelFS:SetText(text)
        labelFS:Show()
        lastAnchor = labelFS
        rowStartAnchor = nil
    end

    -- ── 2. Fixed item rewards ───────────────────────────────────────────
    if numRewards > 0 then
        if numChoices > 0 then
            col = 0
            lastAnchor = rewardPool[slotIndex] or lastAnchor
        end
        PlaceSubLabel(lootSubLabel, "Loot")

        for i = 1, numRewards do
            slotIndex = slotIndex + 1
            local rf = rewardPool[slotIndex]
            if not rf then break end

            local name, texture, numItems, quality = SafeCall(GetQuestItemInfo, "reward", i)
            local qc = GetQualityColor(quality or 1)

            SetupRewardSlot(rf, texture, name or "Loading...", qc[1], qc[2], qc[3],
                numItems and numItems > 1 and numItems or "", qc[1], qc[2], qc[3], "reward", i)
            SetRewardItemLevelLine(rf, "reward", i)
            PlaceSlot(rf)
        end
    end

    -- ── 3. Currency (XP, Money, and non-rep currency tokens) ──────────
    local hasCurrency = (xp > 0) or (money > 0) or (#currencyList > 0)
    if hasCurrency then
        PlaceSubLabel(currencySubLabel, "Currency")

        if xp > 0 then
            slotIndex = slotIndex + 1
            local rf = rewardPool[slotIndex]
            if rf then
                local xpLabel = "|cff8080ff" .. xp .. "|r XP"
                local maxXP = SafeCall(UnitXPMax, "player") or 1
                if maxXP > 0 then
                    xpLabel = xpLabel .. string.format("  |cff888888(%.1f%%)|r", (xp / maxXP) * 100)
                end
                SetupRewardSlot(rf,
                    "Interface\\Icons\\XP_Icon",
                    xpLabel, 0.80, 0.75, 1.0, "", 0.45, 0.40, 0.70)
                PlaceSlot(rf)
            end
        end

        if money > 0 then
            slotIndex = slotIndex + 1
            local rf = rewardPool[slotIndex]
            if rf then
                local moneyStr = FormatMoney(money) or (math.floor(money / 10000) .. " Gold")
                SetupRewardSlot(rf,
                    "Interface\\Icons\\INV_Misc_Coin_01",
                    moneyStr, 0.94, 0.86, 0.56, "", 0.62, 0.54, 0.36)
                PlaceSlot(rf)
            end
        end

        for _, info in ipairs(currencyList) do
            slotIndex = slotIndex + 1
            local rf = rewardPool[slotIndex]
            if not rf then break end

            local amount = info.totalRewardAmount or info.baseRewardAmount or 0
            local countText = amount > 0 and tostring(amount) or ""
            SetupRewardSlot(rf,
                info.texture or info.iconFileID or "Interface\\Icons\\INV_Misc_Coin_01",
                info.name, 0.70, 0.85, 1.0, countText, 0.40, 0.65, 0.90)
            PlaceSlot(rf)
        end
    end

    -- ── 5. Reputation rewards (major factions + rep-type currencies) ──
    local hasRep = (#repList > 0) or (#currencyRepList > 0)
    if hasRep then
        PlaceSubLabel(repSubLabel, "Reputation")

        -- Rep-type currencies (e.g. Silvermoon Court delivered as currency)
        for _, info in ipairs(currencyRepList) do
            slotIndex = slotIndex + 1
            local rf = rewardPool[slotIndex]
            if not rf then break end

            local amount = info.totalRewardAmount or info.baseRewardAmount or 0
            local countText = amount > 0 and tostring(amount) or ""
            SetupRewardSlot(rf,
                info.texture or info.iconFileID or "Interface\\Icons\\Achievement_Reputation_01",
                info.name, 0.55, 0.80, 1.0, countText, 0.35, 0.60, 0.85)
            PlaceSlot(rf)
        end

        -- Major faction reputation rewards
        for _, rep in ipairs(repList) do
            slotIndex = slotIndex + 1
            local rf = rewardPool[slotIndex]
            if not rf then break end

            local countText = (rep.amount and rep.amount > 0) and tostring(rep.amount) or ""
            SetupRewardSlot(rf,
                rep.icon or "Interface\\Icons\\Achievement_Reputation_01",
                rep.name, 0.55, 0.80, 1.0, countText, 0.35, 0.60, 0.85)
            PlaceSlot(rf)
        end
    end

    -- Return bottom-most visible element for scroll content sizing
    local lastReward = rewardPool[slotIndex]
    if lastReward and lastReward:IsShown() then
        return lastReward
    end
    return rewardDivider
end

-- Calculate and set scroll content height based on bottom-most visible element
local function UpdateScrollContentHeight()
    -- Walk all visible children and find the maximum bottom edge
    local maxBottom = 0
    local children = { scrollContent:GetChildren() }
    for _, child in ipairs(children) do
        if child:IsShown() then
            local _, _, _, _, offsetY = child:GetPoint(1)
            if offsetY then
                local bottom = -offsetY + child:GetHeight()
                if bottom > maxBottom then maxBottom = bottom end
            end
        end
    end
    -- Also check fontstrings
    local regions = { scrollContent:GetRegions() }
    for _, region in ipairs(regions) do
        if region:IsShown() and region.GetStringHeight then
            local _, _, _, _, offsetY = region:GetPoint(1)
            if offsetY then
                local h = region:GetStringHeight() or region:GetHeight()
                local bottom = -offsetY + h
                if bottom > maxBottom then maxBottom = bottom end
            end
        end
    end

    scrollContent:SetHeight(math.max(maxBottom + 20, 1))
end

-- ────────────────────────────────────────────────────────────────────────────
-- §16  GREETING VIEW (multiple quests from one NPC)
-- ────────────────────────────────────────────────────────────────────────────
local function PopulateGreeting()
    ResetContent()

    local greetText = SafeCall(GetGreetingText) or ""
    local numActive = SafeCall(GetNumActiveQuests) or 0
    local numAvail  = SafeCall(GetNumAvailableQuests) or 0

    bodyTextFS:SetText(greetText)
    StartTypewriter(greetText)
    local rowIndex  = 0
    local lastAnchor = bodyTextFS

    -- Active quests (in-progress or ready to turn in)
    if numActive > 0 then
        -- Section header for active quests
        objHeaderFS:ClearAllPoints()
        objHeaderFS:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -20)
        objHeaderFS:SetText("Active Quests")
        objHeaderFS:Show()
        objDivider:ClearAllPoints()
        objDivider:SetPoint("TOPLEFT", objHeaderFS, "BOTTOMLEFT", 0, -4)
        objDivider:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
        objDivider:Show()
        lastAnchor = objDivider

        for i = 1, numActive do
            rowIndex = rowIndex + 1
            local row = greetingPool[rowIndex]
            if not row then break end

            local title = SafeCall(GetActiveTitle, i) or "Quest"
            local isComplete = false
            if IsActiveQuestComplete then
                isComplete = SafeCall(IsActiveQuestComplete, i) or false
            end

            row._icon:Show()
            if row._iconAtlas then row._iconAtlas:Hide() end
            row._icon:SetText(isComplete and "?" or "?")
            if isComplete then
                row._icon:SetTextColor(C.questReady[1], C.questReady[2], C.questReady[3])
            else
                row._icon:SetTextColor(C.questActive[1], C.questActive[2], C.questActive[3])
            end
            row._title:SetText(title)
            row._title:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -2)
            row:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
            row:Show()
            FitGreetingRowHeight(row)
            lastAnchor = row

            local idx = i
            row:SetScript("OnClick", function()
                SafeCall(SelectActiveQuest, idx)
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_SELECT or 856)
            end)
        end
    end

    -- Available quests
    if numAvail > 0 then
        rewardHeaderFS:ClearAllPoints()
        rewardHeaderFS:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -20)
        rewardHeaderFS:SetText("Available Quests")
        rewardHeaderFS:Show()
        rewardDivider:ClearAllPoints()
        rewardDivider:SetPoint("TOPLEFT", rewardHeaderFS, "BOTTOMLEFT", 0, -4)
        rewardDivider:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
        rewardDivider:Show()
        lastAnchor = rewardDivider

        for i = 1, numAvail do
            rowIndex = rowIndex + 1
            local row = greetingPool[rowIndex]
            if not row then break end

            local title = SafeCall(GetAvailableTitle, i) or "Quest"

            SetRowAvailableQuestIcon(row)
            row._title:SetText(title)
            row._title:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -2)
            row:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
            row:Show()
            FitGreetingRowHeight(row)
            lastAnchor = row

            local idx = i
            row:SetScript("OnClick", function()
                SafeCall(SelectAvailableQuest, idx)
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_SELECT or 856)
            end)
        end
    end

    -- Only Goodbye button
    HideAllButtons()
    btnGoodbye:ClearAllPoints()
    btnGoodbye:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT", -CFG.contentPadding, 14)
    btnGoodbye:Show()

    C_Timer.After(0.05, UpdateScrollContentHeight)
end

local function PopulateGossip()
    ResetContent()
    State.currentMode = "gossip"
    local npcName = SafeCall(UnitName, "npc") or ""

    local gossipText = ""
    if type(C_GossipInfo) == "table" and type(C_GossipInfo.GetText) == "function" then
        local okText, textValue = pcall(C_GossipInfo.GetText)
        if okText and type(textValue) == "string" then
            gossipText = textValue
        end
    end
    if gossipText == "" and type(GetGossipText) == "function" then
        gossipText = SafeCall(GetGossipText) or ""
    end
    if gossipText == "" then
        gossipText = SafeCall(GetGreetingText) or ""
    end

    local activeQuests = {}
    local availableQuests = {}
    local gossipOptions = {}
    local gossipApiReady = false

    if type(C_GossipInfo) == "table" then
        if type(C_GossipInfo.GetActiveQuests) == "function" then
            local okActive, activeList = pcall(C_GossipInfo.GetActiveQuests)
            if okActive and type(activeList) == "table" then
                activeQuests = activeList
                gossipApiReady = true
            end
        end
        if type(C_GossipInfo.GetAvailableQuests) == "function" then
            local okAvail, availList = pcall(C_GossipInfo.GetAvailableQuests)
            if okAvail and type(availList) == "table" then
                availableQuests = availList
                gossipApiReady = true
            end
        end
        if type(C_GossipInfo.GetOptions) == "function" then
            local okOpts, optionsList = pcall(C_GossipInfo.GetOptions)
            if okOpts and type(optionsList) == "table" then
                gossipOptions = optionsList
                gossipApiReady = true
            end
        end
    end

    if #activeQuests == 0 then
        local numActive = SafeCall(GetNumActiveQuests) or 0
        for i = 1, numActive do
            activeQuests[#activeQuests + 1] = {
                title = SafeCall(GetActiveTitle, i),
                isComplete = (IsActiveQuestComplete and SafeCall(IsActiveQuestComplete, i)) or false,
                _legacyIndex = i,
            }
        end
    end
    if #availableQuests == 0 then
        local numAvail = SafeCall(GetNumAvailableQuests) or 0
        for i = 1, numAvail do
            availableQuests[#availableQuests + 1] = {
                title = SafeCall(GetAvailableTitle, i),
                _legacyIndex = i,
            }
        end
    end
    if #gossipOptions == 0 and type(GetGossipOptions) == "function" then
        local legacy = { SafeCall(GetGossipOptions) }
        local optionIndex = 0
        for i = 1, #legacy, 2 do
            local optionText = legacy[i]
            if type(optionText) == "string" and optionText ~= "" then
                optionIndex = optionIndex + 1
                gossipOptions[#gossipOptions + 1] = {
                    name = optionText,
                    _legacyIndex = optionIndex,
                }
            end
        end
    end

    local hasChoices = (#activeQuests + #availableQuests + #gossipOptions) > 0
    local gossipTextSource = "live"
    if gossipText ~= "" then
        State.lastGossipText = gossipText
        State.lastGossipNpc = npcName
        State.lastGossipTextAt = (GetTime and GetTime()) or 0
    else
        gossipTextSource = "empty"
        local now = (GetTime and GetTime()) or 0
        local age = now - (State.lastGossipTextAt or 0)
        local hasRecentCache = (State.lastGossipText or "") ~= ""
            and State.lastGossipNpc == npcName
            and age >= 0 and age <= 30
        if hasRecentCache then
            gossipText = State.lastGossipText
            gossipTextSource = "cached"
        end
    end

    bodyTextFS:SetText(gossipText)
    StartTypewriter(gossipText)
    local rowIndex = 0
    local lastAnchor = bodyTextFS
    local activeHeaderText = _G.ACTIVE_QUESTS or "Active Quests"
    local availableHeaderText = _G.AVAILABLE_QUESTS or "Available Quests"
    local optionsHeaderText = _G.GOSSIP_OPTIONS or "Conversation"

    if #activeQuests > 0 then
        objHeaderFS:ClearAllPoints()
        objHeaderFS:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -20)
        objHeaderFS:SetText(activeHeaderText)
        objHeaderFS:Show()
        objDivider:ClearAllPoints()
        objDivider:SetPoint("TOPLEFT", objHeaderFS, "BOTTOMLEFT", 0, -4)
        objDivider:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
        objDivider:Show()
        lastAnchor = objDivider

        for i = 1, #activeQuests do
            rowIndex = rowIndex + 1
            local row = greetingPool[rowIndex]
            if not row then break end
            local entry = activeQuests[i] or {}
            local title = entry.title or "Quest"
            local isComplete = entry.isComplete and true or false
            local questID = tonumber(entry.questID) or tonumber(entry.questId)

            row._icon:Show()
            if row._iconAtlas then row._iconAtlas:Hide() end
            row._icon:SetText("?")
            if isComplete then
                row._icon:SetTextColor(C.questReady[1], C.questReady[2], C.questReady[3])
            else
                row._icon:SetTextColor(C.questActive[1], C.questActive[2], C.questActive[3])
            end
            row._title:SetText(title)
            row._title:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -2)
            row:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
            row:Show()
            FitGreetingRowHeight(row)
            lastAnchor = row

            local legacyIndex = tonumber(entry._legacyIndex) or i
            row:SetScript("OnClick", function()
                local okSelect = false
                if type(C_GossipInfo) == "table"
                   and type(C_GossipInfo.SelectActiveQuest) == "function"
                   and questID then
                    okSelect = pcall(C_GossipInfo.SelectActiveQuest, questID)
                end
                if not okSelect and type(SelectActiveQuest) == "function" then
                    okSelect = pcall(SelectActiveQuest, legacyIndex)
                end
                if not okSelect and type(SelectGossipActiveQuest) == "function" then
                    okSelect = pcall(SelectGossipActiveQuest, legacyIndex)
                end
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_SELECT or 856)
            end)
        end
    end

    if #availableQuests > 0 then
        rewardHeaderFS:ClearAllPoints()
        rewardHeaderFS:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -20)
        rewardHeaderFS:SetText(availableHeaderText)
        rewardHeaderFS:Show()
        rewardDivider:ClearAllPoints()
        rewardDivider:SetPoint("TOPLEFT", rewardHeaderFS, "BOTTOMLEFT", 0, -4)
        rewardDivider:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
        rewardDivider:Show()
        lastAnchor = rewardDivider

        for i = 1, #availableQuests do
            rowIndex = rowIndex + 1
            local row = greetingPool[rowIndex]
            if not row then break end
            local entry = availableQuests[i] or {}
            local title = entry.title or "Quest"
            local questID = tonumber(entry.questID) or tonumber(entry.questId)

            SetRowAvailableQuestIcon(row)
            row._title:SetText(title)
            row._title:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -2)
            row:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
            row:Show()
            FitGreetingRowHeight(row)
            lastAnchor = row

            local legacyIndex = tonumber(entry._legacyIndex) or i
            row:SetScript("OnClick", function()
                local okSelect = false
                if type(C_GossipInfo) == "table"
                   and type(C_GossipInfo.SelectAvailableQuest) == "function"
                   and questID then
                    okSelect = pcall(C_GossipInfo.SelectAvailableQuest, questID)
                end
                if not okSelect and type(SelectAvailableQuest) == "function" then
                    okSelect = pcall(SelectAvailableQuest, legacyIndex)
                end
                if not okSelect and type(SelectGossipAvailableQuest) == "function" then
                    okSelect = pcall(SelectGossipAvailableQuest, legacyIndex)
                end
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_SELECT or 856)
            end)
        end
    end

    if #gossipOptions > 0 then
        reqHeaderFS:ClearAllPoints()
        reqHeaderFS:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -20)
        reqHeaderFS:SetText(optionsHeaderText)
        reqHeaderFS:Show()
        lastAnchor = reqHeaderFS

        for i = 1, #gossipOptions do
            rowIndex = rowIndex + 1
            local row = greetingPool[rowIndex]
            if not row then break end
            local entry = gossipOptions[i] or {}
            local optionText = entry.name or entry.text or "Option"
            local optionID = tonumber(entry.gossipOptionID) or tonumber(entry.optionID)
            local legacyIndex = tonumber(entry._legacyIndex) or i

            SetRowGossipOptionIcon(row)
            row._title:SetText(optionText)
            row._title:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -2)
            row:SetPoint("RIGHT", scrollContent, "RIGHT", -8, 0)
            row:Show()
            FitGreetingRowHeight(row)
            lastAnchor = row

            row:SetScript("OnClick", function()
                local okSelect = false
                if type(C_GossipInfo) == "table"
                   and type(C_GossipInfo.SelectOption) == "function"
                   and optionID then
                    okSelect = pcall(C_GossipInfo.SelectOption, optionID)
                end
                if not okSelect and type(SelectGossipOption) == "function" then
                    okSelect = pcall(SelectGossipOption, legacyIndex)
                end
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or 856)
            end)
        end
    end

    HideAllButtons()
    btnGoodbye:ClearAllPoints()
    btnGoodbye:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT", -CFG.contentPadding, 14)
    btnGoodbye:Show()

    C_Timer.After(0.05, UpdateScrollContentHeight)
    return gossipText, hasChoices, gossipTextSource
end

-- ────────────────────────────────────────────────────────────────────────────
-- §17  QUEST DETAIL / PROGRESS / COMPLETE POPULATION
-- ────────────────────────────────────────────────────────────────────────────
local function PopulateDetail()
    ResetContent()
    State.currentMode = "detail"

    -- Quest API resolved from _G at call time (demand-loaded by Blizzard_QuestUI)
    local title     = SafeCall(GetTitleText) or "Quest"
    local questText = SafeCall(GetQuestText) or ""

    titleText:SetText(title)
    StartTypewriter(questText)

    -- Build content below body text
    local anchor = bodyTextFS
    anchor = PopulateObjectives(anchor)
    anchor = PopulateRewards(anchor, "detail")

    -- Buttons: Accept + Decline
    HideAllButtons()
    btnAccept:Show()
    btnDecline:Show()

    -- Handle auto-accept quests (legacy API check)
    if QuestGetAutoAccept and SafeCall(QuestGetAutoAccept) then
        btnAccept._label:SetText("Continue")
        btnAccept:SetScript("OnClick", function()
            if AcknowledgeAutoAcceptQuest then SafeCall(AcknowledgeAutoAcceptQuest) end
            SafeCall(CloseQuest)
        end)
        btnDecline:Hide()
    else
        btnAccept._label:SetText("Accept Quest")
        btnAccept:SetScript("OnClick", function()
            local questName = SafeCall(GetTitleText) or ""
            SafeCall(AcceptQuest)
            pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LOG_OPEN or 844)
            TriggerQuestAcceptedBanner(questName)
        end)
    end

    C_Timer.After(0.05, UpdateScrollContentHeight)
end

local function PopulateProgress()
    ResetContent()
    State.currentMode = "progress"

    local title    = SafeCall(GetTitleText) or "Quest"
    local progText = SafeCall(GetProgressText) or ""

    titleText:SetText(title)
    StartTypewriter(progText)

    -- Required items
    local anchor = bodyTextFS
    anchor = PopulateRequiredItems(anchor)

    -- Buttons: Continue (if completable) or just Goodbye
    HideAllButtons()
    local completable = SafeCall(IsQuestCompletable)
    if completable then
        btnContinue:Show()
        btnGoodbye:ClearAllPoints()
        btnGoodbye:SetPoint("RIGHT", btnContinue, "LEFT", -10, 0)
        btnGoodbye:Show()
    else
        btnGoodbye:ClearAllPoints()
        btnGoodbye:SetPoint("BOTTOMRIGHT", contentPanel, "BOTTOMRIGHT", -CFG.contentPadding, 14)
        btnGoodbye:Show()
    end

    C_Timer.After(0.05, UpdateScrollContentHeight)
end

local function PopulateComplete()
    ResetContent()
    State.currentMode = "complete"

    local title      = SafeCall(GetTitleText) or "Quest"
    local rewardText = SafeCall(GetRewardText) or ""

    titleText:SetText(title)
    StartTypewriter(rewardText)

    -- Rewards
    local anchor = bodyTextFS
    anchor = PopulateRewards(anchor, "complete")

    -- Buttons: Complete + Goodbye
    HideAllButtons()
    btnComplete:Show()
    btnGoodbye:ClearAllPoints()
    btnGoodbye:SetPoint("RIGHT", btnComplete, "LEFT", -10, 0)
    btnGoodbye:Show()

    -- If only one choice, auto-select it
    local numChoices = SafeCall(GetNumQuestChoices) or 0
    if numChoices == 1 then
        State.chosenReward = 1
    end

    C_Timer.After(0.05, UpdateScrollContentHeight)
end

-- ────────────────────────────────────────────────────────────────────────────
-- §18  SHOW / HIDE TRANSITIONS
-- ────────────────────────────────────────────────────────────────────────────
local function ShowQuestFrame()
    SetupModel()
    RestoreContentAnchors()
    QI:SetAlpha(0)
    QI:Show()

    -- Force scroll content width immediately so bodyTextFS can word-wrap correctly.
    -- Without this, bodyTextFS has 0 width and typewriter text is invisible.
    local w = scrollFrame:GetWidth()
    if not w or w <= 0 then
        -- Fallback: compute from known frame dimensions
        w = CFG.frameWidth - CFG.modelWidth - (CFG.contentPadding * 2)
    end
    if w > 0 then
        scrollContent:SetWidth(w)
    end

    -- Deferred pass to catch any layout settle and update scroll height.
    C_Timer.After(0, function()
        local w2 = scrollFrame:GetWidth()
        if w2 and w2 > 0 then
            scrollContent:SetWidth(w2)
        end
        UpdateScrollContentHeight()
    end)

    State.fadeAlpha = 0
    State.fadeDir = 1  -- fading in
    State.fadeDone = nil
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_OPEN or 844)
end

local function HideQuestFrame(immediate)
    if immediate then
        QI:Hide()
        QI:SetAlpha(0)
        State.fadeDir = 0
        State.fadeAlpha = 0
        return
    end
    if not QI:IsShown() then return end
    State.fadeDir = -1  -- fading out
    State.fadeDone = function()
        QI:Hide()
        QI:SetAlpha(0)
    end
end

-- ────────────────────────────────────────────────────────────────────────────
-- §19  MASTER OnUpdate — drives typewriter, fade, scroll, model drift
-- ────────────────────────────────────────────────────────────────────────────
QI:SetScript("OnUpdate", function(self, elapsed)
    if not elapsed or elapsed <= 0 then return end

    -- ── Fade transition ──
    if State.fadeDir ~= 0 then
        local dur = State.fadeDir > 0 and CFG.fadeInDuration or CFG.fadeOutDuration
        State.fadeAlpha = State.fadeAlpha + (State.fadeDir * elapsed / dur)
        if State.fadeAlpha >= 1 then
            State.fadeAlpha = 1
            State.fadeDir = 0
        elseif State.fadeAlpha <= 0 then
            State.fadeAlpha = 0
            State.fadeDir = 0
            if State.fadeDone then
                State.fadeDone()
                State.fadeDone = nil
            end
            return
        end
        self:SetAlpha(Smoothstep(State.fadeAlpha))
    end

    -- ── Typewriter ──
    if not State.typewriterDone then
        if State.talkAnimWanted and npcModel:IsShown() then
            State.talkAnimRetry = State.talkAnimRetry - elapsed
            if State.talkAnimRetry <= 0 then
                if not State.talkAnimID then
                    local resolvedID, resolvedIndex, resolvedSupported = ResolveNPCTalkAnimation()
                    State.talkAnimID = resolvedID
                    State.talkAnimIndex = resolvedIndex or 1
                    State.talkAnimNoState = not resolvedSupported
                end
                local isActive, currentAnimID, reason = IsNPCTalkAnimationActive()
                if isActive then
                    State.talkAnimApplied = true
                    if State.talkAnimNoState or reason == "no_GetAnimation" then
                        State.talkAnimRefreshes = (State.talkAnimRefreshes or 0) + 1
                        if (State.talkAnimRefreshes % 2) == 0 then
                            State.talkAnimIndex = State.talkAnimIndex + 1
                            if State.talkAnimIndex > #NPC_ANIM_TALK_CANDIDATES then
                                State.talkAnimIndex = 1
                            end
                            State.talkAnimID = NPC_ANIM_TALK_CANDIDATES[State.talkAnimIndex]
                        end
                        local refreshed = SetNPCAnimationSafe(State.talkAnimID, "tick-refresh")
                        if refreshed then
                            State.talkAnimRetry = NPC_ANIM_NOSTATE_REAPPLY_SECONDS
                            local afterAnimID, afterReason = GetNPCAnimationSafe()
                            local refreshReason = ((State.talkAnimRefreshes % 2) == 0)
                                and "reapplied_rotated" or "reapplied_same"
                        else
                            State.talkAnimApplied = false
                            State.talkAnimRetry = NPC_ANIM_APPLY_RETRY_SECONDS
                            local failAnimID, failReason = GetNPCAnimationSafe()
                        end
                    else
                        State.talkAnimRetry = NPC_ANIM_STATE_POLL_SECONDS
                    end
                else
                    local applied = SetNPCAnimationSafe(State.talkAnimID, "tick")
                    if applied then
                        State.talkAnimApplied = true
                        State.talkAnimRefreshes = 0
                        if State.talkAnimNoState or reason == "no_GetAnimation" then
                            State.talkAnimRetry = NPC_ANIM_NOSTATE_REAPPLY_SECONDS
                        else
                            State.talkAnimRetry = NPC_ANIM_STATE_POLL_SECONDS
                        end
                        local afterAnimID, afterReason = GetNPCAnimationSafe()
                    else
                        State.talkAnimApplied = false
                        State.talkAnimRetry = NPC_ANIM_APPLY_RETRY_SECONDS
                        local failAnimID, failReason = GetNPCAnimationSafe()
                    end
                end
            end
        end
        if State.typewriterDelay > 0 then
            State.typewriterDelay = State.typewriterDelay - elapsed
        else
            State.typewriterTimer = State.typewriterTimer + elapsed
            local charsToShow = math.floor(State.typewriterTimer * CFG.typewriterRate)
            if charsToShow > State.typewriterVisCur then
                State.typewriterVisCur = math.min(charsToShow, State.typewriterVisTotal)
                local display = Typewriter.Build(State.typewriterAtoms, State.typewriterVisCur)
                bodyTextFS:SetText(display)

                -- Auto-scroll if text exceeds visible area
                C_Timer.After(0, function()
                    local textH = bodyTextFS:GetStringHeight()
                    local scrollH = scrollFrame:GetHeight()
                    if textH > scrollH then
                        State.scrollTarget = textH - scrollH
                    end
                    UpdateScrollContentHeight()
                end)
            end
            if State.typewriterVisCur >= State.typewriterVisTotal then
                State.typewriterDone = true
                State.talkAnimWanted = false
                State.talkAnimRetry = 0
                State.talkAnimID = nil
                State.talkAnimIndex = 1
                State.talkAnimNoState = false
                State.talkAnimRefreshes = 0
                State.talkAnimApplied = false
                bodyTextFS:SetText(Typewriter.Build(State.typewriterAtoms, State.typewriterVisTotal))
                C_Timer.After(0.05, UpdateScrollContentHeight)
                -- Return NPC to idle when done talking
                if npcModel:IsShown() then
                    SetNPCAnimationSafe(NPC_ANIM_IDLE, "done")
                end
            end
        end
    end

    -- ── Smooth scroll ──
    if math.abs(State.scrollTarget - State.scrollCurrent) > 0.5 then
        State.scrollCurrent = State.scrollCurrent
            + (State.scrollTarget - State.scrollCurrent) * math.min(1, elapsed * 10)
        scrollFrame:SetVerticalScroll(State.scrollCurrent)
    end

    -- ── Scroll thumb update ──
    local maxScroll = scrollFrame:GetVerticalScrollRange()
    if maxScroll > 0 then
        scrollTrack:Show()
        scrollThumb:Show()
        local scrollH = scrollFrame:GetHeight()
        local ratio = scrollH / (scrollH + maxScroll)
        local thumbH = math.max(20, scrollH * ratio)
        scrollThumb:SetHeight(thumbH)
        local pos = State.scrollCurrent / maxScroll
        local travel = scrollH - thumbH
        scrollThumb:ClearAllPoints()
        scrollThumb:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", -1, -(pos * travel))
    else
        scrollTrack:Hide()
        scrollThumb:Hide()
    end

    -- ── Model ambient drift (very subtle breathing/sway) ──
    if modelPanel:IsShown() and npcModel:IsShown() then
        State.modelDrift = State.modelDrift + elapsed
        local sway = math.sin(State.modelDrift * 0.6) * 0.015
        npcModel:SetFacing(CFG.modelFacing + sway)

        -- Subtle glow pulse
        local glowPulse = 0.14 + math.sin(State.modelDrift * 1.2) * 0.04
        glowCenter:SetVertexColor(
            C.glowAmbient[1], C.glowAmbient[2], C.glowAmbient[3],
            math.max(0.06, math.min(0.28, glowPulse)))
    end
end)

-- ────────────────────────────────────────────────────────────────────────────
-- §20  EVENT HANDLING
-- ────────────────────────────────────────────────────────────────────────────
local EventFrame = CreateFrame("Frame")

local function SuppressDefaultQuestFrame()
    -- CRITICAL: We must NOT use HideUIPanel(QuestFrame) here.
    -- HideUIPanel triggers the panel manager's full teardown which fires
    -- QuestFrame's OnHide → CloseQuest() → ends the server-side quest
    -- interaction → QUEST_FINISHED fires immediately → all quest API calls
    -- (GetTitleText, GetQuestText, etc.) return empty strings.
    --
    -- Instead we make QuestFrame visually invisible while keeping the quest
    -- interaction alive.  We move it off-screen and suppress mouse input.
    if QuestFrame then
        QuestFrame:SetAlpha(0)
        QuestFrame:EnableMouse(false)
        -- Move off-screen so it doesn't intercept clicks even if re-shown
        if not QuestFrame._muiStashed then
            QuestFrame._muiStashed = true
            QuestFrame:ClearAllPoints()
            QuestFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -9999, 9999)
        end
    end
end

local function RestoreDefaultQuestFrame()
    -- Undo our visual suppression when the interaction ends (QUEST_FINISHED).
    -- We don't need to restore position — QuestFrame's OnShow will re-anchor
    -- it via UIParentPanelManager next time it opens.
    if QuestFrame and QuestFrame._muiStashed then
        QuestFrame._muiStashed = nil
        QuestFrame:SetAlpha(1)
        QuestFrame:EnableMouse(true)
        -- Let Blizzard re-anchor next show via panel manager
    end
end

local function SuppressDefaultGossipFrame()
    if type(GossipFrame) == "table" and type(GossipFrame.SetAlpha) == "function" then
        GossipFrame:SetAlpha(0)
        if type(GossipFrame.EnableMouse) == "function" then
            GossipFrame:EnableMouse(false)
        end
        if not GossipFrame._muiStashed
            and type(GossipFrame.ClearAllPoints) == "function"
            and type(GossipFrame.SetPoint) == "function" then
            GossipFrame._muiStashed = true
            GossipFrame:ClearAllPoints()
            GossipFrame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -9999, 9999)
        end
    end
end

local function RestoreDefaultGossipFrame()
    if type(GossipFrame) == "table" and GossipFrame._muiStashed then
        GossipFrame._muiStashed = nil
        if type(GossipFrame.SetAlpha) == "function" then
            GossipFrame:SetAlpha(1)
        end
        if type(GossipFrame.EnableMouse) == "function" then
            GossipFrame:EnableMouse(true)
        end
    end
end

local GOSSIP_REFRESH_DELAYS = { 0.15, 0.40, 0.80, 1.20, 1.80, 2.40 }

local function QueueGossipRefresh(reason, attempt, nonce)
    local idx = tonumber(attempt) or 1
    local delay = GOSSIP_REFRESH_DELAYS[idx]
    if not delay then
        return
    end
    C_Timer.After(delay, function()
        if nonce ~= State.gossipRefreshNonce then return end
        if State.currentMode ~= "gossip" then return end
        if not QI:IsShown() then return end

        local _, _, textSource = PopulateGossip()
        ShowQuestFrame()
        SuppressDefaultGossipFrame()
        if textSource ~= "live" then
            QueueGossipRefresh(reason, idx + 1, nonce)
        end
    end)
end

local function OnQuestDetail()
    if State.declining then
        State.declining = nil
        SafeCall(CloseQuest)
        return
    end
    -- Populate FIRST while quest API data is still valid, THEN suppress
    PopulateDetail()
    ShowQuestFrame()
    SuppressDefaultQuestFrame()
end

local function OnQuestProgress()
    if State.declining then
        State.declining = nil
        SafeCall(CloseQuest)
        return
    end
    PopulateProgress()
    ShowQuestFrame()
    SuppressDefaultQuestFrame()
end

local function OnQuestComplete()
    if State.declining then
        State.declining = nil
        SafeCall(CloseQuest)
        return
    end
    PopulateComplete()
    ShowQuestFrame()
    SuppressDefaultQuestFrame()
end

local function OnQuestGreeting()
    if State.declining then
        State.declining = nil
        SafeCall(CloseQuest)
        return
    end
    State.currentMode = "greeting"
    titleText:SetText(SafeCall(UnitName, "npc") or "")
    PopulateGreeting()
    ShowQuestFrame()
    SuppressDefaultQuestFrame()
end

local function OnGossipShow()
    if State.declining then
        State.declining = nil
        if type(C_GossipInfo) == "table" and type(C_GossipInfo.CloseGossip) == "function" then
            pcall(C_GossipInfo.CloseGossip)
        elseif type(CloseGossip) == "function" then
            pcall(CloseGossip)
        else
            SafeCall(CloseQuest)
        end
        return
    end
    State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1
    local refreshNonce = State.gossipRefreshNonce
    titleText:SetText(SafeCall(UnitName, "npc") or "")
    local _, _, textSource = PopulateGossip()
    ShowQuestFrame()
    SuppressDefaultGossipFrame()
    if textSource ~= "live" then
        QueueGossipRefresh("show", 1, refreshNonce)
    end
end

local function OnCinematicStart()
    if GossipFrame and GossipFrame:IsShown() then
        State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1
    end
end

local function OnCinematicStop()
    local s = _G.MidnightUISettings
    if type(s) == "table" and type(s.General) == "table"
       and s.General.useBlizzardQuestingInterface == true then
        return
    end
    State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1

    -- Cutscene/movie launched from gossip should return closed by default.
    if State.currentMode == "gossip" or QI:IsShown() then
        RestoreDefaultGossipFrame()
        HideQuestFrame(true)
        State.currentMode = nil
        State.typewriterDone = true
    end
end

local function OnMovieStart()
    State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1

    -- If movie starts from a gossip option, close custom frame immediately.
    if State.currentMode == "gossip" or QI:IsShown() then
        RestoreDefaultGossipFrame()
        HideQuestFrame(true)
        State.currentMode = nil
        State.typewriterDone = true
    end
end

local function OnMovieStop()
    OnCinematicStop()
end

local function OnGossipClosed()
    State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1
    RestoreDefaultGossipFrame()
    if State.currentMode == "gossip" then
        HideQuestFrame(false)
    end
end

local function OnQuestFinished()
    State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1
    RestoreDefaultQuestFrame()
    RestoreDefaultGossipFrame()
    HideQuestFrame(false)
    -- declining flag persists so the subsequent re-offer event
    -- (QUEST_DETAIL / QUEST_GREETING / GOSSIP_SHOW) can intercept it.
    -- Safety net: clear after 0.5s in case no re-offer event arrives.
    if State.declining then
        C_Timer.After(0.5, function() State.declining = nil end)
    end
end

local function OnQuestItemUpdate()
    -- Re-populate rewards if item data loaded asynchronously
    if not QI:IsShown() then return end
    if State.currentMode == "detail" then
        PopulateDetail()
    elseif State.currentMode == "complete" then
        PopulateComplete()
    elseif State.currentMode == "progress" then
        PopulateProgress()
    end
end

EventFrame:SetScript("OnEvent", function(self, event, ...)
    if event ~= "PLAYER_LOGIN" and UseBlizzardQuestingInterface() then
        if QI:IsShown() or State.currentMode ~= nil then
            State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1
            RestoreDefaultQuestFrame()
            RestoreDefaultGossipFrame()
            HideQuestFrame(true)
            State.currentMode = nil
            State.typewriterDone = true
            State.fadeDir = 0
        end
        return
    end

    if event == "QUEST_DETAIL" then
        OnQuestDetail()
    elseif event == "QUEST_PROGRESS" then
        OnQuestProgress()
    elseif event == "QUEST_COMPLETE" then
        OnQuestComplete()
    elseif event == "QUEST_GREETING" then
        OnQuestGreeting()
    elseif event == "QUEST_FINISHED" then
        OnQuestFinished()
    elseif event == "QUEST_ITEM_UPDATE" then
        OnQuestItemUpdate()
    elseif event == "GOSSIP_SHOW" then
        OnGossipShow()
    elseif event == "GOSSIP_CLOSED" then
        OnGossipClosed()
    elseif event == "CINEMATIC_START" then
        OnCinematicStart()
    elseif event == "CINEMATIC_STOP" then
        OnCinematicStop()
    elseif event == "PLAY_MOVIE" then
        OnMovieStart(...)
    elseif event == "STOP_MOVIE" then
        OnMovieStop(...)
    elseif event == "PLAYER_LOGIN" then
        self:UnregisterEvent("PLAYER_LOGIN")
        State.initialized = true
        if UseBlizzardQuestingInterface() then
            RestoreDefaultQuestFrame()
            RestoreDefaultGossipFrame()
            HideQuestFrame(true)
            State.currentMode = nil
            State.typewriterDone = true
            State.fadeDir = 0

            self:UnregisterEvent("QUEST_DETAIL")
            self:UnregisterEvent("QUEST_PROGRESS")
            self:UnregisterEvent("QUEST_COMPLETE")
            self:UnregisterEvent("QUEST_GREETING")
            self:UnregisterEvent("QUEST_FINISHED")
            self:UnregisterEvent("QUEST_ITEM_UPDATE")
            self:UnregisterEvent("GOSSIP_SHOW")
            self:UnregisterEvent("GOSSIP_CLOSED")
            self:UnregisterEvent("CINEMATIC_START")
            self:UnregisterEvent("CINEMATIC_STOP")
            self:UnregisterEvent("PLAY_MOVIE")
            self:UnregisterEvent("STOP_MOVIE")
            return
        end

        -- ── Suppress the default QuestFrame ──
        -- Hook OnShow to visually stash it whenever our interface is active.
        -- We CANNOT use HideUIPanel or :Hide() here — both trigger the
        -- panel manager teardown which calls CloseQuest() and kills the
        -- server-side quest interaction (all API calls return empty).
        if QuestFrame then
            QuestFrame:HookScript("OnShow", function(f)
                local s = _G.MidnightUISettings
                if type(s) == "table" and type(s.General) == "table"
                   and s.General.useBlizzardQuestingInterface == true then
                    return -- let Blizzard handle it
                end
                SuppressDefaultQuestFrame()
            end)
        end

        if GossipFrame then
            GossipFrame:HookScript("OnShow", function(f)
                local s = _G.MidnightUISettings
                if type(s) == "table" and type(s.General) == "table"
                   and s.General.useBlizzardQuestingInterface == true then
                    return -- let Blizzard handle it
                end
                SuppressDefaultGossipFrame()
            end)
        end
    end
end)

-- Register events
EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:RegisterEvent("QUEST_DETAIL")
EventFrame:RegisterEvent("QUEST_PROGRESS")
EventFrame:RegisterEvent("QUEST_COMPLETE")
EventFrame:RegisterEvent("QUEST_GREETING")
EventFrame:RegisterEvent("QUEST_FINISHED")
EventFrame:RegisterEvent("QUEST_ITEM_UPDATE")
EventFrame:RegisterEvent("GOSSIP_SHOW")
EventFrame:RegisterEvent("GOSSIP_CLOSED")
EventFrame:RegisterEvent("CINEMATIC_START")
EventFrame:RegisterEvent("CINEMATIC_STOP")
EventFrame:RegisterEvent("PLAY_MOVIE")
EventFrame:RegisterEvent("STOP_MOVIE")

-- ────────────────────────────────────────────────────────────────────────────
-- §21  ESCAPE KEY SUPPORT
-- ────────────────────────────────────────────────────────────────────────────
-- Add our frame to the special frames table so Escape closes it
-- (this is done after PLAYER_LOGIN to ensure UISpecialFrames exists)
QI:SetScript("OnShow", function()
    -- Register for Escape key closing
    local found = false
    for _, name in ipairs(UISpecialFrames) do
        if name == "MidnightUI_QuestInterface" then
            found = true
            break
        end
    end
    if not found then
        table.insert(UISpecialFrames, "MidnightUI_QuestInterface")
    end
end)

QI:SetScript("OnHide", function()
    -- Ensure the quest interaction is properly closed server-side
    -- (prevent stuck NPC dialogs)
    ResetContent()
    State.gossipRefreshNonce = (State.gossipRefreshNonce or 0) + 1
    RestoreDefaultQuestFrame()
    RestoreDefaultGossipFrame()
    State.currentMode = nil
    State.typewriterDone = true
    State.fadeDir = 0
end)

-- ────────────────────────────────────────────────────────────────────────────
-- §22  QUEST ACCEPTED BANNER
-- ────────────────────────────────────────────────────────────────────────────
-- A cinematic "Quest Accepted" splash that fades in then out over the centre
-- of the screen.  Uses the midnight-score-topper atlas (467 x 71).

local classBannerAtlas = {
    HUNTER      = "UI-Centaur-Highlight-Bottom",
    ROGUE       = "UI-Centaur-Highlight-Bottom",
    EVOKER      = "UI-Dream-Highlight-Bottom",
    MONK        = "UI-Dream-Highlight-Bottom",
    DEATHKNIGHT = "UI-Expedition-Highlight-Bottom",
    PALADIN     = "UI-Expedition-Highlight-Bottom",
    WARRIOR     = "UI-Niffen-Highlight-Bottom",
    DRUID       = "UI-Niffen-Highlight-Bottom",
    MAGE        = "ui-plunderstorm-highlight-bottom",
    SHAMAN      = "UI-Tuskarr-Highlight-Bottom",
    DEMONHUNTER = "UI-Valdrakken-Highlight-Bottom",
    PRIEST      = "UI-Valdrakken-Highlight-Bottom",
    WARLOCK     = "UI-Valdrakken-Highlight-Bottom",
}
local function GetBannerAtlas()
    local _, pc = UnitClass("player")
    return classBannerAtlas[pc] or "UI-Valdrakken-Highlight-Bottom"
end

local bannerFrame = CreateFrame("Frame", nil, UIParent)
bannerFrame:SetSize(798, 228)
bannerFrame:SetPoint("TOP", UIParent, "TOP", 0, -72)
bannerFrame:SetFrameStrata("TOOLTIP")
bannerFrame:SetAlpha(0)
bannerFrame:Hide()

-- Background atlas — text sits on top of this
local bannerBg = bannerFrame:CreateTexture(nil, "BACKGROUND")
bannerBg:SetAllPoints()
bannerBg:SetAlpha(0.65)

-- "Quest Accepted" title — centered on the banner
local bannerText = bannerFrame:CreateFontString(nil, "OVERLAY")
TrySetFont(bannerText, TITLE_FONT, 28, "OUTLINE")
bannerText:SetPoint("CENTER", bannerFrame, "CENTER", 0, 8)
bannerText:SetText("Quest Accepted")
bannerText:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
bannerText:SetShadowColor(0, 0, 0, 0.8)
bannerText:SetShadowOffset(2, -2)

-- Quest name subtitle — below the title
local bannerSubtitle = bannerFrame:CreateFontString(nil, "OVERLAY")
TrySetFont(bannerSubtitle, BODY_FONT, 15, "OUTLINE")
bannerSubtitle:SetPoint("TOP", bannerText, "BOTTOM", 0, -14)
bannerSubtitle:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.9)
bannerSubtitle:SetShadowColor(0, 0, 0, 0.8)
bannerSubtitle:SetShadowOffset(1, -1)
bannerSubtitle:SetText("")

local bannerState = {
    active   = false,
    timer    = 0,
    holdTime = 1.8,
    fadeIn   = 0.35,
    fadeOut  = 0.60,
    phase    = "idle",
}

function ShowQuestAcceptedBanner(questName)
    bannerState.active = true
    bannerState.timer = 0
    bannerState.phase = "fadein"
    bannerFrame:SetAlpha(0)
    bannerFrame:Show()
    bannerSubtitle:SetText(questName or "")
    if bannerBg.SetAtlas then
        pcall(bannerBg.SetAtlas, bannerBg, GetBannerAtlas(), false)
    end
end

bannerFrame:SetScript("OnUpdate", function(self, elapsed)
    if not bannerState.active then return end
    bannerState.timer = bannerState.timer + elapsed

    if bannerState.phase == "fadein" then
        local p = math.min(1, bannerState.timer / bannerState.fadeIn)
        self:SetAlpha(Smoothstep(p))
        if p >= 1 then
            bannerState.phase = "hold"
            bannerState.timer = 0
        end
    elseif bannerState.phase == "hold" then
        self:SetAlpha(1)
        if bannerState.timer >= bannerState.holdTime then
            bannerState.phase = "fadeout"
            bannerState.timer = 0
        end
    elseif bannerState.phase == "fadeout" then
        local p = math.min(1, bannerState.timer / bannerState.fadeOut)
        self:SetAlpha(1 - Smoothstep(p))
        if p >= 1 then
            bannerState.active = false
            bannerState.phase = "idle"
            self:SetAlpha(0)
            self:Hide()
        end
    end
end)

-- ────────────────────────────────────────────────────────────────────────────
-- §22b  QUEST COMPLETE BANNER
-- ────────────────────────────────────────────────────────────────────────────
-- Identical structure to the Quest Accepted banner.

local completeBannerFrame = CreateFrame("Frame", nil, UIParent)
completeBannerFrame:SetSize(798, 228)
completeBannerFrame:SetPoint("TOP", UIParent, "TOP", 0, -72)
completeBannerFrame:SetFrameStrata("TOOLTIP")
completeBannerFrame:SetAlpha(0)
completeBannerFrame:Hide()

local completeBannerBg = completeBannerFrame:CreateTexture(nil, "BACKGROUND")
completeBannerBg:SetAllPoints()
completeBannerBg:SetAlpha(0.8)

local completeBannerText = completeBannerFrame:CreateFontString(nil, "OVERLAY")
TrySetFont(completeBannerText, TITLE_FONT, 28, "OUTLINE")
completeBannerText:SetPoint("CENTER", completeBannerFrame, "CENTER", 0, 8)
completeBannerText:SetText("Quest Complete")
completeBannerText:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
completeBannerText:SetShadowColor(0, 0, 0, 0.8)
completeBannerText:SetShadowOffset(2, -2)

local completeBannerSubtitle = completeBannerFrame:CreateFontString(nil, "OVERLAY")
TrySetFont(completeBannerSubtitle, BODY_FONT, 15, "OUTLINE")
completeBannerSubtitle:SetPoint("TOP", completeBannerText, "BOTTOM", 0, -6)
completeBannerSubtitle:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.9)
completeBannerSubtitle:SetShadowColor(0, 0, 0, 0.8)
completeBannerSubtitle:SetShadowOffset(1, -1)
completeBannerSubtitle:SetText("")

local completeBannerState = {
    active   = false,
    timer    = 0,
    holdTime = 1.8,
    fadeIn   = 0.35,
    fadeOut  = 0.60,
    phase    = "idle",
}

function ShowQuestCompleteBanner(questName)
    completeBannerState.active = true
    completeBannerState.timer = 0
    completeBannerState.phase = "fadein"
    completeBannerFrame:SetAlpha(0)
    completeBannerFrame:Show()
    completeBannerSubtitle:SetText(questName or "")
    if completeBannerBg.SetAtlas then
        pcall(completeBannerBg.SetAtlas, completeBannerBg, GetBannerAtlas(), false)
    end
end

completeBannerFrame:SetScript("OnUpdate", function(self, elapsed)
    if not completeBannerState.active then return end
    completeBannerState.timer = completeBannerState.timer + elapsed

    if completeBannerState.phase == "fadein" then
        local p = math.min(1, completeBannerState.timer / completeBannerState.fadeIn)
        self:SetAlpha(Smoothstep(p))
        if p >= 1 then
            completeBannerState.phase = "hold"
            completeBannerState.timer = 0
        end
    elseif completeBannerState.phase == "hold" then
        self:SetAlpha(1)
        if completeBannerState.timer >= completeBannerState.holdTime then
            completeBannerState.phase = "fadeout"
            completeBannerState.timer = 0
        end
    elseif completeBannerState.phase == "fadeout" then
        local p = math.min(1, completeBannerState.timer / completeBannerState.fadeOut)
        self:SetAlpha(1 - Smoothstep(p))
        if p >= 1 then
            completeBannerState.active = false
            completeBannerState.phase = "idle"
            self:SetAlpha(0)
            self:Hide()
        end
    end
end)

-- ────────────────────────────────────────────────────────────────────────────
-- §23  PUBLIC API
-- ────────────────────────────────────────────────────────────────────────────
-- Attach API methods directly to the frame so that _G.MidnightUI_QuestInterface
-- (set by CreateFrame) remains the real frame.  Overwriting the global with a
-- plain table broke UISpecialFrames: CloseWindows could call :Hide() on a table
-- that lacked the method, producing "attempt to call method 'Hide' (a nil value)".
QI.GetState    = function() return State.currentMode end
QI.ForceClose  = function() HideQuestFrame(true) end

-- ────────────────────────────────────────────────────────────────────────────
--  EOF
-- ────────────────────────────────────────────────────────────────────────────
