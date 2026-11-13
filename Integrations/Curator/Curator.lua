-- Keeps Curator's fallback gossip panel beside Lorewalker's dialog and suspends HideUI while its tavern windows are open.
-- Curator's inn card and tavern panels already anchor to that panel in sequence.
local _, addon = ...
local compat = addon.Compat or {}
addon.Compat = compat

local positionPending = false
local applyingPosition = false
local hookedPanels = {}
local hookedDialogs = {}
local hookedRows = {}
local hideUIModeActive = false
local hideUIModeAPIUsable
local hideUIDisabledForCurator = false
local hideUIWasActiveForCurator = false
local curatorActionPending = false
local curatorWindowsOpen = false
local restoringUIVisibility = false
local windowCheckPending = false
local curatorActionDeadline = 0
local vignetteWasShown = false
local hookedCuratorWindows = {}
local experienceBarHooked
local eventFrame

local HIDE_UI_MODE = "Lorewalker.HideUI"
local CURATOR_TAVERN_WINDOWS = {
    "CuratorInnCard",
    "CuratorTavernBet",
    "CuratorRumor",
    "CuratorRumorBuy",
}
local ScheduleCuratorWindowCheck
local SchedulePosition

local function IsHideUIActive()
    if hideUIModeActive then return true end
    local uiParent = _G.UIParent
    local worldFrame = _G.WorldFrame
    local dialog = _G.LWDialogFrame
    if not (dialog and dialog.IsShown and dialog:IsShown()) then return false end

    -- Lorewalker can restore UIParent while leaving the world hidden. Treat that partial state as HideUI too.
    local uiParentHidden = uiParent and uiParent.GetAlpha and uiParent:GetAlpha() < 0.99
    local worldHidden = worldFrame and worldFrame.GetAlpha and worldFrame:GetAlpha() < 0.99
    return uiParentHidden or worldHidden
end

local function SetLorewalkerHideUIModeActive(active)
    local uiModeUtil = _G.UIModeUtil
    if hideUIModeAPIUsable == false or not (uiModeUtil and uiModeUtil.SetModeActive) then
        return false
    end

    local ok = pcall(uiModeUtil.SetModeActive, HIDE_UI_MODE, active)
    if ok then
        hideUIModeAPIUsable = true
        return true
    end

    hideUIModeAPIUsable = false
    if active then
        -- A failed push can leave the name in the manager's active stack; try to clear it once.
        pcall(uiModeUtil.SetModeActive, HIDE_UI_MODE, false)
    end
    return false
end

local function KeepUIVisible()
    if restoringUIVisibility then return end
    restoringUIVisibility = true
    SetLorewalkerHideUIModeActive(false)
    if _G.UIParent then
        if _G.UIParent.Show and not _G.UIParent:IsShown() then _G.UIParent:Show() end
        if _G.UIParent.SetAlpha then _G.UIParent:SetAlpha(1) end
    end
    if _G.WorldFrame and _G.WorldFrame.SetAlpha then _G.WorldFrame:SetAlpha(1) end
    hideUIModeActive = false
    restoringUIVisibility = false
end

local function KeepUIHiddenWhileCuratorOpens()
    if restoringUIVisibility then return end
    restoringUIVisibility = true
    if _G.UIParent and _G.UIParent.SetAlpha then _G.UIParent:SetAlpha(0) end
    if _G.WorldFrame and _G.WorldFrame.SetAlpha then _G.WorldFrame:SetAlpha(0) end
    restoringUIVisibility = false
end

local function HideCuratorExperienceBar()
    local bar = _G.LWUIExperienceBar
    if bar and bar.Hide then bar:Hide() end
end

local function HookExperienceBar()
    local bar = _G.LWUIExperienceBar
    if not bar or experienceBarHooked then return end
    experienceBarHooked = bar
    bar:HookScript("OnShow", function(self)
        if curatorActionPending or curatorWindowsOpen then self:Hide() end
    end)
end

local function AnyCuratorTavernWindowOpen()
    local anyOpen = false
    for _, name in ipairs(CURATOR_TAVERN_WINDOWS) do
        local frame = _G[name]
        if frame then
            if not hookedCuratorWindows[frame] then
                hookedCuratorWindows[frame] = true
                frame:HookScript("OnShow", function()
                    if hideUIDisabledForCurator then
                        HideCuratorExperienceBar()
                        ScheduleCuratorWindowCheck()
                    end
                end)
                frame:HookScript("OnHide", function()
                    if hideUIDisabledForCurator then
                        ScheduleCuratorWindowCheck()
                    end
                end)
            end
            if frame.IsShown and frame:IsShown() then anyOpen = true end
        end
    end
    return anyOpen
end

local function RestoreHideUIAfterCuratorWindows()
    local dialog = _G.LWDialogFrame
    local shouldRestore = hideUIWasActiveForCurator
        and dialog and dialog.IsShown and dialog:IsShown()
        and not (_G.InCombatLockdown and _G.InCombatLockdown())

    curatorWindowsOpen = false
    curatorActionPending = false
    hideUIDisabledForCurator = false
    if shouldRestore then
        hideUIModeActive = SetLorewalkerHideUIModeActive(true)
        if _G.UIParent and _G.UIParent.SetAlpha then _G.UIParent:SetAlpha(0) end
        if _G.WorldFrame and _G.WorldFrame.SetAlpha then _G.WorldFrame:SetAlpha(0) end
    end

    local bar = _G.LWUIExperienceBar
    if bar and bar.Update then bar:Update() end

    local vignette = _G.LWVignette
    if vignetteWasShown and shouldRestore and vignette and vignette.FadeIn then
        vignette:FadeIn()
    end
    vignetteWasShown = false
    hideUIWasActiveForCurator = false
end

ScheduleCuratorWindowCheck = function()
    if windowCheckPending then return end
    windowCheckPending = true
    local function Check()
        windowCheckPending = false
        local anyOpen = AnyCuratorTavernWindowOpen()
        if anyOpen then
            curatorActionPending = false
            if not curatorWindowsOpen then
                curatorWindowsOpen = true
                local vignette = _G.LWVignette
                vignetteWasShown = vignette and vignette.IsShown and vignette:IsShown() or false
                if vignetteWasShown and vignette.FadeOut then vignette:FadeOut() end
            end
            KeepUIVisible()
            HookExperienceBar()
            HideCuratorExperienceBar()
        elseif curatorWindowsOpen then
            RestoreHideUIAfterCuratorWindows()
        elseif hideUIDisabledForCurator then
            -- Curator may wait for a server response before creating its lazy tavern frame.
            -- Keep the XP bar suppressed during that gap instead of releasing after one empty scan.
            if curatorActionPending and _G.GetTime and _G.GetTime() < curatorActionDeadline then
                ScheduleCuratorWindowCheck()
            else
                RestoreHideUIAfterCuratorWindows()
            end
        end
    end
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0.1, Check)
    else
        Check()
    end
end

local function OnHideUIModeChanged(mode, active)
    if mode ~= HIDE_UI_MODE then return end
    hideUIModeActive = active == true
    if hideUIDisabledForCurator then
        if curatorWindowsOpen then
            if hideUIModeActive then KeepUIVisible() end
        elseif curatorActionPending and not hideUIModeActive then
            KeepUIHiddenWhileCuratorOpens()
        end
    end
end

local function OnUIParentAlphaChanged(_, alpha)
    if hideUIDisabledForCurator and not restoringUIVisibility then
        if curatorWindowsOpen and alpha < 1 then
            KeepUIVisible()
        elseif curatorActionPending and alpha > 0 then
            KeepUIHiddenWhileCuratorOpens()
        end
        HideCuratorExperienceBar()
    end
end

local function OnWorldFrameAlphaChanged(_, alpha)
    if hideUIDisabledForCurator and not restoringUIVisibility then
        if curatorWindowsOpen and alpha < 1 then
            KeepUIVisible()
        elseif curatorActionPending and alpha > 0 then
            KeepUIHiddenWhileCuratorOpens()
        end
        HideCuratorExperienceBar()
    end
end

local function DisableHideUIForCuratorAction()
    if hideUIDisabledForCurator or not IsHideUIActive()
        or (_G.InCombatLockdown and _G.InCombatLockdown()) then return end

    -- Leave the saved preference intact; hold the visible UI only while Curator's tavern windows are open.
    hideUIWasActiveForCurator = true
    hideUIDisabledForCurator = true
    curatorActionPending = true
    curatorActionDeadline = (_G.GetTime and _G.GetTime() or 0) + 5
    HookExperienceBar()
    KeepUIHiddenWhileCuratorOpens()
    HideCuratorExperienceBar()
    ScheduleCuratorWindowCheck()
end

local function HookCuratorRows(panel)
    for _, row in ipairs(panel.rows or {}) do
        if row and not hookedRows[row] then
            hookedRows[row] = true
            row:HookScript("PreClick", DisableHideUIForCuratorAction)
        end
    end
end

local function LorewalkerDialog()
    local dialog = _G.LWDialogFrame
    if not dialog or not dialog.IsShown or not dialog:IsShown() then return end

    local gossip = dialog.GossipFrame
    if gossip and gossip.IsShown and not gossip:IsShown() then return end
    return dialog
end

local function PositionCuratorPanel()
    local panel = _G.CuratorGossip
    local dialog = LorewalkerDialog()
    local uiParent = _G.UIParent
    if not (panel and panel.IsShown and panel:IsShown() and dialog and uiParent) then return end

    local dialogLeft = dialog.GetLeft and dialog:GetLeft()
    local dialogRight = dialog.GetRight and dialog:GetRight()
    local screenWidth = uiParent.GetWidth and uiParent:GetWidth()
    if not dialogLeft or not dialogRight or not screenWidth then return end
    local preferRight = (screenWidth - dialogRight) >= dialogLeft

    applyingPosition = true
    panel:ClearAllPoints()
    if preferRight then
        panel:SetPoint("TOPLEFT", dialog, "TOPRIGHT", 12, 0)
    else
        panel:SetPoint("TOPRIGHT", dialog, "TOPLEFT", -12, 0)
    end
    applyingPosition = false
end

local function HookCuratorPanel(panel)
    if not panel or hookedPanels[panel] then return end
    hookedPanels[panel] = true
    panel:HookScript("OnShow", function(self)
        -- Curator assigns a temporary point immediately before Show; move it before the next frame is drawn.
        HookCuratorRows(self)
        PositionCuratorPanel()
        SchedulePosition()
    end)
    panel:HookScript("OnSizeChanged", SchedulePosition)
    -- Curator resets this panel's points whenever it refreshes its custom gossip rows.
    _G.hooksecurefunc(panel, "SetPoint", function()
        if applyingPosition then return end
        if panel.IsShown and panel:IsShown() then
            PositionCuratorPanel()
        end
        SchedulePosition()
    end)
end

SchedulePosition = function()
    if positionPending then return end
    positionPending = true

    local function Apply()
        positionPending = false
        local panel = _G.CuratorGossip
        HookCuratorPanel(panel)
        if panel then HookCuratorRows(panel) end
        PositionCuratorPanel()
    end

    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, Apply)
    else
        Apply()
    end
end

local function HookLorewalkerDialog()
    local dialog = _G.LWDialogFrame
    if not dialog or hookedDialogs[dialog] then return end
    hookedDialogs[dialog] = true
    dialog:HookScript("OnShow", SchedulePosition)
    dialog:HookScript("OnSizeChanged", SchedulePosition)
end

local function OnGossipEvent(_, event)
    if event == "GOSSIP_SHOW" then
        HookLorewalkerDialog()
        SchedulePosition()
    end
end

local function OnFrameCreated(_, name)
    if name == "CuratorGossip" then
        HookCuratorPanel(_G.CuratorGossip)
    end
end

function compat.Initialize()
    if eventFrame then return true end
    if not (_G.LWDialogFrame and _G.hooksecurefunc and _G.CreateFrame) then return false end

    if _G.UIModeUtil and _G.UIModeUtil.SetModeActive then
        _G.hooksecurefunc(_G.UIModeUtil, "SetModeActive", OnHideUIModeChanged)
    end
    if _G.UIParent and _G.UIParent.SetAlpha then
        _G.hooksecurefunc(_G.UIParent, "SetAlpha", OnUIParentAlphaChanged)
    end
    if _G.WorldFrame and _G.WorldFrame.SetAlpha then
        _G.hooksecurefunc(_G.WorldFrame, "SetAlpha", OnWorldFrameAlphaChanged)
    end
    -- Curator creates its fallback panel lazily during GOSSIP_SHOW. Hook it before it reaches Show().
    _G.hooksecurefunc("CreateFrame", OnFrameCreated)

    eventFrame = _G.CreateFrame("Frame")
    eventFrame:RegisterEvent("GOSSIP_SHOW")
    eventFrame:SetScript("OnEvent", OnGossipEvent)
    HookLorewalkerDialog()
    return true
end

addon.RegisterModule("Compat.Curator", compat.Initialize)
