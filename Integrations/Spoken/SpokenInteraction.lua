-- Synchronizes Interaction's readable pages with Spoken_Readables.
local _, addon = ...
local compat = addon.Compat or {}
addon.Compat = compat

local TICK = 0.05
local MIN_MATCH_SHARE = 0.65
local LOOKAHEAD = 6

local spoken
local driver
local stoppedHandle
local session
local elapsed = 0

local function IsAddonLoaded(name)
    if _G.C_AddOns and _G.C_AddOns.IsAddOnLoaded then
        return _G.C_AddOns.IsAddOnLoaded(name)
    end
    return _G.IsAddOnLoaded and _G.IsAddOnLoaded(name) or false
end

local function SafeText(value)
    if type(value) ~= "string" then return nil end
    if spoken and type(spoken.NotSecret) == "function" then
        local ok, safeValue = pcall(spoken.NotSecret, value)
        if not ok then return nil end
        value = safeValue
    end
    return value
end

local function NormalizeText(value)
    value = SafeText(value)
    if not value then return "" end
    local ok, words = pcall(spoken.SplitCaption, spoken, value)
    if not (ok and type(words) == "table") then return "" end
    local keys, marks = {}, spoken:WordMarks()
    for _, word in ipairs(words) do
        local key = type(word) == "table" and marks.Key(word.text)
        if key then keys[#keys + 1] = key end
    end
    return table.concat(keys, " ")
end

local function ContainsWords(haystack, needle)
    return needle ~= "" and (" " .. haystack .. " "):find(" " .. needle .. " ", 1, true) ~= nil
end

local function IsReadableClip(clip)
    return clip and clip.source and clip.source.key == "readables"
        and IsAddonLoaded("Spoken_Readables")
end

local function ReadableFrames()
    local frame = _G.InteractionReadableUIFrame
    if not (frame and frame.IsShown and frame:IsShown()) then return nil end
    local ui = frame.ReadableUIFrame
    if not (ui and ui.IsShown and ui:IsShown()) then return nil end
    local book, item = ui.BookFrame, ui.ItemFrame
    local bookOpen = book and book.IsVisible and book:IsVisible()
    local itemOpen = item and item.IsVisible and item:IsVisible()
    if not (bookOpen or itemOpen) then return nil end
    return frame, ui, bookOpen and book or nil, itemOpen and item or nil
end

local function GetText(region)
    if not (region and region.GetText) then return "" end
    local ok, value = pcall(region.GetText, region)
    return ok and SafeText(value) or ""
end

local function PageNumber(value)
    if type(value) == "number" then return value end
    if type(value) ~= "string" then return nil end
    return tonumber(value:match("^%s*(%d+)"))
end

local function ReadTitle(ui, book)
    if book then
        local front = book.FrontPage
        local title = GetText(front and front.Text and front.Text.Title)
        if title ~= "" then return title end
    end
    return GetText(ui.Title and ui.Title.Text)
end

local function ReadVisiblePages(ui, book, item)
    local title = ReadTitle(ui, book)
    if book and book.FrontPage and book.FrontPage.IsVisible and book.FrontPage:IsVisible() then
        return title, true, {}, "cover\31" .. title
    end

    local pages, pageSignature = {}, ""
    if book and book.Content then
        local content = book.Content
        local left = content.Left
        local right = content.Right
        local leftText = GetText(left and left.Text and left.Text.Text)
        local rightText = GetText(right and right.Text and right.Text.Text)
        local leftNumber, rightNumber = GetText(left and left.Footer), GetText(right and right.Footer)
        if leftText ~= "" then
            pages[#pages + 1] = { side = "left", text = leftText, number = PageNumber(leftNumber) }
        end
        if rightText ~= "" then
            pages[#pages + 1] = { side = "right", text = rightText, number = PageNumber(rightNumber) }
        end
        pageSignature = "\31" .. leftNumber .. "\31" .. rightNumber
    elseif item and item.ScrollFrame then
        local text = GetText(item.ScrollFrame.Text and item.ScrollFrame.Text.Text)
        local pageCounter = GetText(ui.Title and ui.Title.CurrentPageText)
        if text ~= "" then
            pages[#pages + 1] = { side = "page", text = text, number = PageNumber(pageCounter) }
        end
    end
    return title, false, pages, title .. "\31" .. table.concat({ pages[1] and pages[1].text or "",
        pages[2] and pages[2].text or "" }, "\31") .. pageSignature
end

local function ClipMatchesTitle(clip, title)
    local needle = NormalizeText(title)
    local present = clip and clip.present
    if needle == "" or not present then return false end
    if NormalizeText(present.label) == needle or NormalizeText(present.header) == needle then return true end
    local candidates = {}
    if type(present.transcript) == "string" then candidates[#candidates + 1] = present.transcript end
    if type(clip.text) == "string" then candidates[#candidates + 1] = clip.text end
    for _, text in ipairs(candidates) do
        if ContainsWords(NormalizeText(text), needle) then return true end
    end
    return false
end

local function FindSpan(text, captionWords)
    local ok, targetWords = pcall(spoken.SplitCaption, spoken, text)
    if not (ok and type(targetWords) == "table" and type(captionWords) == "table") then return nil end
    local marks, target = spoken:WordMarks(), {}
    for _, word in ipairs(targetWords) do
        local key = type(word) == "table" and marks.Key(word.text)
        if key then target[#target + 1] = key end
    end
    if #target == 0 then return nil end

    local bestStart, bestEnd, bestFound
    for start = 1, #captionWords do
        local first = captionWords[start]
        if type(first) == "table" and marks.Key(first.text) == target[1] then
            local cursor, found, lastTarget = start, 1, 1
            for targetIndex = 2, #target do
                local limit = math.min(#captionWords, cursor + LOOKAHEAD)
                for index = cursor + 1, limit do
                    local candidate = captionWords[index]
                    if type(candidate) == "table" and marks.Key(candidate.text) == target[targetIndex] then
                        cursor, found, lastTarget = index, found + 1, targetIndex
                        break
                    end
                end
            end
            if lastTarget == #target and found / #target >= MIN_MATCH_SHARE
                and (not bestFound or found > bestFound) then
                bestStart, bestEnd, bestFound = start, cursor, found
            end
        end
    end
    if bestStart then return bestStart, bestEnd end
end

local function FindCaptionInText(text, captionWords)
    local ok, pageWords = pcall(spoken.SplitCaption, spoken, text)
    if not (ok and type(pageWords) == "table" and type(captionWords) == "table") then return nil end
    local marks = spoken:WordMarks()
    if type(marks.Align) ~= "function" then return nil end
    if type(marks.MarkLinks) == "function" then marks.MarkLinks(text, pageWords) end
    local map = marks.Align(captionWords, { { text = text, words = pageWords } })
    if not map then return nil end
    local first, last
    for captionIndex, location in pairs(map) do
        if location.p == 1 then
            first = not first and captionIndex or math.min(first, captionIndex)
            last = not last and captionIndex or math.max(last, captionIndex)
        end
    end
    if first then return first, last end
end

local function ReadablesPage(clip)
    local readables = _G.SpokenReadables
    if not (clip and clip.pageId and readables and type(readables.PlaceOf) == "function") then
        return nil, nil
    end
    local ok, bookId, pageNumber = pcall(readables.PlaceOf, readables, clip.pageId)
    if not ok then return nil, nil end
    return bookId, tonumber(pageNumber)
end

local function FindVisiblePageNumber(pages, pageNumber)
    if not pageNumber then return nil end
    for _, page in ipairs(pages) do
        if page.number == pageNumber then return page.side end
    end
end

local function FindVisibleSide(pages, captionWords, onlySide)
    local bestSide, bestEnd, bestScore
    for _, page in ipairs(pages) do
        if not onlySide or page.side == onlySide then
            local first, last = FindCaptionInText(page.text, captionWords)
            if first then
                local score = last - first
                if not bestScore or score > bestScore then
                    bestSide, bestEnd, bestScore = page.side, last, score
                end
            end
        end
    end
    return bestSide, bestEnd
end

local function CaptionReached(caption, finalIndex)
    local word = caption.words and caption.words[finalIndex]
    return word and type(caption.progress) == "number" and type(caption.totalWeight) == "number"
        and type(word.finish) == "number" and caption.progress * caption.totalWeight >= word.finish or false
end

local function FirstCaptionWordStarted(caption)
    local first = caption.words and caption.words[1]
    if not (caption.speaking and caption.activeWord and first
        and type(caption.progress) == "number" and type(caption.totalWeight) == "number"
        and type(first.start) == "number") then
        return false
    end
    return caption.progress * caption.totalWeight >= first.start
end

local function SetPresentationSuspended(suspended)
    local presentation = addon.Compat
    if presentation and type(presentation.SetInteractionSuspended) == "function" then
        presentation.SetInteractionSuspended(suspended)
    end
end

local function AdvanceReadable(frame)
    if not (frame and type(frame.Next) == "function") then return false end
    if not session.waitingTurn then
        session.waitingTurn = session.signature
        session.side = nil
        session.matchEnd = nil
        pcall(frame.Next, frame)
    end
    return true
end

local function CloseReadable()
    local frame = _G.InteractionReadableUIFrame
    if frame and type(frame.HideWithAnimation) == "function" then
        pcall(frame.HideWithAnimation, frame)
    end
    session = nil
end

local function HasFollowingClip(clip)
    if clip.continues then return true end
    if not clip.group or type(spoken.GetQueue) ~= "function" then return false end
    local ok, queue = pcall(spoken.GetQueue, spoken)
    if not (ok and type(queue) == "table") then return false end
    for _, queued in ipairs(queue) do
        if queued ~= clip and queued.group == clip.group then return true end
    end
    return false
end

local function OnClipStopped(clip, finishedPlaying)
    if not finishedPlaying or not session or session.clip ~= clip then return end
    local frame = ReadableFrames()
    if not frame then return end
    if not HasFollowingClip(clip) then
        CloseReadable()
        return
    end

    local hasRightPage = session.pages and session.pages.right
    if session.side == "left" and hasRightPage then
        session.waitingForRight = true
    elseif session.side == "right" or session.side == "page"
        or (session.side == "left" and not hasRightPage) then
        AdvanceReadable(frame)
    end
    session.previousSide = session.side
    session.clip = nil
    session.matchEnd = nil
end

local function OnUpdate(_, delta)
    elapsed = elapsed + delta
    if elapsed < TICK then return end
    elapsed = 0

    local frame, ui, book, item = ReadableFrames()
    if not frame then
        session = nil
        SetPresentationSuspended(false)
        return
    end
    SetPresentationSuspended(true)

    local title, isCover, pages, signature = ReadVisiblePages(ui, book, item)
    if not session then
        session = { title = title, signature = signature, pages = {} }
    elseif session.signature ~= signature then
        session.signature = signature
        session.pages = {}
        for _, page in ipairs(pages) do session.pages[page.side] = page.text end
        session.side = nil
        session.matchEnd = nil
        if session.waitingTurn then session.waitingTurn = nil end
    end
    session.pages = {}
    for _, page in ipairs(pages) do session.pages[page.side] = page.text end

    local clip = type(spoken.GetCurrent) == "function" and spoken:GetCurrent()
    if not IsReadableClip(clip) or not ClipMatchesTitle(clip, session.title) then return end
    local caption = type(spoken.GetCaption) == "function" and spoken:GetCaption()
    if not (caption and caption.clip == clip and type(caption.words) == "table") then return end
    local bookId, pageNumber = ReadablesPage(clip)
    if bookId then
        if session.bookId and session.bookId ~= bookId then return end
        session.bookId = bookId
    end

    if session.waitingTurn == signature then return end
    if session.clip ~= clip then
        session.clip = clip
        session.side = nil
        session.matchEnd = nil
        if session.waitingForRight then
            local side = FindVisiblePageNumber(pages, pageNumber)
            local last
            if side ~= "right" then
                side, last = FindVisibleSide(pages, caption.words, "right")
            end
            if side then
                session.side, session.matchEnd = side, last
                session.waitingForRight = nil
            else
                if pageNumber and not FindVisiblePageNumber(pages, pageNumber) then
                    session.waitingForRight = nil
                    AdvanceReadable(frame)
                end
                return
            end
        end
    end

    if isCover then
        if not session.matchEnd then
            local _, titleEnd = FindSpan(title, caption.words)
            if titleEnd then
                session.side, session.matchEnd = "cover", titleEnd
            elseif FirstCaptionWordStarted(caption) then
                -- Spoken_Readables times the cover title before the first page's words,
                -- while its transcript contains only that page.
                AdvanceReadable(frame)
                return
            end
        end
        if session.side == "cover" and CaptionReached(caption, session.matchEnd) then
            AdvanceReadable(frame)
        end
        return
    end

    if not session.side then
        session.side = FindVisiblePageNumber(pages, pageNumber)
        if not session.side then
            session.side, session.matchEnd = FindVisibleSide(pages, caption.words)
        end
    end
end

function compat.InitializeSpokenInteraction()
    if not (IsAddonLoaded("Interaction") and IsAddonLoaded("Spoken")
        and IsAddonLoaded("Spoken_Readables")) then
        return false
    end
    spoken = _G.Spoken
    if type(spoken) ~= "table" or type(spoken.GetCurrent) ~= "function"
        or type(spoken.GetCaption) ~= "function" or type(spoken.GetQueue) ~= "function"
        or type(spoken.SplitCaption) ~= "function" or type(spoken.WordMarks) ~= "function"
        or type(spoken.RegisterCallback) ~= "function" then
        return false
    end
    if not driver then
        driver = _G.CreateFrame("Frame")
        driver:SetScript("OnUpdate", OnUpdate)
    end
    if not stoppedHandle then
        stoppedHandle = spoken:RegisterCallback("CLIP_STOPPED", OnClipStopped)
    end
    return true
end

addon.RegisterModule("Compat.SpokenInteraction", compat.InitializeSpokenInteraction)
