-- Turn Lorewalker's immersive paragraphs after Spoken has read them.
local _, addon = ...
local compat = addon.Compat or {}
addon.Compat = compat

local MODE_IMMERSIVE = 2 -- Lorewalker's Preload.Enum.Mode.Immersive
local TICK = 0.05
local TRANSITION_DELAY = 0
local MIN_PARAGRAPHS = 2
local MIN_ANCHOR_WORDS = 3
local MAX_ANCHOR_WORDS = 8
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

local function ClearSync()
    local wasSyncing = syncing
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
end

local function InstallOnBubble(current)
    if bubble == current then return end
    if bubble then
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
