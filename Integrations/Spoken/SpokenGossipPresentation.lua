-- Presents a matching Spoken line in a compact Lorewalker-themed panel after its dialog closes.
-- The real Lorewalker dialog is allowed to close normally; this keeps HideUI and session state intact.
local _, addon = ...
local compat = addon.Compat or {}
addon.Compat = compat

local TICK = 0.05
local CLIP_WAIT = 4
local MISSION_CLOSE_SETTLE_DELAY = 0.35
local CLIP_GAP_GRACE = 0.7
local PAGE_TRANSITION_DELAY = 0.12
local PAGE_FADE_OUT = 0.10
local PAGE_FADE_IN = 0.16
local ARRIVE_TIME = 0.62
local LEAVE_TIME = 0.22
local MISSION_SIZE = { width = 490, height = 410 }
local PLACE_SIZE = { width = 490, height = 510 }
local PANEL_BOTTOM = 150
local PORTRAIT_SIZE = 126
local NPC_PORTRAIT_SIZE = 45
local NPC_PORTRAIT_RING_SIZE = 53
local NPC_HEADER_HEIGHT = 50
local PLACE_SUBTITLE_FONT_SIZE = 12
local PICTURE_HEIGHT = 195
local TEXT_INSET = 22
local TEXT_SIDE_INSET = 34
local PAGE_CONTROL_BROWN = { 0.32, 0.16, 0.07 }
local PAGE_CONTROL_ALPHA = 0.6
local MIN_PAGE_WORDS = 8
local MAX_PAGE_WORDS = 36
local MIN_PAGE_ANCHOR_WORDS = 3
local MIN_PAGE_HEIGHT = 72
local FRAME_BG_INSETS = { 28, 118, 29, 142 }
local FRAME_BG_TEXCOORD = { 0, 366 / 512, 0, 466 / 512 }

local spoken
local spokenAudioChangedHandle
local driver
local panel
local panelReady = false
local savedPanelPosition
local dragHandle
local isDraggingPanel = false
local context
local pendingClose
local activeClip
local motion
local textBox
local scrollContent
local pageIndicator
local previousPageButton
local nextPageButton
local dividerTexture
local portraitViewport
local portraitModel
local portraitRenderer
local portraitTexture
local npcHeader
local npcNameText
local npcPortraitTexture
local npcPortraitMask
local npcPortraitCaptured = false
local npcPortraitRing
local npcPortraitRingCaptured = false
local spokenHeader
local spokenNameText
local spokenPortraitMask
local spokenPortraitRing
local spokenBossFace
local placePicture
local placeMask
local playButton
local skipButton
local tickElapsed = 0
local LayoutBody
local UpdatePageControls
local ApplyTranscriptPage
local ChangePageBy
local transcriptPages
local transcriptBoundaries
local transcriptPage = 1
local transcriptClip
local transcriptText
local transcriptMode
local transcriptHasPicture
local transcriptHasPortrait
local pendingPage
local textFade
local manualPageOverride
local missingClipSince
local ReleasePortrait
local RestoreSpokenWindow
local MaintainSpokenWindowSuppression
local spokenFrameSuppressed = false
local suppressedPlayerFrames = {}
local hookedSpokenFrames = setmetatable({}, { __mode = "k" })

local function IsAddonLoaded(name)
    if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded then
        return _G.C_AddOns.IsAddOnLoaded(name)
    end
    return _G.IsAddOnLoaded and _G.IsAddOnLoaded(name) or false
end

local function SafeText(value)
    if spoken and type(spoken.NotSecret) == "function" then
        local ok, safeValue = pcall(spoken.NotSecret, value)
        if not ok then return nil end
        value = safeValue
    elseif type(_G.issecretvalue) == "function" then
        local ok, secret = pcall(_G.issecretvalue, value)
        if not ok or secret then return nil end
    end
    if type(value) ~= "string" then return nil end
    local ok, empty = pcall(function() return value == "" end)
    if not ok or empty then return nil end
    return value
end

local function PresentationSettings()
    if type(addon.GetSpokenPresentationSettings) == "function" then
        return addon.GetSpokenPresentationSettings()
    end

    local database = _G.LorewalkerQoLDB
    if type(database) ~= "table" then
        database = {}
        _G.LorewalkerQoLDB = database
    end
    addon.db = database
    local settings = database.spokenPresentation
    if type(settings) ~= "table" then
        settings = {}
        database.spokenPresentation = settings
    end
    if type(settings.enabled) ~= "boolean" then settings.enabled = true end
    if type(settings.movementLocked) ~= "boolean" then settings.movementLocked = false end
    return settings
end

local function IsPresentationEnabled()
    return PresentationSettings().enabled
end

local function SavePanelPosition(x, y)
    local screenWidth, screenHeight = _G.UIParent:GetWidth(), _G.UIParent:GetHeight()
    if not (screenWidth and screenHeight and screenWidth > 0 and screenHeight > 0) then return end
    local normalized = { x = x / screenWidth, y = y / screenHeight }
    savedPanelPosition = normalized
    PresentationSettings().position = normalized
end

local function CurrentQuestID()
    if type(_G.GetQuestID) ~= "function" then return nil end
    local ok, id = pcall(function()
        local value = _G.GetQuestID()
        if type(value) == "number" and value > 0 then return value end
    end)
    if ok then return id end
end

local function ContextFor(dialog)
    local quest = dialog.QuestFrame
    local gossip = dialog.GossipFrame
    local isQuest = quest and quest.IsShown and quest:IsShown()
    local title
    if isQuest and quest.QuestTitleContainer and quest.QuestTitleContainer.TitleText then
        title = SafeText(quest.QuestTitleContainer.TitleText:GetText())
    end

    local x, y = dialog:GetCenter()
    local scale = dialog:GetEffectiveScale() / (_G.UIParent:GetEffectiveScale() or 1)
    return {
        kind = isQuest and "quest" or gossip and gossip:IsShown() and "gossip" or nil,
        questID = CurrentQuestID(),
        questTitle = title,
        npcName = SafeText(dialog.TitleContainer and dialog.TitleContainer.Name
            and dialog.TitleContainer.Name:GetText()),
        centerX = x and x * scale,
        centerY = y and y * scale,
        width = dialog:GetWidth() * scale,
        height = dialog:GetHeight() * scale,
        at = _G.GetTime and _G.GetTime() or 0,
    }
end

local function IsMissionClip(clip, forContext)
    if not (clip and clip.source and clip.source.key == "quests" and clip.questID
        and forContext and forContext.kind ~= nil) then
        return false
    end
    if forContext.questID then return clip.questID == forContext.questID end
    local title = SafeText(clip.present and clip.present.label)
    if title and title == forContext.questTitle then return true end
    local speaker = SafeText(clip.present and clip.present.header)
    local closedAt = forContext.closedAt
    local matchExpiresAt = forContext.matchExpiresAt or (closedAt and closedAt + CLIP_WAIT)
    return type(speaker) == "string" and speaker ~= "" and speaker == forContext.npcName
        and matchExpiresAt and (_G.GetTime and _G.GetTime() or 0) <= matchExpiresAt
end

local function IsExternalMissionClip(clip)
    if not (clip and clip.source and clip.source.key == "quests" and clip.questID
        and IsAddonLoaded("Spoken_Quests")) then
        return false
    end
    local origin = clip.origin
    if origin == "Azeroth's Compendium" then return true end
    if type(origin) == "string" and origin:find("objective tracker's Play button", 1, true) then
        return true
    end

    -- QuestMapFrame's details Play button shares the quest-log origin in Spoken_Quests.
    -- Limit that shared label to the map window so the detached quest-log path keeps its behavior.
    local map = _G.WorldMapFrame
    return origin == "the quest log's Play button" and map and map.IsShown and map:IsShown() or false
end

local function IsPlaceClip(clip, forContext)
    return clip and clip.source and clip.source.key == "places"
        and IsAddonLoaded("Spoken_Places")
end

local function IsReadableClip(clip)
    return clip and clip.source and clip.source.key == "readables"
        and IsAddonLoaded("Spoken_Readables")
end

local function IsBossClip(clip)
    return clip and clip.source and clip.source.key == "bosses"
        and IsAddonLoaded("Spoken_Bosses")
end

local function IsSpokenPortraitClip(clip)
    return IsReadableClip(clip) or IsBossClip(clip)
end

local function IsGossipClip(clip, forContext)
    if not (clip and clip.source and clip.source.key == "gossip" and forContext
        and forContext.kind and type(forContext.npcName) == "string" and forContext.npcName ~= "") then
        return false
    end
    local speaker = SafeText(clip.present and clip.present.header)
    local matchExpiresAt = forContext.matchExpiresAt
        or (forContext.closedAt and forContext.closedAt + CLIP_WAIT)
    return type(speaker) == "string" and speaker == forContext.npcName
        and matchExpiresAt and (_G.GetTime and _G.GetTime() or 0) <= matchExpiresAt
end

local function IsDialogClip(clip, forContext)
    return IsMissionClip(clip, forContext) or IsGossipClip(clip, forContext)
end

local function IsWorldMapOpen()
    local map = _G.WorldMapFrame
    return map and map.IsShown and map:IsShown() or false
end

local function IsLorewalkerDialogOpen()
    local dialog = _G.LWDialogFrame
    if not (dialog and dialog.IsShown and dialog:IsShown()) then return false end

    local gossip = dialog.GossipFrame
    local quest = dialog.QuestFrame
    return gossip and gossip.IsShown and gossip:IsShown()
        or quest and quest.IsShown and quest:IsShown() or false
end

local function IsEligibleClip(clip, forContext)
    if not spoken or type(spoken.GetPlayerStyle) ~= "function"
        or spoken:GetPlayerStyle() ~= "classic" then
        return false
    end
    return IsMissionClip(clip, forContext) or IsExternalMissionClip(clip)
        or IsPlaceClip(clip, forContext)
        or IsGossipClip(clip, forContext) or IsSpokenPortraitClip(clip)
end

local function ShouldKeepSpokenWindowSuppressed()
    if not IsPresentationEnabled() or not spoken or type(spoken.GetPlayerStyle) ~= "function"
        or spoken:GetPlayerStyle() ~= "classic" then
        return false
    end
    if IsLorewalkerDialogOpen() then return true end
    if panel and panel.IsShown and panel:IsShown() and activeClip
        and (IsMissionClip(activeClip, context) or IsExternalMissionClip(activeClip)
            or IsPlaceClip(activeClip, context)
            or IsGossipClip(activeClip, context) or IsSpokenPortraitClip(activeClip)) then
        return true
    end

    local current = type(spoken.GetCurrent) == "function" and spoken:GetCurrent()
    if IsExternalMissionClip(current) or IsPlaceClip(current, context) or IsGossipClip(current, context)
        or IsSpokenPortraitClip(current) then return true end
    local forContext = pendingClose and pendingClose.context or context
    return IsDialogClip(current, forContext)
end

local function CopyTexture(source, target)
    if not source or not target then return false end
    if source.GetAtlas and target.SetAtlas then
        local ok, atlas = pcall(source.GetAtlas, source)
        if ok and type(atlas) == "string" and atlas ~= "" then
            target:SetAtlas(atlas)
            return true
        end
    end
    if source.GetTexture then
        local ok, texture = pcall(source.GetTexture, source)
        if ok and texture then
            target:SetTexture(texture)
            if source.GetTexCoord then
                local left, right, top, bottom = source:GetTexCoord()
                target:SetTexCoord(left, right, top, bottom)
            end
            return true
        end
    end
    return false
end

local function GetTextureObject(textureFrame)
    if textureFrame and type(textureFrame.GetTextureObject) == "function" then
        local ok, result = pcall(textureFrame.GetTextureObject, textureFrame)
        if ok then return result end
    end
    return textureFrame
end

local function CopyTextureCoordinates(source, target, fallback)
    if source and type(source.GetTexCoord) == "function" then
        local ok, a, b, c, d, e, f, g, h = pcall(source.GetTexCoord, source)
        if ok and h ~= nil then
            local minX = math.min(a, c, e, g)
            local maxX = math.max(a, c, e, g)
            local minY = math.min(b, d, f, h)
            local maxY = math.max(b, d, f, h)
            if maxX - minX > 0.001 and maxY - minY > 0.001 then
                target:SetTexCoord(a, b, c, d, e, f, g, h)
                return true
            end
        elseif ok and d ~= nil and math.abs(a - b) > 0.001 and math.abs(c - d) > 0.001 then
            target:SetTexCoord(a, b, c, d)
            return true
        end
    end
    target:SetTexCoord(fallback[1], fallback[2], fallback[3], fallback[4])
    return false
end

local function CopyVertexColor(source, target)
    if source and type(source.GetVertexColor) == "function" then
        local ok, r, g, b, a = pcall(source.GetVertexColor, source)
        if ok then
            target:SetVertexColor(r or 1, g or 1, b or 1, a or 1)
            return
        end
    end
    target:SetVertexColor(1, 1, 1, 1)
end

local function SetTextureFromSource(target, source, fallbackPath, fallbackCoords)
    local textureObject = GetTextureObject(source)
    local texturePath
    if textureObject and type(textureObject.GetTexture) == "function" then
        local ok, result = pcall(textureObject.GetTexture, textureObject)
        if ok then texturePath = result end
    end
    target:SetTexture(texturePath or fallbackPath)
    CopyTextureCoordinates(textureObject, target, fallbackCoords)
    CopyVertexColor(textureObject, target)
    return textureObject
end

local function ApplyLorewalkerBackgroundSlicing(target)
    if target.SetTextureSliceMargins and target.SetTextureSliceMode
        and _G.Enum and _G.Enum.UITextureSliceMode then
        target:SetTextureSliceMargins(FRAME_BG_INSETS[1], FRAME_BG_INSETS[3],
            FRAME_BG_INSETS[2], FRAME_BG_INSETS[4])
        target:SetTextureSliceMode(_G.Enum.UITextureSliceMode.Stretched)
    end
end

local function SetLorewalkerBackground(dialog)
    local content = dialog and dialog.ContentFrame
    local underlay = content and content.UnderlayTexture
    local background = content and content.BackgroundTexture

    local frameTexture = SetTextureFromSource(panel.backdrop, underlay,
        [[Interface\AddOns\Lorewalker\Art\Dialog\DialogFrame\QuestBackgroundFrame]], FRAME_BG_TEXCOORD)
    ApplyLorewalkerBackgroundSlicing(panel.backdrop)
    -- UI Kit's frame atlas occupies only the upper-left part of its 512px source.
    -- Copy all eight corner coordinates; reducing them to four collapses the x range.
    CopyTextureCoordinates(frameTexture, panel.backdrop, FRAME_BG_TEXCOORD)

    local paperTexture = SetTextureFromSource(panel.paper, background,
        [[Interface\AddOns\Lorewalker\Art\Dialog\DialogFrame\QuestBackgroundClassic]], FRAME_BG_TEXCOORD)
    ApplyLorewalkerBackgroundSlicing(panel.paper)
    CopyTextureCoordinates(paperTexture, panel.paper, FRAME_BG_TEXCOORD)
end

local function CopyFont(source, target, fallback)
    if source and source.GetFontObject and target.SetFontObject then
        local font = source:GetFontObject()
        if font then
            target:SetFontObject(font)
            if source.GetTextColor then target:SetTextColor(source:GetTextColor()) end
            return
        end
    end
    if fallback then target:SetFontObject(fallback) end
end

local function SetFontSize(fontString, size)
    if not (fontString and fontString.GetFont and fontString.SetFont) then return end
    local face, _, flags = fontString:GetFont()
    if face then fontString:SetFont(face, size, flags or "") end
end

local function MakeText(parent, fontObject, justify)
    local text = parent:CreateFontString(nil, "OVERLAY")
    text:SetFontObject(fontObject or _G.GameFontHighlight)
    text:SetJustifyH(justify or "LEFT")
    text:SetJustifyV("TOP")
    text:SetWordWrap(true)
    text:SetNonSpaceWrap(true)
    return text
end

local function SetPageButtonVisual(button, direction, pushed)
    local icon = button.icon
    icon:SetTexture([[Interface\AddOns\Lorewalker\Art\Dialog\Shared\StepperButton]])
    if direction == "left" then
        icon:SetTexCoord(pushed and 0.5 or 0, pushed and 1 or 0.5, 0, 0.5)
    else
        icon:SetTexCoord(pushed and 0.5 or 0, pushed and 1 or 0.5, 0.5, 1)
    end
    icon:SetVertexColor(PAGE_CONTROL_BROWN[1], PAGE_CONTROL_BROWN[2], PAGE_CONTROL_BROWN[3])
    icon:SetAlpha(button:IsEnabled() and PAGE_CONTROL_ALPHA or 0.3)
end

local function StartPanelDrag()
    if PresentationSettings().movementLocked or motion or isDraggingPanel or not panel then return end
    isDraggingPanel = true
    panel:StartMoving()
end

local function StopPanelDrag()
    if not isDraggingPanel or not panel then return end
    panel:StopMovingOrSizing()
    isDraggingPanel = false
    local x, y = panel:GetCenter()
    if x and y then SavePanelPosition(x, y) end
end

local function MakePanelDraggable(frame)
    if not frame then return end
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", StartPanelDrag)
    frame:SetScript("OnDragStop", StopPanelDrag)
end

local function BuildPanel()
    if panelReady then return true end
    if panel then return false end
    panel = _G.CreateFrame("Frame", nil, _G.UIParent, "BackdropTemplate")
    panel:SetFrameStrata("DIALOG")
    panel:SetFrameLevel(80)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    MakePanelDraggable(panel)
    if panel.SetIgnoreParentAlpha then panel:SetIgnoreParentAlpha(true) end
    panel:SetSize(MISSION_SIZE.width, MISSION_SIZE.height)
    panel:Hide()

    local backdrop = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
    backdrop:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    backdrop:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    panel.backdrop = backdrop

    local paper = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
    paper:SetAllPoints(backdrop)
    panel.paper = paper

    panel.title = MakeText(panel, _G.GameFontNormalLarge)
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 30, -20)
    panel.title:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -108, -20)
    panel.title:SetHeight(28)

    panel.subtitle = MakeText(panel, _G.GameFontNormalSmall)
    panel.subtitle:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -2)
    panel.subtitle:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -108, -44)
    panel.subtitle:SetHeight(18)

    dividerTexture = panel:CreateTexture(nil, "ARTWORK")
    dividerTexture:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -76)
    dividerTexture:SetHeight(11)
    local dividerPath = [[Interface\AddOns\Spoken_Places\Textures\Art\spellbook-divider]]
    local usePlacesDivider = IsAddonLoaded("Spoken_Places")
    local dividerAtlas = not usePlacesDivider and _G.C_Texture and _G.C_Texture.GetAtlasInfo
        and _G.C_Texture.GetAtlasInfo("spellbook-divider")
    local dividerRule = usePlacesDivider and { width = 657, left = 0, right = 0.641602, top = 0, bottom = 0.6875 }
        or dividerAtlas and {
            width = dividerAtlas.width or 657,
            left = dividerAtlas.leftTexCoord or 0, right = dividerAtlas.rightTexCoord or 1,
            top = dividerAtlas.topTexCoord or 0, bottom = dividerAtlas.bottomTexCoord or 1,
        }
    if usePlacesDivider then
        dividerTexture:SetTexture(dividerPath)
        dividerTexture:SetTexCoord(0, 0.641602, 0, 0.6875)
    elseif dividerAtlas and (dividerAtlas.file or dividerAtlas.filename) then
        dividerTexture:SetTexture(dividerAtlas.file or dividerAtlas.filename)
        dividerTexture:SetTexCoord(dividerAtlas.leftTexCoord or 0, dividerAtlas.rightTexCoord or 1,
            dividerAtlas.topTexCoord or 0, dividerAtlas.bottomTexCoord or 1)
    else
        dividerTexture:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -20, -76)
        dividerTexture:SetHeight(1)
        dividerTexture:SetColorTexture(0.34, 0.19, 0.07, 0.55)
    end
    panel.divider = dividerTexture
    panel.dividerUsesRule = dividerRule and true or false
    local function FitDivider()
        if dividerRule then
            local sourceWidth = dividerRule.width
            local width = math.min(sourceWidth, math.max(1, panel:GetWidth() - 40))
            dividerTexture:SetWidth(width)
            dividerTexture:SetTexCoord(dividerRule.left,
                dividerRule.left + (dividerRule.right - dividerRule.left) * width / sourceWidth,
                dividerRule.top, dividerRule.bottom)
        end
    end
    panel:HookScript("OnSizeChanged", FitDivider)
    FitDivider()

    placePicture = panel:CreateTexture(nil, "ARTWORK")
    placePicture:SetPoint("TOPLEFT", panel, "TOPLEFT", TEXT_INSET, -87)
    placePicture:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -TEXT_INSET, -87)
    placePicture:SetHeight(PICTURE_HEIGHT)
    placePicture:Hide()

    placeMask = panel:CreateMaskTexture(nil, "ARTWORK")
    placeMask:SetAllPoints(placePicture)
    placeMask:Hide()

    portraitTexture = panel:CreateTexture(nil, "ARTWORK")
    portraitTexture:SetSize(PORTRAIT_SIZE, PORTRAIT_SIZE)
    portraitTexture:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -91)
    portraitTexture:Hide()

    portraitViewport = _G.CreateFrame("Frame", nil, panel)
    portraitViewport:SetSize(PORTRAIT_SIZE, PORTRAIT_SIZE)
    portraitViewport:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -91)
    portraitViewport:SetFrameLevel(panel:GetFrameLevel() + 3)
    portraitViewport:Hide()

    npcHeader = _G.CreateFrame("Frame", nil, panel)
    npcHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 30, -96)
    npcHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -30, -96)
    npcHeader:SetHeight(NPC_HEADER_HEIGHT)
    npcHeader:SetFrameLevel(panel:GetFrameLevel() + 2)

    npcPortraitTexture = npcHeader:CreateTexture(nil, "OVERLAY")
    npcPortraitTexture:SetSize(NPC_PORTRAIT_SIZE, NPC_PORTRAIT_SIZE)
    npcPortraitTexture:SetPoint("CENTER", npcHeader, "LEFT", NPC_PORTRAIT_SIZE / 2, 0)
    npcPortraitMask = npcHeader:CreateMaskTexture(nil, "ARTWORK")
    npcPortraitMask:SetAllPoints(npcPortraitTexture)
    npcPortraitMask:SetTexture([[Interface\AddOns\Lorewalker\Art\Dialog\DialogFrame\Mask-UnitPortrait]])
    npcPortraitTexture:AddMaskTexture(npcPortraitMask)

    npcPortraitRing = npcHeader:CreateTexture(nil, "ARTWORK")
    npcPortraitRing:SetSize(NPC_PORTRAIT_RING_SIZE, NPC_PORTRAIT_RING_SIZE)
    npcPortraitRing:SetPoint("CENTER", npcPortraitTexture, "CENTER")

    npcNameText = MakeText(npcHeader, _G.GameFontNormal)
    npcNameText:SetPoint("LEFT", npcHeader, "LEFT", NPC_PORTRAIT_SIZE + 10, 0)
    npcNameText:SetPoint("RIGHT", npcHeader, "RIGHT", -62, 0)
    npcNameText:SetHeight(NPC_HEADER_HEIGHT)
    npcNameText:SetJustifyV("MIDDLE")
    npcHeader:Hide()

    spokenHeader = _G.CreateFrame("Frame", nil, panel)
    spokenHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 30, -96)
    spokenHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -30, -96)
    spokenHeader:SetHeight(NPC_HEADER_HEIGHT)
    spokenHeader:SetFrameLevel(panel:GetFrameLevel() + 2)

    spokenPortraitRing = spokenHeader:CreateTexture(nil, "OVERLAY")
    spokenPortraitRing:SetSize(NPC_PORTRAIT_RING_SIZE, NPC_PORTRAIT_RING_SIZE)
    spokenPortraitRing:SetPoint("CENTER", spokenHeader, "LEFT", NPC_PORTRAIT_SIZE / 2, 0)
    spokenPortraitRing:SetTexture([[Interface\AddOns\Lorewalker\Art\Dialog\DialogFrame\DialogFrame]])
    spokenPortraitRing:SetTexCoord(6 / 512, 82 / 512, 6 / 512, 82 / 512)

    spokenPortraitMask = spokenHeader:CreateMaskTexture(nil, "ARTWORK")
    spokenPortraitMask:SetSize(NPC_PORTRAIT_SIZE, NPC_PORTRAIT_SIZE)
    spokenPortraitMask:SetPoint("CENTER", spokenHeader, "LEFT", NPC_PORTRAIT_SIZE / 2, 0)
    spokenPortraitMask:SetTexture([[Interface\AddOns\Lorewalker\Art\Dialog\DialogFrame\Mask-UnitPortrait]])

    spokenNameText = MakeText(spokenHeader, _G.GameFontNormal)
    spokenNameText:SetPoint("LEFT", spokenHeader, "LEFT", NPC_PORTRAIT_SIZE + 10, 0)
    spokenNameText:SetPoint("RIGHT", spokenHeader, "RIGHT", -62, 0)
    spokenNameText:SetHeight(NPC_HEADER_HEIGHT)
    spokenNameText:SetJustifyV("MIDDLE")
    spokenHeader:Hide()

    if spoken and type(spoken.CreateSpeakerFace) == "function" then
        local ok, face = pcall(spoken.CreateSpeakerFace, spoken, spokenHeader, NPC_PORTRAIT_RING_SIZE)
        if ok and face then
            spokenBossFace = face
            face:SetPoint("CENTER", spokenHeader, "LEFT", NPC_PORTRAIT_SIZE / 2, 0)
            face:SetFrameLevel(panel:GetFrameLevel() + 3)
            face:Hide()
        end
    end

    portraitViewport:ClearAllPoints()
    portraitViewport:SetSize(NPC_PORTRAIT_SIZE, NPC_PORTRAIT_SIZE)
    portraitViewport:SetPoint("CENTER", spokenHeader, "LEFT", NPC_PORTRAIT_SIZE / 2, 0)
    portraitViewport:SetFrameLevel(panel:GetFrameLevel() + 3)

    local scroll = _G.CreateFrame("ScrollFrame", nil, panel)
    panel.scroll = scroll
    MakePanelDraggable(scroll)
    scrollContent = _G.CreateFrame("Frame", nil, scroll)
    panel.scrollContent = scrollContent
    textBox = MakeText(scrollContent, _G.GameFontHighlight)
    textBox:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 0, 0)
    textBox:SetWidth(440)
    scrollContent:SetSize(440, 100)
    scroll:SetScrollChild(scrollContent)

    previousPageButton = _G.CreateFrame("Button", nil, panel)
    previousPageButton:SetSize(20, 20)
    previousPageButton:SetPoint("CENTER", panel, "BOTTOM", -34, 32)
    previousPageButton.icon = previousPageButton:CreateTexture(nil, "ARTWORK")
    previousPageButton.icon:SetAllPoints()
    previousPageButton:SetScript("OnMouseDown", function()
        if previousPageButton:IsEnabled() then SetPageButtonVisual(previousPageButton, "left", true) end
    end)
    previousPageButton:SetScript("OnMouseUp", function() SetPageButtonVisual(previousPageButton, "left", false) end)
    previousPageButton:SetScript("OnLeave", function() SetPageButtonVisual(previousPageButton, "left", false) end)
    previousPageButton:SetScript("OnClick", function() ChangePageBy(-1) end)
    previousPageButton:Hide()

    pageIndicator = MakeText(panel, _G.GameFontNormalSmall)
    pageIndicator:SetPoint("CENTER", panel, "BOTTOM", 0, 32)
    pageIndicator:SetSize(36, 20)
    pageIndicator:SetFontObject(_G.GameFontNormal)
    pageIndicator:SetJustifyH("CENTER")
    pageIndicator:SetJustifyV("MIDDLE")
    pageIndicator:SetTextColor(PAGE_CONTROL_BROWN[1], PAGE_CONTROL_BROWN[2], PAGE_CONTROL_BROWN[3])
    pageIndicator:SetAlpha(PAGE_CONTROL_ALPHA)
    pageIndicator:Hide()

    nextPageButton = _G.CreateFrame("Button", nil, panel)
    nextPageButton:SetSize(20, 20)
    nextPageButton:SetPoint("CENTER", panel, "BOTTOM", 34, 32)
    nextPageButton.icon = nextPageButton:CreateTexture(nil, "ARTWORK")
    nextPageButton.icon:SetAllPoints()
    nextPageButton:SetScript("OnMouseDown", function()
        if nextPageButton:IsEnabled() then SetPageButtonVisual(nextPageButton, "right", true) end
    end)
    nextPageButton:SetScript("OnMouseUp", function() SetPageButtonVisual(nextPageButton, "right", false) end)
    nextPageButton:SetScript("OnLeave", function() SetPageButtonVisual(nextPageButton, "right", false) end)
    nextPageButton:SetScript("OnClick", function() ChangePageBy(1) end)
    nextPageButton:Hide()

    playButton = spoken and spoken.CreateRoundButton and spoken:CreateRoundButton(panel, "play")
    skipButton = spoken and spoken.CreateRoundButton and spoken:CreateRoundButton(panel, "skip")
    if playButton then
        playButton:SetSize(24, 24)
        playButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -48, -15)
        playButton:SetScript("OnClick", function()
            if activeClip and type(spoken.TogglePause) == "function"
                and spoken:GetCurrent() == activeClip then
                spoken:TogglePause()
            end
        end)
    end
    if skipButton then
        skipButton:SetSize(24, 24)
        skipButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -17, -15)
        skipButton:SetScript("OnClick", function()
            if activeClip and type(spoken.Skip) == "function"
                and spoken:GetCurrent() == activeClip then
                spoken:Skip()
            end
        end)
    end

    dragHandle = _G.CreateFrame("Frame", nil, panel)
    dragHandle:SetPoint("TOPLEFT", panel, "TOPLEFT", 10, -8)
    dragHandle:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -88, -8)
    dragHandle:SetHeight(56)
    dragHandle:SetFrameLevel(panel:GetFrameLevel() + 6)
    MakePanelDraggable(dragHandle)

    panel:SetScript("OnUpdate", function(_, elapsed)
        if textFade then
            textFade.elapsed = textFade.elapsed + elapsed
            local duration = textFade.phase == "out" and PAGE_FADE_OUT or PAGE_FADE_IN
            local progress = math.min(1, textFade.elapsed / duration)
            if textFade.phase == "out" then
                textBox:SetAlpha((textFade.startAlpha or 1) * (1 - progress))
                if progress >= 1 then
                    local target = textFade.target
                    ApplyTranscriptPage(target)
                    textBox:SetAlpha(0)
                    textFade = { phase = "in", elapsed = 0 }
                end
            else
                textBox:SetAlpha(progress)
                if progress >= 1 then
                    textBox:SetAlpha(1)
                    textFade = nil
                end
            end
        end
        if motion then
            motion.elapsed = motion.elapsed + elapsed
            local duration = motion.kind == "in" and ARRIVE_TIME or LEAVE_TIME
            local t = math.min(1, motion.elapsed / duration)
            local eased = t * t * (3 - 2 * t)
            local x = motion.fromX + (motion.toX - motion.fromX) * eased
            local y = motion.fromY + (motion.toY - motion.fromY) * eased
            local scale = motion.fromScale + (motion.toScale - motion.fromScale) * eased
            panel:ClearAllPoints()
            panel:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", x, y)
            panel:SetScale(scale)
            panel:SetAlpha(motion.kind == "in" and t or 1 - t)
            if t >= 1 then
                local leaving = motion.kind == "out"
                motion = nil
                if leaving then
                    panel:Hide()
                    panel:SetAlpha(1)
                    panel:SetScale(1)
                    if ReleasePortrait then ReleasePortrait() end
                    RestoreSpokenWindow()
                end
            end
        end
    end)
    panelReady = true
    return true
end

local function CreatePanel()
    if panelReady then return true end
    local ok, created = pcall(BuildPanel)
    if ok and created then return true end

    if not ok and _G.geterrorhandler then _G.geterrorhandler()(tostring(created)) end
    if panel and panel.Hide then pcall(panel.Hide, panel) end
    panel = nil
    panelReady = false
    motion, activeClip = nil, nil
    textBox, scrollContent, portraitViewport = nil, nil, nil
    npcHeader, npcNameText, npcPortraitTexture, npcPortraitMask, npcPortraitRing = nil, nil, nil, nil, nil
    spokenHeader, spokenNameText, spokenPortraitMask, spokenPortraitRing, spokenBossFace = nil, nil, nil, nil, nil
    portraitModel, portraitRenderer, portraitTexture = nil, nil, nil
    placePicture, placeMask, playButton, skipButton = nil, nil, nil, nil
    dragHandle, isDraggingPanel = nil, false
    return false
end

local function SetBackdropFromLorewalker(dialog)
    SetLorewalkerBackground(dialog)

    local titleText = dialog and dialog.QuestFrame and dialog.QuestFrame.QuestTitleContainer
        and dialog.QuestFrame.QuestTitleContainer.TitleText
    CopyFont(titleText, panel.title, _G.GameFontNormalLarge)
    local body = dialog and dialog.GossipFrame and dialog.GossipFrame.GossipText
    CopyFont(body, panel.subtitle, _G.GameFontNormalSmall)
    SetFontSize(panel.subtitle, PLACE_SUBTITLE_FONT_SIZE)
    CopyFont(body, textBox, _G.GameFontHighlight)
end

local function HideSpokenWindow()
    if not IsPresentationEnabled() then return end
    if type(spoken.GetPlayerFrame) ~= "function" then return end
    local frame = spoken:GetPlayerFrame()
    if not (frame and frame.IsShown and frame.Hide) then return end
    spokenFrameSuppressed = true
    if not suppressedPlayerFrames[frame] then
        suppressedPlayerFrames[frame] = { wasShown = frame:IsShown() }
        if frame.HookScript and not hookedSpokenFrames[frame] then
            frame:HookScript("OnShow", function(self)
                if spokenFrameSuppressed then
                    local state = suppressedPlayerFrames[self]
                    if state then state.wasShown = true end
                    self:Hide()
                end
            end)
            hookedSpokenFrames[frame] = true
        end
    end
    if frame:IsShown() then frame:Hide() end
end

RestoreSpokenWindow = function()
    if spokenFrameSuppressed and ShouldKeepSpokenWindowSuppressed() then
        HideSpokenWindow()
        return
    end
    local currentFrame = spoken and type(spoken.GetPlayerFrame) == "function" and spoken:GetPlayerFrame()
    local current = spoken and type(spoken.GetCurrent) == "function" and spoken:GetCurrent()
    local canShow = spoken and type(spoken.GetPlayerStyle) == "function"
        and spoken:GetPlayerStyle() == "classic" and current ~= nil
    if canShow and current.source and type(spoken.ShowsNarratorFor) == "function" then
        canShow = spoken:ShowsNarratorFor(current.source.key)
    end
    spokenFrameSuppressed = false
    for frame, state in pairs(suppressedPlayerFrames) do
        if frame == currentFrame and state.wasShown and canShow then
            if frame.SetAlpha then frame:SetAlpha(1) end
            frame:Show()
        end
    end
    suppressedPlayerFrames = {}
end

MaintainSpokenWindowSuppression = function()
    if not spokenFrameSuppressed then return end
    if not ShouldKeepSpokenWindowSuppressed() then
        RestoreSpokenWindow()
        return
    end
    HideSpokenWindow()
    for frame in pairs(suppressedPlayerFrames) do
        if frame.IsShown and frame:IsShown() then frame:Hide() end
    end
end

local function ConfigurePortrait(clip)
    if ReleasePortrait then ReleasePortrait() end
    portraitTexture:Hide()
    local spec = clip and clip.present and clip.present.portrait
    if not spec then return false end

    if spec.kind == "model" and tonumber(spec.creatureID) then
        local getRenderer = spoken and spoken.GetPortraitRenderer
        local renderer = type(getRenderer) == "function" and spoken:GetPortraitRenderer("model")
        if renderer and type(renderer.Acquire) == "function" and type(renderer.Update) == "function"
            and type(renderer.Release) == "function" then
            local acquired, model = pcall(renderer.Acquire, portraitViewport, clip)
            if acquired and model then
                local updated, hasModel = pcall(renderer.Update, model, clip, spec)
                if updated then
                    portraitRenderer, portraitModel = renderer, model
                    portraitViewport:Show()
                    local fallback = spec.fallback
                    if not hasModel and fallback and fallback.kind == "texture" and fallback.texture then
                        portraitTexture:SetTexture(fallback.texture)
                        local coords = fallback.texCoord
                        if type(coords) == "table" then
                            portraitTexture:SetTexCoord(coords[1] or 0, coords[2] or 1, coords[3] or 0, coords[4] or 1)
                        else
                            portraitTexture:SetTexCoord(0, 1, 0, 1)
                        end
                        portraitTexture:Show()
                    end
                    return true
                end
                pcall(renderer.Release, model)
            end
        end
        spec = spec.fallback or {}
    end
    if spec.kind == "texture" and spec.texture then
        portraitTexture:SetTexture(spec.texture)
        local coords = spec.texCoord
        if type(coords) == "table" then
            portraitTexture:SetTexCoord(coords[1] or 0, coords[2] or 1, coords[3] or 0, coords[4] or 1)
        else
            portraitTexture:SetTexCoord(0, 1, 0, 1)
        end
        portraitTexture:Show()
        return true
    end
    return false
end

local function CaptureNpcPortraitRing(dialog, final)
    if not npcPortraitRing or npcPortraitRingCaptured then return npcPortraitRingCaptured end
    local portrait = dialog and dialog.TitleContainer and dialog.TitleContainer.Portrait
    local source
    if portrait and type(portrait.GetTextureFrame) == "function" then
        local ok, textureFrame = pcall(portrait.GetTextureFrame, portrait)
        if ok then source = GetTextureObject(textureFrame) end
    end
    if source and CopyTexture(source, npcPortraitRing) then
        CopyTextureCoordinates(source, npcPortraitRing, { 0, 1, 0, 1 })
        CopyVertexColor(source, npcPortraitRing)
        npcPortraitRingCaptured = true
        return true
    end
    if not final then return false end

    local underlay = dialog and dialog.ContentFrame and dialog.ContentFrame.UnderlayTexture
    local underlayObject = GetTextureObject(underlay)
    local underlayPath = underlayObject and underlayObject.GetTexture and underlayObject:GetTexture()
    local isForever = type(underlayPath) == "string" and underlayPath:find("Camelot", 1, true) ~= nil
    local base = [[Interface\AddOns\Lorewalker\Art\Dialog\DialogFrame\DialogFrame]]
    npcPortraitRing:SetTexture(isForever and (base .. "-Camelot") or base)
    npcPortraitRing:SetTexCoord(6 / 512, 82 / 512, 6 / 512, 82 / 512)
    npcPortraitRingCaptured = true
    return true
end

local function CaptureNpcPortrait(dialog, final)
    if not npcPortraitTexture then return false end
    CaptureNpcPortraitRing(dialog, final)
    if npcPortraitCaptured then return true end
    local unit
    if _G.UnitExists and _G.UnitExists("questnpc") then
        unit = "questnpc"
    elseif _G.UnitExists and _G.UnitExists("npc") then
        unit = "npc"
    end

    local isGameObject = unit and _G.UnitIsGameObject
        and (_G.UnitIsGameObject(unit) or _G.UnitIsGameObject("npc") or _G.UnitIsGameObject("questnpc"))
    if unit and not isGameObject and type(_G.SetPortraitTexture) == "function" then
        local ok = pcall(_G.SetPortraitTexture, npcPortraitTexture, unit)
        if ok then
            npcPortraitCaptured = true
            return true
        end
    end

    if not final then return false end
    -- Lorewalker uses the quest book icon for game objects and missing unit portraits.
    npcPortraitTexture:SetTexture([[Interface\QuestFrame\UI-QuestLog-BookIcon]])
    npcPortraitTexture:SetTexCoord(0, 1, 0, 1)
    npcPortraitCaptured = true
    return true
end

local function ConfigureNpcHeader(dialog, clip)
    local title = dialog and dialog.TitleContainer
    CaptureNpcPortrait(dialog, true)

    local name = title and title.Name
    local text = SafeText(name and name.GetText and name:GetText())
        or SafeText(clip and clip.present and clip.present.header)
        or SafeText(context and context.npcName) or ""
    npcNameText:SetText(text)
    CopyFont(textBox, npcNameText, _G.GameFontHighlight)
    npcHeader:SetShown(true)
    return true
end

local function ConfigureSpokenPortrait(clip, portraitOverride)
    local present = clip and clip.present or {}
    local spec = portraitOverride
    if portraitOverride == nil then spec = present.portrait end
    if not spec or spec.kind == "none" then return false end

    local function RenderSpec(portraitSpec)
        if not portraitSpec or not portraitSpec.kind or not spoken
            or type(spoken.GetPortraitRenderer) ~= "function" then return false end
        local renderer = spoken:GetPortraitRenderer(portraitSpec.kind)
        if not (renderer and type(renderer.Acquire) == "function"
            and type(renderer.Update) == "function" and type(renderer.Release) == "function") then
            return false
        end
        local acquired, portrait = pcall(renderer.Acquire, portraitViewport, clip)
        if not (acquired and portrait) then return false end
        local updated, hasPortrait = pcall(renderer.Update, portrait, clip, portraitSpec)
        if not (updated and hasPortrait) then
            pcall(renderer.Release, portrait)
            return false
        end

        portraitRenderer, portraitModel = renderer, portrait
        if portraitSpec.kind == "texture" and portrait.AddMaskTexture and spokenPortraitMask then
            pcall(portrait.AddMaskTexture, portrait, spokenPortraitMask)
        end
        portraitViewport:Show()
        spokenPortraitRing:Show()
        return true
    end

    if RenderSpec(spec) then return true end
    if spec.kind == "model" and RenderSpec(spec.fallback) then return true end

    if present.bullet and spoken and type(spoken.GetBullet) == "function" then
        local ok, bullet = pcall(spoken.GetBullet, spoken, present.bullet)
        if ok and type(bullet) == "table" and bullet.texture then
            return RenderSpec({ kind = "texture", texture = bullet.texture })
        end
    end
    return false
end

local function ConfigureSpokenHeader(clip, label, portraitOverride)
    npcHeader:Hide()
    spokenPortraitRing:Hide()
    if spokenBossFace then spokenBossFace:Hide() end
    local text = type(label) == "string" and label or ""
    spokenNameText:SetText(text)
    CopyFont(textBox, spokenNameText, _G.GameFontHighlight)
    local hasPortrait = ConfigureSpokenPortrait(clip, portraitOverride)
    spokenHeader:SetShown(hasPortrait or text ~= "")
    return hasPortrait or text ~= ""
end

local function ConfigureBossHeader(clip, label)
    npcHeader:Hide()
    spokenPortraitRing:Hide()
    spokenNameText:SetText(type(label) == "string" and label or "")
    CopyFont(textBox, spokenNameText, _G.GameFontHighlight)
    if not spokenBossFace or type(spokenBossFace.SetSpeaker) ~= "function" then
        local present = clip and clip.present or {}
        local icon = present.bullet and spoken and type(spoken.GetBullet) == "function"
            and spoken:GetBullet(present.bullet)
        local fallback = icon and icon.texture and { kind = "texture", texture = icon.texture }
        return ConfigureSpokenHeader(clip, "", fallback)
    end

    local bossAddon = _G.SpokenBossesAddon
    local ok, speaker
    if bossAddon and type(bossAddon.Portrait) == "function" and clip.mapID and clip.bossKey then
        ok, speaker = pcall(bossAddon.Portrait, bossAddon, clip.mapID, clip.bossKey)
    end
    if not (ok and type(speaker) == "table") then
        local portrait = clip and clip.present and clip.present.portrait
        if portrait and portrait.kind == "model" then
            speaker = {
                creatureID = portrait.creatureID,
                displayID = portrait.displayID,
                bullet = clip.present.bullet,
            }
        end
    end

    local present = clip and clip.present or {}
    local bullet
    if present.bullet and spoken and type(spoken.GetBullet) == "function" then
        local gotBullet, value = pcall(spoken.GetBullet, spoken, present.bullet)
        if gotBullet then bullet = value end
    end
    if type(speaker) ~= "table" or (not speaker.creatureID and not speaker.objectOrItem) then
        speaker = { objectOrItem = true, icon = bullet and bullet.texture, bullet = present.bullet }
    end

    local setOk = pcall(spokenBossFace.SetSpeaker, spokenBossFace, speaker)
    if not setOk then
        spokenBossFace:Hide()
        local fallback = bullet and bullet.texture
            and { kind = "texture", texture = bullet.texture }
        return ConfigureSpokenHeader(clip, "", fallback)
    end

    -- The Compendium header uses the static creature portrait. If Spoken could not draw that
    -- still, use the boss bullet instead of leaving its generic book/model fallback visible.
    if speaker.creatureID and not (spokenBossFace.still and spokenBossFace.still:IsShown()) then
        spokenBossFace:SetSpeaker({
            objectOrItem = true,
            icon = bullet and bullet.texture,
            bullet = present.bullet,
        })
    end

    spokenBossFace:Show()
    spokenHeader:SetShown(true)
    return true
end

local function ConfigureExternalMissionHeader(clip, label)
    npcHeader:Hide()
    spokenPortraitRing:Hide()
    spokenNameText:SetText(type(label) == "string" and label or "")
    CopyFont(textBox, spokenNameText, _G.GameFontHighlight)

    if not spokenBossFace or type(spokenBossFace.SetSpeaker) ~= "function" then
        return ConfigureSpokenHeader(clip, label)
    end

    local present = clip and clip.present or {}
    local portrait = present.portrait or {}
    local speaker = { bullet = present.bullet }
    if portrait.kind == "model" then
        speaker.creatureID = portrait.creatureID
        speaker.displayID = portrait.displayID
    elseif portrait.kind == "texture" then
        speaker.objectOrItem = true
        speaker.icon = portrait.texture
        speaker.iconCrop = portrait.texCoord
    end

    local ok = pcall(spokenBossFace.SetSpeaker, spokenBossFace, speaker)
    if not ok then
        spokenBossFace:Hide()
        return ConfigureSpokenHeader(clip, label)
    end

    spokenBossFace:Show()
    spokenHeader:SetShown(true)
    return true
end

local function HideNpcHeader()
    if npcHeader then npcHeader:Hide() end
end

ReleasePortrait = function()
    if portraitRenderer and portraitModel then
        pcall(portraitRenderer.Release, portraitModel)
    end
    portraitRenderer, portraitModel = nil, nil
    if portraitViewport then portraitViewport:Hide() end
end

local function ConfigurePlacePicture(clip)
    local picture = clip and clip.present and clip.present.picture
    placePicture:RemoveMaskTexture(placeMask)
    placePicture:Hide()
    placeMask:Hide()
    if type(picture) ~= "table" or not picture.file then return false end
    placePicture:SetTexture(picture.file)
    if picture.mask then
        placeMask:SetTexture(picture.mask)
        placeMask:Show()
        placePicture:AddMaskTexture(placeMask)
    end
    placePicture:Show()
    return true
end

local function Trim(text)
    return (text or ""):gsub("^%s*(.-)%s*$", "%1")
end

local function CaptionWordCount(text)
    if spoken and type(spoken.SplitCaption) == "function" then
        local ok, words = pcall(spoken.SplitCaption, spoken, text)
        if ok and type(words) == "table" then return #words end
    end
    local count = 0
    for _ in (text or ""):gmatch("%S+") do count = count + 1 end
    return count
end

local function AppendBoundedPages(segment, pages)
    local ok, words
    if spoken and type(spoken.SplitCaption) == "function" then
        ok, words = pcall(spoken.SplitCaption, spoken, segment)
    end
    if not (ok and type(words) == "table" and #words > MAX_PAGE_WORDS) then
        pages[#pages + 1] = segment
        return
    end

    local startWord = 1
    while startWord <= #words do
        local endWord = math.min(#words, startWord + MAX_PAGE_WORDS - 1)
        if endWord < #words then
            for index = endWord, startWord + MIN_PAGE_WORDS, -1 do
                if (words[index].text or ""):match("[,;:]$") then
                    endWord = index
                    break
                end
            end
        end
        local first = words[startWord].first
        local last = words[endWord].last
        local page = first and last and segment:sub(first, last) or nil
        if not page or page == "" then
            pages[#pages + 1] = segment
            return
        end
        pages[#pages + 1] = Trim(page)
        startWord = endWord + 1
    end
end

local function MergePagesWithoutAnchor(pages)
    local page = 1
    while #pages > 1 and page <= #pages do
        if CaptionWordCount(pages[page]) < MIN_PAGE_ANCHOR_WORDS then
            if page < #pages then
                pages[page + 1] = Trim(pages[page] .. " " .. pages[page + 1])
                table.remove(pages, page)
            else
                pages[page - 1] = Trim(pages[page - 1] .. " " .. pages[page])
                table.remove(pages, page)
                page = page - 1
            end
        else
            page = page + 1
        end
    end
    return pages
end

local function SplitTranscriptPages(text)
    if type(text) ~= "string" or text == "" then return { text or "" } end
    if not (spoken and type(spoken.SplitCaption) == "function"
        and type(spoken.WordMarks) == "function" and type(spoken.GetCaption) == "function") then
        return { text }
    end
    local chunks = {}
    for chunk in text:gmatch("[^%.,!?;:\r\n]+[%.,!?;:]*[\r\n]*") do
        chunk = Trim(chunk)
        if chunk ~= "" then chunks[#chunks + 1] = chunk end
    end
    if #chunks < 2 then
        local pages = {}
        AppendBoundedPages(text, pages)
        MergePagesWithoutAnchor(pages)
        return #pages > 1 and pages or { text }
    end

    local pages, combined = {}, ""
    for _, chunk in ipairs(chunks) do
        combined = combined == "" and chunk or (combined .. " " .. chunk)
        if CaptionWordCount(combined) >= MIN_PAGE_WORDS then
            AppendBoundedPages(combined, pages)
            combined = ""
        end
    end
    if combined ~= "" then
        if #pages > 0 and CaptionWordCount(combined) < MIN_PAGE_WORDS then
            if CaptionWordCount(pages[#pages]) + CaptionWordCount(combined) <= MAX_PAGE_WORDS then
                pages[#pages] = pages[#pages] .. " " .. combined
            else
                AppendBoundedPages(combined, pages)
            end
        else
            AppendBoundedPages(combined, pages)
        end
    end
    MergePagesWithoutAnchor(pages)
    return #pages > 1 and pages or { text }
end

local function SplitMissionTranscriptPages(text)
    if type(text) ~= "string" or text == "" then return { text or "" } end
    local normalized = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    local pages = {}
    local startAt, index = 1, 1
    while index <= #normalized do
        local character = normalized:sub(index, index)
        local boundary = character == "\n"
        local endAt = index - 1
        local nextAt = index + 1

        if character == "." then
            local previousCharacter = normalized:sub(index - 1, index - 1)
            local nextCharacter = normalized:sub(index + 1, index + 1)
            local partOfRepeatedDots = previousCharacter == "." or nextCharacter == "."
            if not partOfRepeatedDots and (nextCharacter == "" or nextCharacter:match("%s")) then
                boundary = true
                endAt = index
            end
        end

        if boundary then
            local part = Trim(normalized:sub(startAt, endAt))
            if part ~= "" then pages[#pages + 1] = part end
            startAt = nextAt
        end
        index = index + 1
    end
    local remainder = Trim(normalized:sub(startAt))
    if remainder ~= "" then pages[#pages + 1] = remainder end
    return #pages > 1 and pages or { text }
end

local function BuildTranscriptBoundaries(pages, captionWords)
    if not (spoken and type(spoken.WordMarks) == "function") then return nil end
    local ok, marks = pcall(spoken.WordMarks, spoken)
    if not (ok and type(marks) == "table" and type(marks.Key) == "function") then return nil end

    local captionKeys = {}
    for index, word in ipairs(captionWords or {}) do
        local key = marks.Key(word.text)
        if key then captionKeys[#captionKeys + 1] = { key = key, wordIndex = index } end
    end

    local boundaries, previousEnd = {}, 0
    for page = 1, #pages - 1 do
        local splitOK, words = pcall(spoken.SplitCaption, spoken, pages[page])
        if not (splitOK and type(words) == "table") then return nil end
        local keys = {}
        for _, word in ipairs(words) do
            local key = marks.Key(word.text)
            if key then keys[#keys + 1] = key end
        end
        if #keys < MIN_PAGE_ANCHOR_WORDS then return nil end

        local endIndex
        for anchorLength = MIN_PAGE_ANCHOR_WORDS, math.min(8, #keys) do
            local count, foundEnd = 0, nil
            for start = 1, #captionKeys - anchorLength + 1 do
                local matches = true
                for offset = 1, anchorLength do
                    if captionKeys[start + offset - 1].key ~= keys[#keys - anchorLength + offset] then
                        matches = false
                        break
                    end
                end
                local candidateEnd = matches and captionKeys[start + anchorLength - 1].wordIndex
                if matches and candidateEnd > previousEnd then
                    count = count + 1
                    foundEnd = candidateEnd
                    if count > 1 then break end
                end
            end
            if count == 1 then
                endIndex = foundEnd
                break
            end
        end
        if not endIndex then return nil end
        boundaries[page] = endIndex
        previousEnd = endIndex
    end
    return boundaries
end

local function SetTranscriptPage(page)
    if not (transcriptPages and transcriptPages[page] and page ~= transcriptPage) then return end
    pendingPage = nil
    if transcriptPage == 0 or not (panel and panel.IsShown and panel:IsShown()) then
        transcriptPage = page
        textBox:SetText(transcriptPages[page])
        textBox:SetAlpha(1)
        textFade = nil
        panel.scroll:SetVerticalScroll(0)
        LayoutBody(transcriptMode, transcriptHasPicture, transcriptHasPortrait)
        UpdatePageControls()
        return
    end
    if textFade and textFade.phase == "out" then
        textFade.target = page
        return
    end
    textFade = { phase = "out", elapsed = 0, target = page, startAlpha = textBox:GetAlpha() }
end

ApplyTranscriptPage = function(page)
    transcriptPage = page
    textBox:SetText(transcriptPages[page])
    panel.scroll:SetVerticalScroll(0)
    LayoutBody(transcriptMode, transcriptHasPicture, transcriptHasPortrait)
    UpdatePageControls()
end

UpdatePageControls = function()
    local count = transcriptPages and #transcriptPages or 0
    local shown = count > 1
    if pageIndicator then
        pageIndicator:SetText(shown and tostring(transcriptPage) or "")
        pageIndicator:SetShown(shown)
    end
    if previousPageButton then
        previousPageButton:SetShown(shown)
        local enabled = shown and transcriptPage > 1
        previousPageButton:SetEnabled(enabled)
        previousPageButton.icon:SetAlpha(enabled and PAGE_CONTROL_ALPHA or 0.3)
        if enabled then SetPageButtonVisual(previousPageButton, "left", false) end
    end
    if nextPageButton then
        nextPageButton:SetShown(shown)
        local enabled = shown and transcriptPage < count
        nextPageButton:SetEnabled(enabled)
        nextPageButton.icon:SetAlpha(enabled and PAGE_CONTROL_ALPHA or 0.3)
        if enabled then SetPageButtonVisual(nextPageButton, "right", false) end
    end
end

ChangePageBy = function(offset)
    if not (transcriptPages and #transcriptPages > 1) then return end
    local current = textFade and textFade.phase == "out" and textFade.target or transcriptPage
    local target = math.max(1, math.min(#transcriptPages, current + offset))
    if target == transcriptPage then return end
    manualPageOverride = true
    SetTranscriptPage(target)
end

local function UpdateTranscriptPaging()
    if not (transcriptPages and #transcriptPages > 1 and transcriptClip == activeClip) then return end
    if textFade then return end
    if not (spoken and type(spoken.GetCaption) == "function") then return end
    local ok, caption = pcall(spoken.GetCaption, spoken)
    if not (ok and caption and caption.clip == transcriptClip and caption.speaking
        and caption.activeWord and type(caption.words) == "table") then
        return
    end

    if manualPageOverride then return end
    if transcriptBoundaries == false then return end
    if not transcriptBoundaries then
        transcriptBoundaries = BuildTranscriptBoundaries(transcriptPages, caption.words) or false
        if transcriptBoundaries == false then
            -- Keep manual page navigation available when word matching is ambiguous.
            UpdatePageControls()
            return
        end
    end

    local target = 1
    for page = 1, #transcriptBoundaries do
        if caption.activeWord > transcriptBoundaries[page] then
            target = page + 1
        else
            break
        end
    end
    if target == transcriptPage then
        pendingPage = nil
        return
    end
    if transcriptPage == 0 then
        SetTranscriptPage(target)
        return
    end
    local now = _G.GetTime and _G.GetTime() or 0
    if not pendingPage or pendingPage.target ~= target then
        pendingPage = { target = target, since = now }
        return
    end
    if now - pendingPage.since >= PAGE_TRANSITION_DELAY then SetTranscriptPage(target) end
end

LayoutBody = function(mode, hasPicture, hasPortrait)
    local width = panel:GetWidth() - TEXT_SIDE_INSET * 2
    local top
    if mode == "place" then
        if hasPicture then
            top = 95 + PICTURE_HEIGHT + 16
        else
            top = 95
        end
    else
        top = hasPortrait and (96 + NPC_HEADER_HEIGHT + 16) or 95
    end

    textBox:ClearAllPoints()
    textBox:SetPoint("TOPLEFT", scrollContent, "TOPLEFT", 0, 0)
    width = math.max(100, width)
    textBox:SetWidth(width)
    local textHeight = math.max(MIN_PAGE_HEIGHT, textBox:GetStringHeight() or MIN_PAGE_HEIGHT)
    textBox:SetHeight(textHeight)

    local maxHeight = mode == "place" and PLACE_SIZE.height or MISSION_SIZE.height
    local footerHeight = transcriptPages and #transcriptPages > 1 and 34 or 18
    local visibleTextHeight = math.min(math.max(MIN_PAGE_HEIGHT, textHeight), maxHeight - top - footerHeight)
    panel:SetHeight(top + visibleTextHeight + footerHeight)
    UpdatePageControls()

    panel.scroll:ClearAllPoints()
    panel.scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", TEXT_SIDE_INSET, -top)
    panel.scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -TEXT_SIDE_INSET, footerHeight - 2)
    scrollContent:SetSize(width, math.max(textHeight, panel.scroll:GetHeight() or 0))
end

local function RenderClip(clip, sourceDialog)
    if not CreatePanel() then return false end
    activeClip = clip
    SetBackdropFromLorewalker(sourceDialog)
    local present = clip.present or {}
    local sourceKey = clip.source and clip.source.key
    local isPlace = sourceKey == "places"
    local isReadable = sourceKey == "readables"
    local isBoss = sourceKey == "bosses"
    local isExternalMission = IsExternalMissionClip(clip)
    local useSpokenPortrait = isReadable or isBoss or isExternalMission
    local mode = isPlace and "place" or "quest"
    local mainTitle, subTitle, headerLabel

    if isPlace then
        mainTitle = present.label or present.header or clip.title or clip.name or ""
        if present.header and present.header ~= mainTitle then
            subTitle = "Ubicación: " .. present.header
        end
    elseif isReadable then
        mainTitle = present.header or present.label or clip.title or clip.name or ""
        headerLabel = present.label ~= mainTitle and present.label or ""
    elseif isBoss then
        mainTitle = present.header or clip.title or clip.name or ""
        subTitle = ""
        headerLabel = present.label or ""
    else
        mainTitle = present.label or context and context.questTitle or clip.title or clip.name or ""
        subTitle = ""
        headerLabel = present.header or context and context.npcName or ""
    end

    panel.title:SetText(mainTitle)
    panel.subtitle:SetText(subTitle)
    panel.subtitle:SetShown(subTitle ~= "")
    panel.title:ClearAllPoints()
    local titleY = isPlace and -20 or -24
    panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 30, titleY)
    panel.title:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -108, titleY)

    local dividerY = subTitle ~= "" and -76 or -60
    panel.divider:ClearAllPoints()
    panel.divider:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, dividerY)
    if not panel.dividerUsesRule then
        panel.divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -20, dividerY)
    end

    local hasPicture, hasNpcHeader
    if isPlace then
        hasPicture = ConfigurePlacePicture(clip)
        ReleasePortrait()
        portraitTexture:Hide()
        HideNpcHeader()
        spokenHeader:Hide()
        panel:SetSize(PLACE_SIZE.width, hasPicture and PLACE_SIZE.height
            or PLACE_SIZE.height - PICTURE_HEIGHT - 16)
        if playButton then
            playButton:ClearAllPoints()
            playButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -48, -15)
        end
        if skipButton then
            skipButton:ClearAllPoints()
            skipButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -17, -15)
        end
    else
        ReleasePortrait()
        portraitTexture:Hide()
        placePicture:RemoveMaskTexture(placeMask)
        placePicture:Hide()
        placeMask:Hide()
        if useSpokenPortrait then
            if isBoss then
                hasNpcHeader = ConfigureBossHeader(clip, headerLabel)
            elseif isExternalMission then
                hasNpcHeader = ConfigureExternalMissionHeader(clip, headerLabel)
            else
                hasNpcHeader = ConfigureSpokenHeader(clip, headerLabel)
            end
        else
            spokenHeader:Hide()
            hasNpcHeader = ConfigureNpcHeader(sourceDialog, clip)
        end
        if playButton then
            playButton:ClearAllPoints()
            playButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -48, -15)
        end
        if skipButton then
            skipButton:ClearAllPoints()
            skipButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -17, -15)
        end
        panel:SetSize(MISSION_SIZE.width, MISSION_SIZE.height)
    end

    local transcript = present.transcript or clip.text or ""
    transcriptClip = clip
    transcriptText = transcript
    transcriptPages = isPlace and SplitTranscriptPages(transcript) or SplitMissionTranscriptPages(transcript)
    transcriptBoundaries = nil
    transcriptPage = 1
    pendingPage = nil
    textFade = nil
    manualPageOverride = false
    textBox:SetAlpha(1)
    transcriptMode = mode
    transcriptHasPicture = hasPicture
    transcriptHasPortrait = hasNpcHeader
    textBox:SetText(transcriptPages[1] or transcript)
    LayoutBody(mode, hasPicture, hasNpcHeader)
    if playButton then playButton:Show() end
    if skipButton then skipButton:Show() end
    return true
end

local function FinalPosition()
    local screenWidth = _G.UIParent:GetWidth()
    local screenHeight = _G.UIParent:GetHeight()
    local width, height = panel:GetWidth(), panel:GetHeight()
    local x, y
    local position = savedPanelPosition or PresentationSettings().position
    local hasSavedPosition = type(position) == "table"
        and type(position.x) == "number" and type(position.y) == "number"
        and position.x >= 0 and position.x <= 1 and position.y >= 0 and position.y <= 1
    if hasSavedPosition then
        x, y = position.x * screenWidth, position.y * screenHeight
    else
        savedPanelPosition = nil
        PresentationSettings().position = nil
        x = screenWidth / 2
        y = math.min(screenHeight - height / 2 - 24, height / 2 + PANEL_BOTTOM)
    end

    local minX, maxX = width / 2, screenWidth - width / 2
    local minY, maxY = height / 2, screenHeight - height / 2
    if maxX >= minX then x = math.max(minX, math.min(maxX, x)) else x = screenWidth / 2 end
    if maxY >= minY then y = math.max(minY, math.min(maxY, y)) else y = screenHeight / 2 end
    if hasSavedPosition then SavePanelPosition(x, y) end
    return x, y
end

local function BeginMotion(kind, fromX, fromY, fromScale, toX, toY, toScale)
    motion = { kind = kind, elapsed = 0, fromX = fromX, fromY = fromY, fromScale = fromScale,
        toX = toX, toY = toY, toScale = toScale }
end

local function ShowClip(clip, forContext, animateFromDialog, deferDisplay)
    if not IsEligibleClip(clip, forContext) then return false end
    context = forContext
    local ok, rendered = pcall(RenderClip, clip, _G.LWDialogFrame)
    if not (ok and rendered) then
        if not ok and _G.geterrorhandler then _G.geterrorhandler()(tostring(rendered)) end
        return false
    end

    local startX, startY
    if animateFromDialog and forContext then
        startX, startY = forContext.centerX, forContext.centerY
    end
    if not startX or not startY then startX, startY = FinalPosition() end
    local finalX, finalY = FinalPosition()
    if deferDisplay then
        panel:ClearAllPoints()
        panel:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", finalX, finalY)
        panel:SetScale(1)
        panel:SetAlpha(1)
        panel:Hide()
        HideSpokenWindow()
        missingClipSince = nil
        pendingClose = nil
        return true
    end
    local startScale = 1
    if animateFromDialog and forContext and forContext.width then
        startScale = math.max(0.25, math.min(2, forContext.width / panel:GetWidth()))
    end
    panel:ClearAllPoints()
    panel:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", startX, startY)
    panel:SetScale(startScale)
    panel:SetAlpha(animateFromDialog and 0 or 1)
    panel:Show()
    HideSpokenWindow()
    missingClipSince = nil
    if animateFromDialog then
        BeginMotion("in", startX, startY, startScale, finalX, finalY, 1)
    else
        panel:ClearAllPoints()
        panel:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", finalX, finalY)
        panel:SetScale(1)
        motion = nil
    end
    pendingClose = nil
    return true
end

local function HidePlaceForMap()
    if textFade then
        if textFade.phase == "out" and textFade.target then ApplyTranscriptPage(textFade.target) end
        textFade = nil
        if textBox then textBox:SetAlpha(1) end
    end
    motion = nil
    if panel then
        panel:Hide()
        panel:SetAlpha(1)
        panel:SetScale(1)
    end
    manualPageOverride = false
end

local function RevealPreparedPlace()
    if not (panel and activeClip and IsPlaceClip(activeClip)) then return false end
    local x, y = FinalPosition()
    panel:ClearAllPoints()
    panel:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", x, y)
    panel:SetScale(1)
    panel:SetAlpha(1)
    panel:Show()
    motion = nil
    HideSpokenWindow()
    return true
end

local function BeginHide()
    if not (panel and panel:IsShown()) then
        activeClip = nil
        missingClipSince = nil
        RestoreSpokenWindow()
        return
    end
    if motion and motion.kind == "out" then return end
    local x, y = panel:GetCenter()
    local scale = panel:GetScale() or 1
    local fromX, fromY = x or 0, y or 0
    BeginMotion("out", fromX, fromY, scale, fromX, fromY - 18, math.max(0.72, scale * 0.92))
    activeClip = nil
    missingClipSince = nil
end

local function CurrentCandidate()
    if not spoken or type(spoken.GetCurrent) ~= "function" then return nil end
    return spoken:GetCurrent()
end

local function FindQueuedDialogClip(forContext)
    if not (spoken and type(spoken.GetQueue) == "function") then return nil end
    local queue = spoken:GetQueue()
    if type(queue) ~= "table" then return nil end
    for _, clip in ipairs(queue) do
        if IsDialogClip(clip, forContext) then return clip end
    end
end

local function OnSpokenAudioChanged()
    if not IsPresentationEnabled() then return end
    local pending = pendingClose
    if pending then
        local current = CurrentCandidate()
        if IsDialogClip(current, pending.context)
            and (not pending.matchingClip or current == pending.matchingClip) then
            pending.matchingClip = current
            HideSpokenWindow()
            return
        end
    end

    -- Spoken's own player update can show the native frame again, so reapply active
    -- suppression after that update completes.
    if spokenFrameSuppressed then MaintainSpokenWindowSuppression() end
end

local function OnDialogHidden(dialog)
    if not IsPresentationEnabled() then return end
    CaptureNpcPortrait(dialog, true)
    if not context then context = ContextFor(dialog) end
    if not context or not context.kind then return end
    local rect = ContextFor(dialog)
    context.centerX, context.centerY, context.width, context.height = rect.centerX, rect.centerY, rect.width, rect.height
    context.closedAt = _G.GetTime and _G.GetTime() or 0
    context.matchExpiresAt = context.closedAt + CLIP_WAIT
    pendingClose = {
        context = context,
        showAfter = context.closedAt + MISSION_CLOSE_SETTLE_DELAY,
        untilTime = context.closedAt + CLIP_WAIT,
    }
    pendingClose.matchingClip = FindQueuedDialogClip(context)
    local current = CurrentCandidate()
    if IsDialogClip(current, context)
        and (not pendingClose.matchingClip or current == pendingClose.matchingClip) then
        pendingClose.matchingClip = current
        HideSpokenWindow()
    end
end

local function SnapshotDialog(dialog)
    if dialog and dialog.IsShown and dialog:IsShown() then
        CaptureNpcPortrait(dialog)
        local fresh = ContextFor(dialog)
        if fresh.kind then context = fresh end
    elseif context and context.closedAt then
        -- Keep the last visible page snapshot until a clip is matched or the short close window expires.
        local now = _G.GetTime and _G.GetTime() or 0
        local dialogPanelOwnsContext = panel and panel.IsShown and panel:IsShown()
            and activeClip and activeClip.source
            and (activeClip.source.key == "quests" or activeClip.source.key == "gossip")
        if dialogPanelOwnsContext then
            context.matchExpiresAt = now + CLIP_WAIT
        end
        if now > (context.matchExpiresAt or (context.closedAt + CLIP_WAIT)) then context = nil end
    end
end

local function RefreshPresentation()
    if not panel or not activeClip then return end
    local clip = CurrentCandidate()
    if clip == activeClip and IsEligibleClip(clip, context) then
        missingClipSince = nil
        UpdateTranscriptPaging()
        local nowPlaying = type(spoken.GetNowPlaying) == "function" and spoken:GetNowPlaying() or nil
        if playButton and playButton.SetPlaying then
            local paused = type(spoken.IsPaused) == "function" and spoken:IsPaused()
            playButton:SetPlaying(nowPlaying == clip and not paused)
        end
        return
    end
    if clip and IsEligibleClip(clip, context) then
        local ok, rendered = pcall(RenderClip, clip, _G.LWDialogFrame)
        if ok and rendered then
            activeClip = clip
            missingClipSince = nil
            UpdateTranscriptPaging()
            return
        end
        if not ok and _G.geterrorhandler then _G.geterrorhandler()(tostring(rendered)) end
    end
    local now = _G.GetTime and _G.GetTime() or 0
    if not missingClipSince then
        missingClipSince = now
    elseif now - missingClipSince >= CLIP_GAP_GRACE then
        BeginHide()
    end
end

local function OnUpdate(_, delta)
    if not IsPresentationEnabled() then return end
    tickElapsed = tickElapsed + delta
    if tickElapsed < TICK then return end
    tickElapsed = 0

    MaintainSpokenWindowSuppression()
    local dialog = _G.LWDialogFrame
    SnapshotDialog(dialog)
    local dialogOpen = dialog and dialog.IsShown and dialog:IsShown()
    if panel and panel:IsShown() then
        if IsPlaceClip(activeClip) and IsWorldMapOpen() then
            HidePlaceForMap()
            RefreshPresentation()
            return
        end
        if dialogOpen then
            -- Places narration can start while Lorewalker is still showing its gossip,
            -- so let that clip remain visible. Once a quest clip takes over, close the
            -- Places panel and wait for Lorewalker's quest dialog to close normally.
            local current = CurrentCandidate()
            if not IsPlaceClip(activeClip) or not IsPlaceClip(current) then
                BeginHide()
                pendingClose = nil
                return
            end
        end
        if not spoken or type(spoken.GetPlayerStyle) ~= "function"
            or spoken:GetPlayerStyle() ~= "classic" then
            BeginHide()
        else
            local current = CurrentCandidate()
            if not activeClip and motion and motion.kind == "out"
                and IsEligibleClip(current, context) then
                local ok, rendered = pcall(RenderClip, current, dialog)
                if ok and rendered then
                    activeClip = current
                    missingClipSince = nil
                    motion = nil
                    panel:SetAlpha(1)
                    panel:SetScale(1)
                    local x, y = FinalPosition()
                    panel:ClearAllPoints()
                    panel:SetPoint("CENTER", _G.UIParent, "BOTTOMLEFT", x, y)
                    UpdateTranscriptPaging()
                    return
                end
            end
            RefreshPresentation()
        end
        return
    end

    local current = CurrentCandidate()
    if IsPlaceClip(activeClip) then
        if current == activeClip and IsEligibleClip(current, context) then
            RefreshPresentation()
            if not IsWorldMapOpen() then RevealPreparedPlace() end
            return
        end
        RefreshPresentation()
        return
    end
    if IsPlaceClip(current) and IsEligibleClip(current, context) then
        if IsWorldMapOpen() then
            if ShowClip(current, dialogOpen and context or nil, false, true) then
                HidePlaceForMap()
                UpdateTranscriptPaging()
            end
        else
            ShowClip(current, dialogOpen and context or nil, dialogOpen and context ~= nil)
        end
        return
    end
    if dialogOpen then
        pendingClose = nil
        if IsLorewalkerDialogOpen()
            and spoken and type(spoken.GetPlayerStyle) == "function"
            and spoken:GetPlayerStyle() == "classic" then
            HideSpokenWindow()
        elseif not (panel and panel.IsShown and panel:IsShown()) then
            RestoreSpokenWindow()
        end
        return
    end

    if (IsSpokenPortraitClip(current) or IsExternalMissionClip(current))
        and IsEligibleClip(current, context) then
        ShowClip(current, nil, false)
        return
    end

    local pending = pendingClose
    if not pending then return end
    local now = _G.GetTime and _G.GetTime() or 0
    local clip = CurrentCandidate()
    if IsDialogClip(clip, pending.context)
        and (not pending.matchingClip or clip == pending.matchingClip) then
        pending.matchingClip = clip
        HideSpokenWindow()
    end
    -- Lorewalker may briefly hide its dialog while replacing Gossip with a quest view.
    -- Let its OnShow hook cancel this close before the QoL panel takes over.
    if now < (pending.showAfter or 0) then return end
    if IsDialogClip(clip, pending.context)
        and (not pending.matchingClip or clip == pending.matchingClip) then
        ShowClip(clip, pending.context, true)
        return
    end
    local queued = FindQueuedDialogClip(pending.context)
    if queued then
        pending.matchingClip = queued
        return
    end
    pending.matchingClip = nil
    if now >= pending.untilTime then
        pendingClose = nil
        context = nil
        if not (panel and panel.IsShown and panel:IsShown()) then RestoreSpokenWindow() end
    end
end

function compat.InitializeSpokenGossipPresentation()
    if not IsPresentationEnabled() then return true end
    if not (IsAddonLoaded("Lorewalker") and IsAddonLoaded("Spoken")) then return false end
    spoken = _G.Spoken
    if type(spoken) ~= "table" or type(spoken.GetCurrent) ~= "function"
        or type(spoken.GetPlayerStyle) ~= "function" or type(spoken.CreateRoundButton) ~= "function" then
        return false
    end
    local dialog = _G.LWDialogFrame
    if not (dialog and dialog.HookScript and dialog.ContentFrame and dialog.GossipFrame and dialog.QuestFrame) then
        return false
    end
    if not driver then
        if not CreatePanel() then return false end
        driver = _G.CreateFrame("Frame")
        driver:SetScript("OnUpdate", OnUpdate)
        dialog:HookScript("OnShow", function()
            if not IsPresentationEnabled() then return end
            pendingClose = nil
            if IsLorewalkerDialogOpen()
                and spoken and type(spoken.GetPlayerStyle) == "function"
                and spoken:GetPlayerStyle() == "classic" then
                HideSpokenWindow()
            elseif not (panel and panel.IsShown and panel:IsShown()) then
                RestoreSpokenWindow()
            end
            npcPortraitCaptured = false
            npcPortraitRingCaptured = false
            if npcPortraitTexture then npcPortraitTexture:SetTexture(nil) end
            if npcPortraitRing then npcPortraitRing:SetTexture(nil) end
            CaptureNpcPortrait(dialog)
            SnapshotDialog(dialog)
        end)
        dialog:HookScript("OnHide", function() OnDialogHidden(dialog) end)
    end
    if not spokenAudioChangedHandle and type(spoken.RegisterCallback) == "function" then
        spokenAudioChangedHandle = spoken:RegisterCallback("AUDIO_CHANGED", OnSpokenAudioChanged)
    end
    return true
end

function compat.SetMovementLocked(locked)
    local settings = PresentationSettings()
    settings.movementLocked = locked and true or false
    if settings.movementLocked then StopPanelDrag() end
    return settings.movementLocked
end

function compat.SetEnabled(enabled)
    local settings = PresentationSettings()
    settings.enabled = enabled and true or false
    if settings.enabled then return compat.InitializeSpokenGossipPresentation() end

    pendingClose = nil
    context = nil
    activeClip = nil
    missingClipSince = nil
    motion = nil
    textFade = nil
    if panel then
        panel:Hide()
        panel:SetAlpha(1)
        panel:SetScale(1)
    end
    if ReleasePortrait then ReleasePortrait() end
    if spokenAudioChangedHandle and spoken and type(spoken.UnregisterCallback) == "function" then
        spoken:UnregisterCallback(spokenAudioChangedHandle)
        spokenAudioChangedHandle = nil
    end
    RestoreSpokenWindow()
    return false
end

addon.RegisterModule("Compat.SpokenGossipPresentation", compat.InitializeSpokenGossipPresentation)
