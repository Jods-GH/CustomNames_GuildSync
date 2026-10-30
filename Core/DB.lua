local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local lib = LibStub("CustomNames")

-- accounts of guildmates that don't share their btag are stored under this prefix and their sync id,
-- it looks like a btag so CustomNames handles it like one
private.ANON_PREFIX = "GuildSync#"
private.SELF_BTAG = "self"
private.MAX_NAME_CHARS = 48

local defaults = {
    configured = false, -- the first run popup was answered, nothing is sent or received before that
    share = true,
    shareBattleTag = false,
    shareName = false,
    syncId = nil, -- generated once per account
    accounts = {}, -- [syncId] = { key, display, btag?, name?, sender, accepted = { [Name-Realm] = true }, trusted, lastHash, lastSeen }
    pending = {}, -- [syncId] = payload of DATA that waits for the user, see Sync.lua
    declined = {}, -- [syncId] = hash of the payload that was declined
    blocked = {}, -- [syncId or "nsrt:" .. Name-Realm] = { display, sender }
    nicknames = {}, -- [Name-Realm] = { nickname?, offer = string|false|nil, declined?, trusted, lastSeen }, see NSRT.lua
}

local readyCallbacks = {}

---@return string syncId -- 10 digits
local function GenerateSyncId()
    return string.format("%05d%05d", math.random(0, 99999), math.random(0, 99999))
end

---Runs the function once the saved variables are loaded
---@param func function
private.OnReady = function(func)
    if private.db then
        func()
    else
        table.insert(readyCallbacks, func)
    end
end

--- Since GetNormalizedRealmName can return nil we need to gsub GetRealmName ourselfs if need be
---@return string Realm
local function NormalizedRealmName()
    return GetNormalizedRealmName() or GetRealmName():gsub("[%s-]+", "")
end
private.NormalizedRealmName = NormalizedRealmName

---@param value any
---@return boolean readable -- false for secret values, they can't be compared or used as a key
private.IsReadable = function(value)
    if issecretvalue and issecretvalue(value) then return false end
    if canaccessvalue and not canaccessvalue(value) then return false end
    return true
end

---Adds the realm to a name that has none (addon messages from the own realm can come without it)
---@param name string
---@return string fullName -- Name-Realm
private.FullName = function(name)
    if name:find("-", 1, true) then return name end
    return name .. "-" .. NormalizedRealmName()
end

---@return string? battleTag -- nil if battle.net is not available
private.GetOwnBattleTag = function()
    if not BNGetInfo then return nil end
    local _, battleTag = BNGetInfo()
    if private.IsReadable(battleTag) and type(battleTag) == "string" and battleTag:match("^[^#%s]+#%d+$") then
        return battleTag
    end
    return nil
end

local playerName, playerFullName -- remembered while they can be read, unit names can turn secret during lockdowns

---@return string? name -- name of the logged in character without the realm
---@return string? fullName -- Name-Realm of the logged in character
local function ReadPlayerName()
    if playerFullName then return playerName, playerFullName end
    local name, realm = UnitFullName("player")
    if not (private.IsReadable(name) and private.IsReadable(realm)) or type(name) ~= "string" then return nil end
    if type(realm) ~= "string" or realm == "" then
        realm = NormalizedRealmName()
    end
    playerName, playerFullName = name, name .. "-" .. realm
    return playerName, playerFullName
end

---@return string? fullName -- Name-Realm of the logged in character, nil while it can't be read
private.GetPlayerName = function()
    local _, fullName = ReadPlayerName()
    return fullName
end

---@return string? name -- the logged in character without the realm, nil while it can't be read
private.GetPlayerShortName = function()
    return (ReadPlayerName())
end

---@param syncId string
---@return string key -- the anonymous key an account is stored under in CustomNames
private.GetAnonKey = function(syncId)
    return private.ANON_PREFIX .. syncId
end

---@return string key -- what guildmates store the own characters under
---@return string? battleTag -- set if the btag is shared
private.GetOwnKey = function()
    local db = private.db
    if db.shareBattleTag then
        local battleTag = private.GetOwnBattleTag()
        if battleTag then
            return battleTag, battleTag
        end
    end
    return private.GetAnonKey(db.syncId), nil
end

---@return table chars -- sorted list of the characters of this account (Name-Realm)
private.GetOwnChars = function()
    local set = {}
    for charname in pairs(lib.GetLinkedCharacters(private.SELF_BTAG)) do
        set[charname] = true
    end
    -- CustomNames links the character on login, but only if it isn't linked elsewhere
    local playerFullName = private.GetPlayerName()
    if playerFullName then
        set[playerFullName] = true
    end
    local list = {}
    for charname in pairs(set) do
        table.insert(list, charname)
    end
    table.sort(list)
    return list
end

---Cuts a text to a number of characters without splitting a multibyte character
---@param text string
---@param maxChars number
---@return string text
private.Utf8Sub = function(text, maxChars)
    local count, cut = 0, 0
    for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > maxChars then break end
        cut = cut + #char
    end
    return text:sub(1, cut)
end

---Makes a name that came from somewhere else safe to show and store
---@param value any
---@param maxChars number
---@return string? name -- nil if nothing usable is left
private.SanitizeName = function(value, maxChars)
    if type(value) ~= "string" then return nil end
    -- escape sequences would let a name color or hyperlink itself in chat
    local name = value:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[|%c]", "")
    name = private.Utf8Sub(strtrim(name), maxChars)
    if name == "" then return nil end
    return name
end

---@return string? name -- the custom name the user set for their own account in CustomNames
private.GetOwnName = function()
    local name = lib.Get(private.SELF_BTAG)
    if name == private.SELF_BTAG then return nil end
    return private.SanitizeName(name, private.MAX_NAME_CHARS)
end

---@return string? name -- the own name if guildmates get it
private.GetSharedName = function()
    local db = private.db
    if not (db.share and db.shareName) then return nil end
    return private.GetOwnName()
end

---@param set table -- [Name-Realm] = true
---@return table list -- sorted names
private.SortedKeys = function(set)
    local list = {}
    for key in pairs(set) do
        table.insert(list, key)
    end
    table.sort(list)
    return list
end

---Hash of what an account shares, used to notice changes without sending the whole list
---@param key string
---@param chars table -- sorted list
---@param name string? -- left out of the text if nil, so older versions get the same hash
---@return string hash
private.HashPayload = function(key, chars, name)
    local text = key .. "|" .. table.concat(chars, ",")
    if name then
        text = text .. "|" .. name
    end
    local hash = 5381
    for index = 1, #text do
        hash = (hash * 33 + text:byte(index)) % 4294967296
    end
    return string.format("%08x", hash)
end

---@param message string
private.Print = function(message)
    print(private.getLocalisation("ChatPrefix") .. message)
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, addon)
    if addon ~= appName then return end
    self:UnregisterEvent("ADDON_LOADED")
    CustomNamesGuildSyncDB = CustomNamesGuildSyncDB or {}
    local db = CustomNamesGuildSyncDB
    for key, value in pairs(defaults) do
        if db[key] == nil then
            db[key] = type(value) == "table" and CopyTable(value) or value
        end
    end
    db.syncId = db.syncId or GenerateSyncId()
    private.db = db
    ReadPlayerName()
    for _, func in ipairs(readyCallbacks) do
        func()
    end
    wipe(readyCallbacks)
end)
