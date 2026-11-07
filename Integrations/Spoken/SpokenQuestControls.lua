-- Adds pause/skip controls for the Spoken clip matching Lorewalker's open quest.
-- Requires Lorewalker and Spoken.
local _, addon = ...
local compat = addon.Compat or {}
addon.Compat = compat

local REFRESH_INTERVAL = 0.15
local PLAY_SIZE = 24
local GAP = 2
local BUTTON_RISE = 14

local spoken
local playButton
local skipButton
local driver
local elapsed = 0
local questWindowWasOpen = false
local openQuestID

local function IsAddonLoaded(name)
    if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded then
        return _G.C_AddOns.IsAddOnLoaded(name)
    end
    return _G.IsAddOnLoaded and _G.IsAddOnLoaded(name) or false
end

local function CurrentQuestFrame()
    local dialog = _G.LWDialogFrame
    if not dialog or not dialog.IsShown or not dialog:IsShown() then return nil end
    local quest = dialog.QuestFrame
    if not quest or not quest.IsShown or not quest:IsShown() then return nil end
    return quest
end

local function CurrentQuestID()
    if type(_G.GetQuestID) ~= "function" then return nil end
    local id = _G.GetQuestID()
    return type(id) == "number" and id > 0 and id or nil
end

local function IsQuestClip(clip, questID)
    return clip and questID and clip.questID == questID
        and clip.source and clip.source.key == "quests"
end

local function MatchingCurrentClip()
    if not spoken or not CurrentQuestFrame() then return nil end
    local questID = CurrentQuestID()
    if not questID or type(spoken.GetCurrent) ~= "function" then return nil end

    -- Match by quest ID so the controls cannot affect a different queued Spoken clip.
    local clip = spoken:GetCurrent()
    if IsQuestClip(clip, questID) then return clip end
end

local function HideButtons()
    if playButton then playButton:Hide() end
    if skipButton then skipButton:Hide() end
end

local function CreateButtons()
    local quest = CurrentQuestFrame()
    local title = quest and quest.QuestTitleContainer
    local separator = title and title.ContentSeperator
    if not separator or not spoken or type(spoken.CreateRoundButton) ~= "function" then return false end

    playButton = spoken:CreateRoundButton(separator, "play")
    skipButton = spoken:CreateRoundButton(separator, "skip")
    playButton:SetSize(PLAY_SIZE, PLAY_SIZE)
    skipButton:SetSize(PLAY_SIZE, PLAY_SIZE)
    skipButton:ClearAllPoints()
    skipButton:SetPoint("RIGHT", separator, "RIGHT", -3, BUTTON_RISE)
    playButton:ClearAllPoints()
    playButton:SetPoint("RIGHT", skipButton, "LEFT", -GAP, 0)

    playButton:SetScript("OnClick", function()
        if MatchingCurrentClip() and type(spoken.TogglePause) == "function" then
            spoken:TogglePause()
        end
    end)
    playButton:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(spoken:IsPaused() and (_G.RESUME or "Resume") or (_G.PAUSE or "Pause"))
        GameTooltip:Show()
    end)
    playButton:HookScript("OnLeave", function() GameTooltip_Hide() end)

    -- The factory's default skip click acts on the queue head. Recheck the quest before skipping.
    skipButton:SetScript("OnClick", function()
        if MatchingCurrentClip() and type(spoken.Skip) == "function" then
            spoken:Skip()
        end
    end)
    return true
end

local function Refresh()
    if not playButton and not CreateButtons() then
        HideButtons()
        return
    end

    local clip = MatchingCurrentClip()
    if not clip then
        HideButtons()
        return
    end

    local nowPlaying = type(spoken.GetNowPlaying) == "function" and spoken:GetNowPlaying() or nil
    playButton:SetPlaying(nowPlaying == clip and not spoken:IsPaused())
    playButton:Show()
    skipButton:Show()
end

local function HandleQuestWindowClose()
    local questFrame = CurrentQuestFrame()
    if questFrame then
        questWindowWasOpen = true
        openQuestID = CurrentQuestID()
        return
    end

    if not questWindowWasOpen then return end
    questWindowWasOpen = false

    -- In text-only player style, skip the matching quest clip when its dialog closes.
    if openQuestID and type(spoken.GetPlayerStyle) == "function"
        and spoken:GetPlayerStyle() == "none" and type(spoken.GetCurrent) == "function"
        and type(spoken.Skip) == "function" then
        local clip = spoken:GetCurrent()
        if IsQuestClip(clip, openQuestID) then
            spoken:Skip()
        end
    end
    openQuestID = nil
end

local function OnUpdate(_, delta)
    elapsed = elapsed + delta
    if elapsed < REFRESH_INTERVAL then return end
    elapsed = 0
    HandleQuestWindowClose()
    Refresh()
end

function compat.InitializeSpokenQuestControls()
    -- Defer setup until both addons expose the objects and methods this bridge uses.
    if not IsAddonLoaded("Lorewalker") or not IsAddonLoaded("Spoken") then return false end
    spoken = _G.Spoken
    if type(spoken) ~= "table" or type(spoken.GetCurrent) ~= "function"
        or type(spoken.CreateRoundButton) ~= "function" then
        return false
    end

    if not driver then
        driver = _G.CreateFrame("Frame")
        driver:SetScript("OnUpdate", OnUpdate)
    end
    Refresh()
    return true
end

addon.RegisterModule("Compat.SpokenQuestControls", compat.InitializeSpokenQuestControls)
