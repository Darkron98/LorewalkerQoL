-- Marks fixed, choice, and received item rewards that Pawn identifies as upgrades.
-- Requires Lorewalker and Pawn; the marker art is bundled with LorewalkerQoL.
local _, addon = ...
local feature = addon.PawnUpgradeArrow or {}
addon.PawnUpgradeArrow = feature

local ICON_PATH = "Interface\\AddOns\\LorewalkerQoL\\assets\\images\\ItemIsUpgrade.png"
local MAX_CHECK_ATTEMPTS = 16
local CHECK_INTERVAL = 0.30
local REWARD_LIST_NAMES = {
    "QuestItemRewards",
    "QuestItemChoiceRewards",
    "QuestItemReceiveRewards",
}

local initialized = false
local scanPending = false
local queue = {}
local queueElapsed = 0

local function GetRewardLists()
    local dialog = _G.LWDialogFrame
    local questFrame = dialog and dialog.QuestFrame
    if not questFrame then return nil end

    local lists = {}
    for index = 1, #REWARD_LIST_NAMES do
        local group = questFrame[REWARD_LIST_NAMES[index]]
        local list = group and group.RewardListFrame
        if list and list.GetAllElementsInPoolByType then
            lists[#lists + 1] = list
        end
    end
    return lists
end

local function HideMarker(button)
    local marker = button.__lqocPawnUpgradeMarker
    if marker then marker:Hide() end
end

local function ShowMarker(button)
    local marker = button.__lqocPawnUpgradeMarker
    if not marker then
        -- Reward buttons are pooled, so create one marker per button and reuse it on later scans.
        local itemSlot = button.Item
        local iconFrame = itemSlot and itemSlot.Item
        if not itemSlot or not iconFrame then return end

        marker = _G.CreateFrame("Frame", nil, itemSlot)
        marker:SetFrameLevel(itemSlot:GetFrameLevel() + 5)
        marker:SetSize(32, 32)
        marker:SetPoint("CENTER", iconFrame, "BOTTOMLEFT", 1, 5)
        marker:EnableMouse(false)
        local texture = marker:CreateTexture(nil, "OVERLAY")
        texture:SetAllPoints()
        texture:SetTexture(ICON_PATH)
        button.__lqocPawnUpgradeMarker = marker
    end
    marker:Show()
end

local function IsCurrentTask(task)
    local button = task.button
    if not button or button.__lqocPawnUpgradeToken ~= task.token then return false end
    -- A pooled button may have been rebound while item data was loading; reject stale results.
    local rewardInfo = button.rewardInfo
    return rewardInfo == task.rewardInfo
        and rewardInfo ~= nil
        and rewardInfo.rewardID == task.rewardID
        and rewardInfo.questRewardType == task.questRewardType
        and rewardInfo.questRewardIndex == task.questRewardIndex
end

local function GetItemLink(task)
    local getQuestItemLink = _G.GetQuestItemLink
    if getQuestItemLink and task.questRewardType and task.questRewardIndex then
        local ok, itemLink = pcall(getQuestItemLink, task.questRewardType, task.questRewardIndex)
        if ok and itemLink then return itemLink end
    end
    return task.button.rewardItemLink
end

local function IsEligibleReward(task, itemLink)
    local rewardInfo = task.rewardInfo
    if rewardInfo.isUsable == false then return false end
    if not itemLink then return nil end

    -- Pawn's upgrade API is the authority for whether an equippable reward
    -- improves the character; IsEquippableItem is unavailable on this client.
    local isCosmetic = _G.IsCosmeticItem
    if isCosmetic then
        local getItemInfoInstant = _G.GetItemInfoInstant
        local itemID = rewardInfo.rewardID
        if getItemInfoInstant then
            local itemInfoOK, actualItemID = pcall(getItemInfoInstant, itemLink)
            if itemInfoOK and actualItemID then itemID = actualItemID end
        end
        if itemID then
            local cosmeticOK, cosmetic = pcall(isCosmetic, itemID)
            if cosmeticOK and cosmetic then return false end
        end
    end

    return true
end

local function CheckTask(task)
    if not IsCurrentTask(task) then return end

    local itemLink = GetItemLink(task)
    local eligible = IsEligibleReward(task, itemLink)
    if eligible == false then
        HideMarker(task.button)
        return
    elseif eligible == nil then
        return "retry"
    end

    local shouldShowUpgrade = _G.PawnShouldItemLinkHaveUpgradeArrow
    if not shouldShowUpgrade then return end

    -- Item data and Pawn's result can both be temporarily unavailable; the worker retries these tasks.
    local ok, isUpgrade = pcall(shouldShowUpgrade, itemLink, false)
    if not ok or isUpgrade == nil then
        return "retry"
    end

    if IsCurrentTask(task) then
        if isUpgrade then
            ShowMarker(task.button)
        else
            HideMarker(task.button)
        end
    end
end

local worker = _G.CreateFrame("Frame")
worker:Hide()
worker:SetScript("OnUpdate", function(self, elapsed)
    queueElapsed = queueElapsed + elapsed
    if queueElapsed < CHECK_INTERVAL then return end
    queueElapsed = 0

    local task = table.remove(queue, 1)
    if not task then
        self:Hide()
        return
    end

    if CheckTask(task) == "retry" then
        task.attempts = task.attempts + 1
        if task.attempts < MAX_CHECK_ATTEMPTS and IsCurrentTask(task) then
            queue[#queue + 1] = task
        end
    end
end)

local function QueueReward(button)
    local rewardInfo = button.rewardInfo
    -- Advancing the token invalidates any queued check for the button's previous reward.
    button.__lqocPawnUpgradeToken = (button.__lqocPawnUpgradeToken or 0) + 1
    local token = button.__lqocPawnUpgradeToken
    HideMarker(button)

    if not rewardInfo or not rewardInfo.rewardID or not rewardInfo.questRewardType or not rewardInfo.questRewardIndex then
        return
    end

    queue[#queue + 1] = {
        button = button,
        rewardInfo = rewardInfo,
        rewardID = rewardInfo.rewardID,
        questRewardType = rewardInfo.questRewardType,
        questRewardIndex = rewardInfo.questRewardIndex,
        token = token,
        attempts = 0,
    }
    worker:Show()
end

local function ScanRewards()
    scanPending = false
    if not _G.LWDialogFrame or not _G.LWDialogFrame:IsShown() then return end

    queue = {}
    local lists = GetRewardLists()
    if not lists then return end

    for listIndex = 1, #lists do
        local ok, buttons = pcall(lists[listIndex].GetAllElementsInPoolByType, lists[listIndex], "Default")
        if ok and type(buttons) == "table" then
            for buttonIndex = 1, #buttons do
                local button = buttons[buttonIndex]
                local buttonOK, isVisible = pcall(function() return button:IsVisible() end)
                if buttonOK and isVisible and button.rewardInfo then
                    QueueReward(button)
                elseif button then
                    button.__lqocPawnUpgradeToken = (button.__lqocPawnUpgradeToken or 0) + 1
                    HideMarker(button)
                end
            end
        end
    end

    if #queue == 0 then worker:Hide() else worker:Show() end
end

local function ScheduleScan()
    -- Coalesce repeated list updates into one scan on the next frame.
    if scanPending then return end
    scanPending = true
    _G.C_Timer.After(0, ScanRewards)
end

local function HookRewardList(list)
    if not list or list.__lqocPawnUpgradeHooked or not list.SetData then return end
    list.__lqocPawnUpgradeHooked = true
    _G.hooksecurefunc(list, "SetData", ScheduleScan)
end

function feature.Initialize()
    if initialized then return true end
    if not _G.LWDialogFrame or not _G.PawnShouldItemLinkHaveUpgradeArrow then return false end

    local lists = GetRewardLists()
    if not lists or #lists == 0 then return false end

    -- Install hooks once; missing addon APIs or UI lists return false for a later retry.
    initialized = true
    for index = 1, #lists do
        HookRewardList(lists[index])
    end

    local dialog = _G.LWDialogFrame
    dialog:HookScript("OnShow", ScheduleScan)
    dialog:HookScript("OnHide", function()
        queue = {}
        worker:Hide()
    end)
    for _, event in ipairs({ "QUEST_DETAIL", "QUEST_COMPLETE", "QUEST_PROGRESS" }) do
        local listener = _G.CreateFrame("Frame")
        listener:RegisterEvent(event)
        listener:SetScript("OnEvent", ScheduleScan)
    end
    return true
end

addon.RegisterModule("QoL.PawnUpgradeArrow", feature.Initialize)
