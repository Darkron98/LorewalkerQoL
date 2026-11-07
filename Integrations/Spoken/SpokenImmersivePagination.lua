-- Syncs immersive paragraph changes and playback pace to Spoken captions.
-- Requires Lorewalker and Spoken; ambiguous text matches fall back to Lorewalker's normal playback.
local _, addon = ...
local compat = addon.Compat or {}
addon.Compat = compat

local MODE_IMMERSIVE = 2 -- Lorewalker's Preload.Enum.Mode.Immersive
local TICK = 0.05
local TRANSITION_DELAY = 0
local MIN_PARAGRAPHS = 2
local MIN_ANCHOR_WORDS = 3
local MAX_ANCHOR_WORDS = 8
local MIN_PLAYBACK_INTERVAL_FACTOR = 0.5
local MAX_PLAYBACK_INTERVAL_FACTOR = 2
local TEXT_PLAYBACK_PAUSE_DURATION = 0.125
local PAUSE_CHARACTERS = { "…", "!", "?", ".", ",", ";", ":" }
local elapsed = 0
local bubble
local originalShowNext
local originalScheduleAutoProgress
local clip
local sourceText
local messagesRef
local boundaries
local syncing = false
local pendingTimer
local pendingTarget
local pendingSerial = 0
local IsEligible

local function IsAddonLoaded(name)
    if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded then
        return _G.C_AddOns.IsAddOnLoaded(name)
    end
    return _G.IsAddOnLoaded and _G.IsAddOnLoaded(name) or false
end

local function IsImmersiveActive()
    local handler = _G.Modes_ModeHandler
    local mode = handler and handler.modes and handler.modes[MODE_IMMERSIVE]
    return mode and mode.isActive == true or false
end

local function CancelPending()
    pendingSerial = pendingSerial + 1
    if pendingTimer and pendingTimer.Cancel then pendingTimer:Cancel() end
    pendingTimer, pendingTarget = nil, nil
end

local function SetPlaybackInterval(state, interval)
    local previousInterval = tonumber(state and state.interval)
    if not previousInterval or previousInterval <= 0 or not interval or interval <= 0 then return end

    -- Keep the currently revealed character stable when changing the interval.
    local characterProgress = (tonumber(state.elapsed) or 0) / previousInterval
    state.interval = interval
    state.elapsed = characterProgress * interval
end

local function RestoreAdaptivePlayback()
    local state = bubble and bubble.textPlaybackState
    local baseInterval = state and state.__lqocBaseInterval
    if not baseInterval then return end

    -- Restore the user's configured interval without changing the character already revealed.
    SetPlaybackInterval(state, baseInterval)
    state.__lqocBaseInterval = nil
    state.__lqocAdaptiveClip = nil
    state.__lqocAdaptivePage = nil
end

local function CountPauseCharacters(text)
    if type(text) ~= "string" then return 0 end

    -- Ignore visual markup so item links, textures, and color codes do not inflate the pause estimate.
    local plainText = text
    plainText = string.gsub(plainText, "|c%x%x%x%x%x%x%x%x", "")
    plainText = string.gsub(plainText, "|r", "")
    plainText = string.gsub(plainText, "|T.-|t", "")
    plainText = string.gsub(plainText, "|A.-|a", "")
    plainText = string.gsub(plainText, "|H.-|h(.-)|h", "%1")

    local count = 0
    for _, character in ipairs(PAUSE_CHARACTERS) do
        local from = 1
        while true do
            local first, last = string.find(plainText, character, from, true)
            if not first then break end
            count = count + 1
            from = last + 1
        end
    end
    return count
end

local function GetWordTime(caption, wordIndex)
    local word = caption.words and caption.words[wordIndex]
    local totalWeight = tonumber(caption.totalWeight)
    local clipLength = tonumber(caption.clip and caption.clip.length)
    local finish = word and tonumber(word.finish)
    if not totalWeight or totalWeight <= 0 or not clipLength or clipLength <= 0 or not finish then
        return nil
    end

    -- Timed captions use seconds as their weight; estimated captions use spoken-word weights.
    -- Converting through the total keeps both forms on the clip's elapsed-time scale.
    return finish / totalWeight * clipLength
end

local function ApplyAdaptivePlayback(page, caption)
    if not bubble or page ~= bubble.messageIndex then return end

    local state = bubble.textPlaybackState
    local baseInterval = state and tonumber(state.__lqocBaseInterval or state.interval)
    if not state or not baseInterval or baseInterval <= 0 then return end

    if state.__lqocAdaptiveClip ~= caption.clip or state.__lqocAdaptivePage ~= page then
        RestoreAdaptivePlayback()
        state = bubble.textPlaybackState
        baseInterval = state and tonumber(state.interval)
        if not state or not baseInterval or baseInterval <= 0 then return end
    elseif state.__lqocAdaptiveClip == caption.clip and state.__lqocAdaptivePage == page then
        return
    end

    local pageStart = page == 1 and 1 or ((boundaries[page - 1] or 0) + 1)
    local pageEnd = boundaries[page] or #caption.words
    if pageStart < 1 or pageEnd < pageStart then return end

    local endTime = GetWordTime(caption, pageEnd)
    local clipLength = tonumber(caption.clip.length)
    local progress = tonumber(caption.progress)
    if not endTime or not clipLength or not progress then return end

    -- Fit the unrevealed characters into the remaining time for this paragraph's matched caption words.
    local remainingSpeech = endTime - progress * clipLength
    if remainingSpeech <= 0 then return end

    local utf8Length = _G.strlenutf8
    local textLength = type(utf8Length) == "function" and utf8Length(state.text or "") or #(state.text or "")
    if textLength <= 0 then return end

    local currentCharacter = math.min(math.floor((tonumber(state.elapsed) or 0) / state.interval) + 1, textLength)
    local remainingCharacters = textLength - currentCharacter
    if remainingCharacters <= 0 then return end

    local remainingFraction = remainingCharacters / textLength
    local pauseBudget = state.pauseEnabled
        and CountPauseCharacters(state.text) * TEXT_PLAYBACK_PAUSE_DURATION * remainingFraction
        or 0
    local revealDuration = math.max(0, remainingSpeech - pauseBudget)
    if revealDuration <= 0 then return end

    -- Clamp relative to the user's base speed so long or short clips cannot cause extreme rates.
    local targetInterval = revealDuration / remainingCharacters
    targetInterval = math.max(baseInterval * MIN_PLAYBACK_INTERVAL_FACTOR,
        math.min(baseInterval * MAX_PLAYBACK_INTERVAL_FACTOR, targetInterval))

    state.__lqocBaseInterval = baseInterval
    state.__lqocAdaptiveClip = caption.clip
    state.__lqocAdaptivePage = page
    SetPlaybackInterval(state, targetInterval)
end

local function ClearSync()
    local wasSyncing = syncing
    -- Leave temporary speed overrides behind when captions stop, mismatch, or the bubble closes.
    RestoreAdaptivePlayback()
    CancelPending()
    clip, sourceText, messagesRef, boundaries, syncing, elapsed = nil, nil, nil, nil, false, 0
    if wasSyncing and bubble and IsEligible() and not bubble.textPlaybackState then
        bubble:ScheduleAutoProgress()
    end
end

IsEligible = function()
    return bubble and _G.LWImmersiveChatBubble == bubble and bubble:IsShown()
        and bubble.messages and #bubble.messages >= MIN_PARAGRAPHS
        and type(bubble.messageIndex) == "number" and IsImmersiveActive()
end

local function PageAnchor(text, marks, splitCaption)
    if type(text) ~= "string" then return nil end
    local words = splitCaption(text)
    if type(words) ~= "table" then return nil end

    local keys = {}
    for _, word in ipairs(words) do
        local key = marks.Key(word.text)
        if key then keys[#keys + 1] = key end
    end
    if #keys < MIN_ANCHOR_WORDS then return nil end
    return keys
end

-- Each boundary tries progressively longer suffixes of the Lorewalker paragraph. The first
-- unique, in-order match wins; ambiguous or out-of-order anchors disable syncing rather than guess.
local function BuildBoundaries(messages, captionWords, marks, splitCaption)
    local captionKeys = {}
    for index, word in ipairs(captionWords) do
        local key = marks.Key(word.text)
        if key then captionKeys[#captionKeys + 1] = { key = key, wordIndex = index } end
    end

    local result, previousEnd = {}, 0
    for page = 1, #messages - 1 do
        local paragraphKeys = PageAnchor(messages[page] and messages[page].text, marks, splitCaption)
        if not paragraphKeys then return nil end

        local endIndex
        local maxAnchorWords = math.min(MAX_ANCHOR_WORDS, #paragraphKeys)
        for anchorWords = MIN_ANCHOR_WORDS, maxAnchorWords do
            local found, count = nil, 0
            for start = 1, #captionKeys - anchorWords + 1 do
                local matches = true
                for offset = 1, anchorWords do
                    if captionKeys[start + offset - 1].key ~= paragraphKeys[#paragraphKeys - anchorWords + offset] then
                        matches = false
                        break
                    end
                end
                if matches then
                    count = count + 1
                    found = start
                    if count > 1 then break end
                end
            end

            if count == 1 then
                local candidateEnd = captionKeys[found + anchorWords - 1].wordIndex
                if candidateEnd > previousEnd then
                    endIndex = candidateEnd
                    break
                end
            end
        end
        if not endIndex then return nil end
        result[page] = endIndex
        previousEnd = endIndex
    end
    return result
end

local function SetPage(target)
    if target == bubble.messageIndex or target < 1 or target > #bubble.messages then return end
    bubble.isFinished = false
    bubble:CancelAutoProgress()
    bubble:SetMessageToIndex(target, false, false)
    bubble.AnimGroup:Stop()
    bubble.AnimGroup:Play(bubble, "NEW")
end

local function RequestPage(target)
    if target <= (bubble.messageIndex or 1) then
        CancelPending()
        return
    end
    -- Coalesce forward page requests while the zero-delay transition is pending.
    pendingTarget = math.max(target, pendingTarget or target)
    if pendingTimer then return end

    pendingSerial = pendingSerial + 1
    local serial = pendingSerial
    local expectedClip, expectedSource, expectedMessages = clip, sourceText, messagesRef
    if _G.C_Timer and _G.C_Timer.NewTimer then
        pendingTimer = _G.C_Timer.NewTimer(TRANSITION_DELAY, function()
            if serial ~= pendingSerial then return end
            local targetNow = pendingTarget
            pendingTimer, pendingTarget = nil, nil
            if not syncing or clip ~= expectedClip or sourceText ~= expectedSource
                or messagesRef ~= expectedMessages or not IsEligible() then return end
            SetPage(targetNow or target)
        end)
    else
        SetPage(pendingTarget)
        CancelPending()
    end
end

local function Follow(_, delta)
    elapsed = elapsed + delta
    if elapsed < TICK then return end
    elapsed = 0

    if not IsEligible() or not IsAddonLoaded("Spoken") then
        ClearSync()
        return
    end

    local spoken = _G.Spoken
    if type(spoken) ~= "table" or type(spoken.GetCaption) ~= "function"
        or type(spoken.WordMarks) ~= "function" or type(spoken.SplitCaption) ~= "function" then
        ClearSync()
        return
    end

    local caption = spoken:GetCaption()
    if not caption or not caption.clip or not caption.speaking or not caption.activeWord
        or type(caption.words) ~= "table" then
        ClearSync()
        return
    end

    -- Rebuild alignment only when Spoken's clip or Lorewalker's displayed text changes.
    if caption.clip ~= clip or bubble.sourceText ~= sourceText or bubble.messages ~= messagesRef then
        local marks = spoken:WordMarks()
        if type(marks) ~= "table" or type(marks.Key) ~= "function" then
            ClearSync()
            return
        end
        boundaries = BuildBoundaries(bubble.messages, caption.words, marks, function(text)
            return spoken:SplitCaption(text)
        end)
        clip = boundaries and caption.clip or nil
        sourceText = boundaries and bubble.sourceText or nil
        messagesRef = boundaries and bubble.messages or nil
    end

    if not (clip == caption.clip and boundaries) then
        ClearSync()
        return
    end

    local target = 1
    for page = 1, #boundaries do
        -- Wait until Spoken has passed the three-word anchor, not merely started it.
        if caption.activeWord > boundaries[page] then
            target = page + 1
        else
            break
        end
    end

    syncing = true
    bubble:CancelAutoProgress()
    RequestPage(target)
    ApplyAdaptivePlayback(target, caption)
end

local function InstallOnBubble(current)
    if bubble == current then return end
    if bubble then
        RestoreAdaptivePlayback()
        bubble.ShowNextMessage = originalShowNext
        bubble.ScheduleAutoProgress = originalScheduleAutoProgress
    end

    bubble = current
    if not bubble then return end
    originalShowNext = bubble.ShowNextMessage
    originalScheduleAutoProgress = bubble.ScheduleAutoProgress

    bubble.ShowNextMessage = function(self, continueAutoProgress)
        if syncing and continueAutoProgress then
            self:CancelAutoProgress()
            return true
        end
        return originalShowNext(self, continueAutoProgress)
    end
    bubble.ScheduleAutoProgress = function(self)
        if syncing then
            self:CancelAutoProgress()
            return
        end
        return originalScheduleAutoProgress(self)
    end
end

local driver
function compat.InitializeSpokenImmersivePagination()
    -- Install the driver only after both addon APIs and Lorewalker's immersive bubble exist.
    if not IsAddonLoaded("Lorewalker") or not IsAddonLoaded("Spoken") then return false end
    if type(_G.LWImmersiveChatBubble) ~= "table" or type(_G.Spoken) ~= "table" then return false end

    InstallOnBubble(_G.LWImmersiveChatBubble)
    if not driver then
        driver = _G.CreateFrame("Frame")
        driver:SetScript("OnUpdate", Follow)
    end
    return true
end

function compat.DisableSpokenImmersivePagination()
    ClearSync()
    if bubble then
        bubble.ShowNextMessage = originalShowNext
        bubble.ScheduleAutoProgress = originalScheduleAutoProgress
    end
    bubble, originalShowNext, originalScheduleAutoProgress = nil, nil, nil
end

addon.RegisterModule("Compat.SpokenImmersivePagination", compat.InitializeSpokenImmersivePagination)
