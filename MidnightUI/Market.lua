--------------------------------------------------------------------------------
-- Market.lua | MidnightUI
-- PURPOSE: Monitors Trade and Services chat channels for watchlist keyword
--          matches, classifies messages by intent (buy/sell/craft), and stores
--          matched messages in the Messenger history under a "Market" tab.
-- DEPENDS ON: Messenger (MessengerDB global, History table, UpdateTabLayout,
--             MyMessenger_RefreshDisplay)
-- EXPORTS: None (self-contained event-driven module)
-- ARCHITECTURE: Standalone frame that listens to ADDON_LOADED and
--               CHAT_MSG_CHANNEL events. Writes into MessengerDB.History
--               which the Messenger UI reads for display. No direct UI of its
--               own; all rendering is handled by the Messenger tab system.
--------------------------------------------------------------------------------

local Market = CreateFrame("Frame")
Market:RegisterEvent("ADDON_LOADED")
Market:RegisterEvent("CHAT_MSG_CHANNEL")

-- ============================================================================
-- DATABASE INITIALIZATION
-- Creates the Market history bucket and default watchlist inside MessengerDB.
-- ============================================================================

--- InitMarketDB: Ensures MessengerDB has a "Market" history entry and a default
--  watchlist if neither exists yet.
-- @calls None (pure data initialization)
-- @calledby Market OnEvent handler on ADDON_LOADED
-- @note Only runs when MessengerDB already exists (Messenger loads first).
--       The watchlist is a simple { [keyword] = bool } map; users can add/remove
--       keywords at runtime through the Messenger UI.
local function InitMarketDB()
    if not MessengerDB then return end

    --- MessengerDB.History["Market"] shape:
    -- {
    --   unread   = (number) count of messages not yet viewed in the Market tab,
    --   messages = { [1..N] = dataObject }  -- see dataObject shape in ProcessMatch
    -- }
    if not MessengerDB.History["Market"] then
        MessengerDB.History["Market"] = {
            unread = 0,
            messages = {}
        }
    end

    --- MessengerDB.MarketWatchList shape:
    -- { [keywordString] = true/false }
    -- When true the keyword is actively scanned in trade/services messages.
    if not MessengerDB.MarketWatchList then
        MessengerDB.MarketWatchList = {
            ["Blacksmithing"] = true,
            ["Leatherworking"] = true,
            ["Lariat"] = true,
        }
    end
end

-- ============================================================================
-- MESSAGE CLASSIFICATION
-- Determines the intent of a trade-channel message so the Market tab can
-- color-code and tag each entry.
-- ============================================================================

--- GetMessageContext: Classifies a chat message into one of four intent
--  categories based on keyword heuristics.
-- @param msg (string) - The raw chat message text
-- @return tag (string) - One of "BUY", "WORK", "SELL", or "DEAL"
-- @return color (string) - Six-character hex color code for display
-- @note Priority order: BUY > WORK > SELL > DEAL (fallback).
--       Matching is case-insensitive via string.lower.
local function GetMessageContext(msg)
    local lower = string.lower(msg)
    if string.find(lower, "wtb") or string.find(lower, "buying") or string.find(lower, "lf ") then
        return "BUY", "00ff00"
    elseif string.find(lower, "lfw") or string.find(lower, "craft") or string.find(lower, "work") then
        return "WORK", "b048f8"
    elseif string.find(lower, "wts") or string.find(lower, "selling") or string.find(lower, "wtt") then
        return "SELL", "ffd700"
    end
    return "DEAL", "ff9900"
end

-- ============================================================================
-- EVENT HANDLER
-- Drives the entire module: initializes DB on load, then filters and stores
-- every matching trade-channel message.
-- ============================================================================

Market:SetScript("OnEvent", function(self, event, ...)
    -- -----------------------------------------------------------------------
    -- ADDON_LOADED: One-time database bootstrap when MidnightUI finishes loading
    -- -----------------------------------------------------------------------
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == "MidnightUI" then
            InitMarketDB()
        end

    -- -----------------------------------------------------------------------
    -- CHAT_MSG_CHANNEL: Real-time trade/services message scanning
    -- Flow: filter self -> filter channel -> scan watchlist -> store match
    -- -----------------------------------------------------------------------
    elseif event == "CHAT_MSG_CHANNEL" then
        if not MessengerDB then return end

        local msg, author, _, _, _, _, _, _, channelName = ...

        -- Skip messages sent by the current player to avoid self-alerts
        local playerName = UnitName("player")
        if author and playerName and string.find(author, playerName) then
            return
        end

        -- Only process messages from Trade and Services channels
        -- Channel names are locale-dependent but contain "Trade" or "Services"
        if channelName and (string.find(channelName, "Trade") or string.find(channelName, "Services")) then

            local lowerMsg = string.lower(msg)
            local matchFound = false
            local matchedKeyword = ""

            -- Scan every enabled watchlist keyword against the message (case-insensitive, plain match)
            if MessengerDB.MarketWatchList then
                for keyword, enabled in pairs(MessengerDB.MarketWatchList) do
                    if enabled then
                        if string.find(lowerMsg, string.lower(keyword), 1, true) then
                            matchFound = true
                            matchedKeyword = keyword
                            break
                        end
                    end
                end
            end

            -- Store matched message and notify the Messenger UI
            if matchFound then
                -- Strip realm suffix from author name for cleaner display
                local shortName = author
                if string.find(shortName, "-") then
                    shortName = strsplit("-", shortName)
                end

                local contextTag, contextColor = GetMessageContext(msg)

                --- dataObject shape (one entry in History["Market"].messages):
                -- {
                --   msg              = (string)  original chat message,
                --   author           = (string)  sender name without realm,
                --   timestamp        = (string)  "HH:MM" formatted time,
                --   nameColorDefault = (string)  6-char hex color from context,
                --   msgColorDefault  = (string)  6-char hex color for body text,
                --   tag              = (string)  "[CONTEXT: keyword]" label,
                -- }
                local dataObject = {
                    msg = msg,
                    author = shortName,
                    timestamp = date("%H:%M"),
                    nameColorDefault = contextColor,
                    msgColorDefault = "eeeeee",
                    tag = string.format("[%s: %s]", contextTag, matchedKeyword)
                }

                if MessengerDB.History["Market"] then
                    table.insert(MessengerDB.History["Market"].messages, dataObject)

                    -- Cap history at 200 entries to bound memory usage
                    if #MessengerDB.History["Market"].messages > 200 then
                        table.remove(MessengerDB.History["Market"].messages, 1)
                    end

                    MessengerDB.History["Market"].unread = MessengerDB.History["Market"].unread + 1

                    -- Cross-module call: tell Messenger to refresh tab badges
                    if _G.UpdateTabLayout then _G.UpdateTabLayout() end

                    -- Cross-module call: live-refresh the message list if Market tab is active
                    if _G.MyMessenger_RefreshDisplay then _G.MyMessenger_RefreshDisplay() end
                end
            end
        end
    end
end)
