local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local currentLocale = LibStub("AceLocale-3.0"):GetLocale(appName, true)
private.getLocalisation = function(Object)
      return currentLocale[Object]
end

---@param count number
---@return string text -- "1 character" or "%d characters"
private.FormatCharacterCount = function(count)
      if count == 1 then
            return currentLocale["CharacterCountOne"]
      end
      return currentLocale["CharacterCount"]:format(count)
end
