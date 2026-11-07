-- Main entry point and module initializer for Lorewalker QoL.
-- WoW loads packaged Lua files through the addon's TOC/XML manifests; this
-- file provides the shared namespace and initializes registered modules.
local addonName, addon = ...

addon.name = addonName
addon.modules = addon.modules or {}

function addon.RegisterModule(name, initialize)
    if type(name) ~= "string" or type(initialize) ~= "function" then return end
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
        or loadedAddon == "PrettyTooltip"
        or loadedAddon == "Pawn" then
        addon.Initialize()
    end
end)
