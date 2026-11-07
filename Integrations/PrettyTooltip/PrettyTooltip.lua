-- Keeps PrettyTooltip's styled tooltip visible when Lorewalker HideUI reparents native tooltips.
-- Requires Lorewalker and PrettyTooltip; hooks are installed once by Initialize.
local _, addon = ...
local compat = addon.Compat or {}
addon.Compat = compat

local TOOLTIP_NAMES = {
    "GameTooltip",
    "ShoppingTooltip1",
    "ShoppingTooltip2",
    "GarrisonFollowerTooltip",
}

local trackedHosts = {}
local compatibilityActive = false
local restoreCheckPending = false

local function IsLorewalkerTooltipParent(parent)
    return parent ~= nil and parent == _G.LWParent
end

local function AnyTooltipStillUsesLorewalkerParent()
    local lorewalkerParent = _G.LWParent
    if not lorewalkerParent then return false end

    for index = 1, #TOOLTIP_NAMES do
        local tooltip = _G[TOOLTIP_NAMES[index]]
        local ok, parent = pcall(function() return tooltip and tooltip:GetParent() end)
        if ok and parent == lorewalkerParent then return true end
    end
    return false
end

local function IsPrettyTooltipPanel(frame)
    -- PrettyTooltip exposes no host lookup API, so identify its panel by the fields its renderer owns.
    return frame ~= nil
        and frame.measure ~= nil
        and type(frame.pool) == "table"
        and type(frame.texturePool) == "table"
end

local function FindPrettyTooltipHosts()
    local uiParent = _G.UIParent
    if not uiParent then return end

    local ok, hosts = pcall(function() return { uiParent:GetChildren() } end)
    if not ok or type(hosts) ~= "table" then return end

    -- The custom panel is nested under a host frame; track hosts, not the panel child itself.
    for hostIndex = 1, #hosts do
        local host = hosts[hostIndex]
        local readable, isPanelHost = pcall(function()
            if not host or not host.GetChildren then return false end
            local children = { host:GetChildren() }
            for childIndex = 1, #children do
                if IsPrettyTooltipPanel(children[childIndex]) then return true end
            end
            return false
        end)
        if readable and isPanelHost then trackedHosts[host] = true end
    end
end

local function MoveTrackedHosts(parent)
    if not parent then return end
    for host in pairs(trackedHosts) do
        pcall(function()
            if host:GetParent() ~= parent then host:SetParent(parent) end
        end)
    end
end

local function RestoreHostsIfReady()
    restoreCheckPending = false
    -- Keep panels under LWParent until every tooltip has returned to its normal parent.
    if not compatibilityActive or AnyTooltipStillUsesLorewalkerParent() then return end
    MoveTrackedHosts(_G.UIParent)
    compatibilityActive = false
end

local function ScheduleRestoreCheck()
    if restoreCheckPending then return end
    restoreCheckPending = true
    -- Defer until the other tooltip parent changes in this frame have also run.
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, RestoreHostsIfReady)
    else
        RestoreHostsIfReady()
    end
end

local function OnTooltipParentChanged(_, parent)
    if IsLorewalkerTooltipParent(parent) then
        compatibilityActive = true
        FindPrettyTooltipHosts()
        MoveTrackedHosts(_G.LWParent)
    elseif compatibilityActive then
        ScheduleRestoreCheck()
    end
end

local function OnTooltipAlphaChanged(_, alpha)
    if not compatibilityActive or alpha ~= 0 then return end
    FindPrettyTooltipHosts()
    MoveTrackedHosts(_G.LWParent)
end

function compat.Initialize()
    -- PrettyTooltipDB is the load-ready signal; return false until its public API is available.
    if type(_G.PrettyTooltipDB) ~= "table" or type(_G.hooksecurefunc) ~= "function" then return false end
    for index = 1, #TOOLTIP_NAMES do
        local tooltip = _G[TOOLTIP_NAMES[index]]
        if tooltip then
            if tooltip.SetParent then _G.hooksecurefunc(tooltip, "SetParent", OnTooltipParentChanged) end
            if tooltip.SetAlpha then _G.hooksecurefunc(tooltip, "SetAlpha", OnTooltipAlphaChanged) end
        end
    end
    if AnyTooltipStillUsesLorewalkerParent() then
        compatibilityActive = true
        FindPrettyTooltipHosts()
        MoveTrackedHosts(_G.LWParent)
    end
    return true
end

addon.RegisterModule("Compat.PrettyTooltip", compat.Initialize)
