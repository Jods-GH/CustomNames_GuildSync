local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local currentLocale = LibStub("AceLocale-3.0"):GetLocale(appName, true)
private.getLocalisation = function(Object)
      return currentLocale[Object]
end
