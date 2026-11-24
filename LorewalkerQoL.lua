-- Main entry point and module initializer for Lorewalker QoL.
-- WoW loads packaged Lua files through the addon's TOC/XML manifests; this
-- file provides the shared namespace and initializes registered modules.
local addonName, addon = ...

addon.name = addonName
addon.modules = addon.modules or {}

function addon.GetSpokenPresentationSettings()
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

addon.GetSpokenPresentationSettings()

function addon.RegisterModule(name, initialize)
    if type(name) ~= "string" or type(initialize) ~= "function" then return end
    -- A module remains eligible for initialization until its initializer returns something other than false.
    addon.modules[#addon.modules + 1] = {
        name = name,
        initialize = initialize,
        initialized = false,
    }
end

function addon.Initialize()
    for index = 1, #addon.modules do
        local module = addon.modules[index]
        if not module.initialized then
            -- Keep failures isolated; an initializer that throws is reported and can be retried later.
            local ok, initialized = pcall(module.initialize)
            if ok and initialized ~= false then
                module.initialized = true
            elseif not ok and _G.geterrorhandler then
                _G.geterrorhandler()(addonName .. " - " .. module.name .. ": " .. tostring(initialized))
            end
        end
    end
end

local lifecycle = _G.CreateFrame("Frame")
lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:RegisterEvent("PLAYER_LOGIN")
lifecycle:SetScript("OnEvent", function(_, event, loadedAddon)
    if event == "PLAYER_LOGIN"
        or loadedAddon == addonName
        or loadedAddon == "Lorewalker"
        or loadedAddon == "Curator"
        or loadedAddon == "PrettyTooltip"
        or loadedAddon == "Spoken_Places"
        or loadedAddon == "Pawn" then
        addon.Initialize()
    end
end)

local function ParseSetting(value, current)
    value = (value or ""):match("^%s*(.-)%s*$"):lower()
    if value == "on" or value == "yes" or value == "1" or value == "si" then return true end
    if value == "off" or value == "no" or value == "0" then return false end
    return not current
end

SLASH_LOREWALKERQOL1 = "/lwq"
SlashCmdList.LOREWALKERQOL = function(message)
    local command, value = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    command = (command or ""):lower()
    local settings = addon.GetSpokenPresentationSettings()
    local presentation = addon.Compat and addon.Compat.SpokenGossipPresentation

    if command == "lock" then
        settings.movementLocked = ParseSetting(value, settings.movementLocked)
        if presentation and presentation.SetMovementLocked then
            presentation.SetMovementLocked(settings.movementLocked)
        end
        print("Lorewalker QoL: movimiento de la ventana "
            .. (settings.movementLocked and "bloqueado." or "desbloqueado."))
    else
        print("Comando disponible: /lwq lock [on|off]")
    end
end
