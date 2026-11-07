-- Marks the choice option with the highest total vendor value (unit price × reward count).
-- Requires Lorewalker; fixed rewards are intentionally excluded.
local _, addon = ...
local feature = addon.HighestSellPrice or {}
addon.HighestSellPrice = feature

local ICON_PATH = "Interface\\AddOns\\LorewalkerQoL\\assets\\images\\Coin-Gold.png"
local MAX_RETRIES = 50
local RETRY_DELAY = 0.8
local CHOICE_LIST_NAMES = {
    "QuestItemRewards",
    "QuestItemChoiceRewards",
}

local initialized = false
local scanPending = false
local retryCount = 0

local function GetRewardLists()
    local dialog = _G.LWDialogFrame
    local questFrame = dialog and dialog.QuestFrame
    if not questFrame then return nil end

    local lists = {}
    -- Lorewalker displays choices in different visual groups before and after quest completion.
    for index = 1, #CHOICE_LIST_NAMES do
        local group = questFrame[CHOICE_LIST_NAMES[index]]
        local list = group and group.RewardListFrame
        if list and list.GetAllElementsInPoolByType then
            lists[#lists + 1] = list
        end
    end
    return lists
end

local function GetButtons(lists)
    local buttons = {}
    for listIndex = 1, #lists do
        local list = lists[listIndex]
        local ok, elements = pcall(list.GetAllElementsInPoolByType, list, "Default")
        if ok and type(elements) == "table" then
            for index = 1, #elements do
                local button = elements[index]
                -- Check semantic reward type rather than the display group so fixed items never enter this comparison.
                if button and button.rewardInfo
                    and button.rewardInfo.questRewardType == "choice" then
                    local visibleOK, isVisible = pcall(function() return button:IsVisible() end)
                    if visibleOK and isVisible then
                        buttons[#buttons + 1] = button
                    end
                end
            end
        end
    end
    return buttons
end

local function HideMarker(button)
    local marker = button.__lqocHighestSellMarker
    if marker then marker:Hide() end
end

local function ShowMarker(button)
    local marker = button.__lqocHighestSellMarker
    if not marker then
        local itemSlot = button.Item
        local iconFrame = itemSlot and itemSlot.Item
        if not itemSlot or not iconFrame then return end

        marker = _G.CreateFrame("Frame", nil, itemSlot)
        marker:SetFrameLevel(itemSlot:GetFrameLevel() + 5)
        marker:SetSize(15, 15)
        marker:SetPoint("CENTER", iconFrame, "TOPLEFT", 3, -3)
        marker:EnableMouse(false)
        local texture = marker:CreateTexture(nil, "OVERLAY")
        texture:SetAllPoints()
        texture:SetTexture(ICON_PATH)
        button.__lqocHighestSellMarker = marker
    end
    marker:Show()
end

local function GetItemLink(button)
    if button.rewardItemLink then return button.rewardItemLink end

    local rewardInfo = button.rewardInfo
    local getQuestItemLink = _G.GetQuestItemLink
    if getQuestItemLink and rewardInfo.questRewardType and rewardInfo.questRewardIndex then
        local ok, itemLink = pcall(getQuestItemLink, rewardInfo.questRewardType, rewardInfo.questRewardIndex)
        if ok and itemLink then return itemLink end
    end
end

local function GetSellPrice(itemLink)
    local itemAPI = _G.C_Item
    local getItemInfo = itemAPI and itemAPI.GetItemInfo
    if not getItemInfo or not itemLink then return nil end

    local ok, itemName, _, _, _, _, _, _, _, _, _, sellPrice = pcall(getItemInfo, itemLink)
    if not ok or not itemName then return nil end
    return tonumber(sellPrice)
end

local function GetRewardCount(button)
    local rewardInfo = button.rewardInfo
    local getQuestItemInfo = _G.GetQuestItemInfo
    if not getQuestItemInfo or not rewardInfo.questRewardType or not rewardInfo.questRewardIndex then
        return nil
    end

    local ok, _, _, count, _, _, itemID = pcall(
        getQuestItemInfo,
        rewardInfo.questRewardType,
        rewardInfo.questRewardIndex
    )
    -- Do not assume a quantity of one while the quest's current reward data is missing or stale.
    if not ok or type(count) ~= "number" or count < 1 then return nil end
    if rewardInfo.rewardID and itemID and rewardInfo.rewardID ~= itemID then return nil end
    return count
end

local function ScanRewards()
    scanPending = false
    local dialog = _G.LWDialogFrame
    if not dialog or not dialog:IsShown() then return end

    local lists = GetRewardLists()
    if not lists then return end
    local buttons = GetButtons(lists)
    if #buttons == 0 then return end

    for index = 1, #buttons do
        HideMarker(buttons[index])
    end
    -- A single choice has no alternative to compare against.
    if #buttons < 2 then return end

    local highestButton
    local highestTotalValue = -1
    local dataPending = false

    for index = 1, #buttons do
        local button = buttons[index]
        local itemLink = GetItemLink(button)
        local unitPrice = itemLink and GetSellPrice(itemLink)
        local count = GetRewardCount(button)
        if unitPrice == nil or count == nil then
            -- Wait for every option's data so an incomplete scan cannot mark the wrong winner.
            dataPending = true
        else
            local totalValue = unitPrice * count
            if totalValue > highestTotalValue then
                highestTotalValue = totalValue
                highestButton = button
            end
        end
    end

    if dataPending then
        if retryCount < MAX_RETRIES then
            retryCount = retryCount + 1
            _G.C_Timer.After(RETRY_DELAY, ScanRewards)
            scanPending = true
        else
            retryCount = 0
        end
        return
    end

    retryCount = 0
    if highestButton and highestTotalValue > 0 then
        ShowMarker(highestButton)
    end
end

local function ScheduleScan()
    -- Coalesce reward-list, quest-event, and dialog updates into one next-frame scan.
    if scanPending then return end
    scanPending = true
    _G.C_Timer.After(0, ScanRewards)
end

local function HookRewardList(list)
    if not list or list.__lqocHighestSellHooked or not list.SetData then return end
    list.__lqocHighestSellHooked = true
    _G.hooksecurefunc(list, "SetData", function()
        retryCount = 0
        ScheduleScan()
    end)
end

function feature.Initialize()
    if initialized then return true end
    if not _G.LWDialogFrame then return false end

    local lists = GetRewardLists()
    if not lists or #lists == 0 then return false end

    -- The feature is ready only after the choice lists exist; retrying before then installs no hooks.
    initialized = true
    for index = 1, #lists do
        HookRewardList(lists[index])
    end

    local dialog = _G.LWDialogFrame
    dialog:HookScript("OnShow", function()
        retryCount = 0
        ScheduleScan()
    end)
    dialog:HookScript("OnHide", function()
        retryCount = 0
        for _, list in ipairs(GetRewardLists() or {}) do
            for _, button in ipairs(GetButtons({ list })) do
                HideMarker(button)
            end
        end
    end)

    for _, event in ipairs({ "QUEST_DETAIL", "QUEST_COMPLETE", "QUEST_PROGRESS" }) do
        local listener = _G.CreateFrame("Frame")
        listener:RegisterEvent(event)
        listener:SetScript("OnEvent", function()
            retryCount = 0
            ScheduleScan()
        end)
    end

    return true
end

addon.RegisterModule("QoL.HighestSellPrice", feature.Initialize)
