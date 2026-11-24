-- Clears stale required-item amounts when Lorewalker's pooled ItemSlot receives false.
-- Lorewalker's current SetAmount treats false as visible but skips SetText, retaining old text.
local _, addon = ...
local feature = addon.RequiredItemAmountFix or {}
addon.RequiredItemAmountFix = feature

local initialized = false

local function ClearStaleAmount(itemSlot)
    local amountText = itemSlot and itemSlot.AmountText
    if not (amountText and amountText.IsShown and amountText:IsShown()) then return end

    if amountText.SetText then amountText:SetText("") end
    amountText:Hide()
end

local function HookItemSlot(itemSlot)
    if not (itemSlot and itemSlot.SetAmount and _G.hooksecurefunc)
        or itemSlot.__lqocRequiredAmountHooked then
        return
    end

    itemSlot.__lqocRequiredAmountHooked = true
    _G.hooksecurefunc(itemSlot, "SetAmount", function(self, amount)
        -- If Lorewalker has already fixed SetAmount, its false case will be hidden here
        -- and this compatibility hook becomes a no-op.
        if amount == false then ClearStaleAmount(self) end
    end)
end

local function RepairVisibleButton(button)
    if not button then return end
    local itemSlot = button.Item
    HookItemSlot(itemSlot)

    local rewardInfo = button.rewardInfo
    local amountText = itemSlot and itemSlot.AmountText
    if rewardInfo and tonumber(rewardInfo.count) == 1
        and amountText and amountText.IsShown and amountText:IsShown() then
        -- Covers a button already pooled before the hook was installed. This also
        -- does nothing after Lorewalker correctly hides the amount for a requirement of 1.
        ClearStaleAmount(itemSlot)
    end
end

local function RefreshRequiredItems(list)
    if not (list and list.GetAllElementsInPoolByType) then return end
    local ok, buttons = pcall(list.GetAllElementsInPoolByType, list, "Default")
    if not ok or type(buttons) ~= "table" then return end

    for index = 1, #buttons do
        local button = buttons[index]
        if button then
            RepairVisibleButton(button)
        end
    end
end

local function GetRequiredItemList()
    local dialog = _G.LWDialogFrame
    local quest = dialog and dialog.QuestFrame
    local group = quest and quest.QuestRequiredItems
    return group and group.RewardListFrame
end

local function HookRequiredItemList(list)
    if not (list and list.SetData and _G.hooksecurefunc)
        or list.__lqocRequiredAmountListHooked then
        return
    end

    list.__lqocRequiredAmountListHooked = true
    _G.hooksecurefunc(list, "SetData", function(self)
        -- SetData updates or creates pooled buttons synchronously. Hook them after
        -- that update so later asynchronous item-data callbacks are covered too.
        RefreshRequiredItems(self)
    end)
end

function feature.Initialize()
    if initialized then return true end
    if not _G.LWDialogFrame or not _G.hooksecurefunc then return false end

    local list = GetRequiredItemList()
    if not list then return false end

    initialized = true
    HookRequiredItemList(list)
    RefreshRequiredItems(list)

    _G.LWDialogFrame:HookScript("OnShow", function()
        RefreshRequiredItems(list)
    end)

    return true
end

addon.RegisterModule("QoL.RequiredItemAmountFix", feature.Initialize)
