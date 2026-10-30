local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local lib = LibStub("CustomNames")

-- What guildmates share is never written to CustomNames without the user, unless they trust that guildmate.
-- A DATA message becomes a pending entry, the diff against what was accepted before is worked out when it is shown
-- and again when it is accepted, CustomNames can change in between

---@class CustomNamesGuildSyncSync
local Sync = {}
private.Sync = Sync

local variables = {
    maxChars = 200,
    maxNameLength = 64,
    maxDisplayLength = 48,
}

---@param value any
---@return boolean
local function IsValidCharName(value)
    return type(value) == "string" and #value <= variables.maxNameLength and not value:find("#", 1, true)
        and value:match("^[^%-%s][^%s]*%-%S+$") ~= nil
end

---@param value any
---@return boolean
local function IsValidBattleTag(value)
    return type(value) == "string" and #value <= variables.maxNameLength and value:match("^[^#%s]+#%d+$") ~= nil
end

---Checks a DATA message and turns it into the pending entry that is saved
---@param sender string
---@param message table
---@return table? payload -- nil if the message can't be used
local function ReadPayload(sender, message)
    local syncId = message.id
    if type(syncId) ~= "string" or not syncId:match("^%d%d%d%d%d%d%d%d%d%d$") then return nil end
    local key = message.key
    if key ~= private.GetAnonKey(syncId) then
        -- a btag can only be used as the key if it is the btag that was sent
        if not IsValidBattleTag(key) or message.btag ~= key then return nil end
    end
    if key == private.SELF_BTAG or key == private.GetOwnBattleTag() or syncId == private.db.syncId then return nil end
    if type(message.chars) ~= "table" or #message.chars == 0 or #message.chars > variables.maxChars then return nil end
    local chars, set = {}, {}
    for _, charname in ipairs(message.chars) do
        if not IsValidCharName(charname) then return nil end
        if not set[charname] then
            set[charname] = true
            table.insert(chars, charname)
        end
    end
    -- whoever sends the list has to be on it, nobody can only claim characters of somebody else
    if not set[sender] then return nil end
    table.sort(chars)
    local display = type(message.display) == "string" and message.display:sub(1, variables.maxDisplayLength) or nil
    if not display or display == "" then
        display = (strsplit("-", sender))
    end
    local name = private.SanitizeName(message.name, private.MAX_NAME_CHARS)
    return {
        id = syncId,
        key = key,
        btag = message.btag,
        display = display,
        name = name,
        sender = sender,
        chars = chars,
        hash = private.HashPayload(key, chars, name), -- worked out again, the one that was sent is not trusted
        receivedAt = time(),
    }
end

---@param syncId string
---@param hash string
---@return boolean wanted -- the HELLO announces something that wasn't seen yet
Sync.WantsData = function(syncId, hash)
    local db = private.db
    if db.blocked[syncId] or syncId == db.syncId then return false end
    local account = db.accounts[syncId]
    if account and account.lastHash == hash then return false end
    if db.declined[syncId] == hash then return false end
    if db.pending[syncId] and db.pending[syncId].hash == hash then return false end
    return true
end

---@param key string
---@return string? customName -- nil if none is set
local function GetCustomName(key)
    local customName = lib.Get(key)
    if customName ~= key then
        return customName
    end
    return nil
end

---Works out what accepting a pending entry would change
---@param syncId string
---@return table? diff -- { added = list, removed = list, conflicts = list, moved = number, oldKey = string?, name = string|false|nil }
Sync.GetDiff = function(syncId)
    local db = private.db
    local payload = db.pending[syncId]
    if not payload then return nil end
    local account = db.accounts[syncId]
    local accepted = account and account.accepted or {}
    local excluded = account and account.excluded or {}
    local oldKey = account and account.key ~= payload.key and account.key or nil
    local linked = lib.GetLinkedCharacters(payload.key)
    local incoming = {}
    local diff = { added = {}, removed = {}, conflicts = {}, moved = 0, oldKey = oldKey }
    -- false: the name that was shared before isn't shared anymore
    if payload.name ~= (account and account.name) then
        diff.name = payload.name or false
    end
    for _, charname in ipairs(payload.chars) do
        incoming[charname] = true
        if excluded[charname] then
            -- the user removed this character from the account, it is not offered again
        elseif not accepted[charname] then
            if linked[charname] or not lib.IsInBnetDatabase(charname) then
                table.insert(diff.added, charname)
            else
                table.insert(diff.conflicts, charname)
            end
        elseif oldKey then
            diff.moved = diff.moved + 1
        end
    end
    for _, charname in ipairs(private.SortedKeys(accepted)) do
        if not incoming[charname] then
            table.insert(diff.removed, charname)
        end
    end
    return diff
end

---@param diff table
---@return boolean empty -- accepting would change nothing
local function IsEmpty(diff)
    return #diff.added == 0 and #diff.removed == 0 and #diff.conflicts == 0 and not diff.oldKey and diff.name == nil
end

local function Changed()
    lib.RefreshWindow()
end

local applying = false -- set while this addon writes to CustomNames itself, see Char_Unlinked below

---Runs writes of this addon to CustomNames, removals in there are not mistaken for removals by the user
---@param func function
local function Apply(func)
    applying = true
    local success, message = pcall(func)
    applying = false
    if not success then
        geterrorhandler()(message)
    end
end

---Moves the accepted characters and the custom name of an account to the key it is shared under now
---@param account table
---@param newKey string
local function MoveAccount(account, newKey)
    local oldKey = account.key
    for charname in pairs(account.accepted) do
        lib.RemoveCharFromBtag(charname, oldKey)
        lib.AddCharToBtag(charname, newKey)
    end
    local customName = lib.Get(oldKey)
    if customName ~= oldKey then
        if lib.Get(newKey) == newKey then
            lib.Set(newKey, customName)
        end
        -- the anonymous key means nothing to anybody else, a btag may still be a friend
        if oldKey:sub(1, #private.ANON_PREFIX) == private.ANON_PREFIX then
            lib.Set(oldKey)
        end
    end
    account.key = newKey
end

---Writes a pending entry into CustomNames
---@param syncId string
---@param trust boolean? -- also trust the guildmate from now on
---@return boolean success
Sync.Accept = function(syncId, trust)
    local db = private.db
    local payload = db.pending[syncId]
    if not payload then return false end
    local diff = Sync.GetDiff(syncId)
    local account = db.accounts[syncId]
    if not account then
        account = { key = payload.key, accepted = {}, trusted = false }
        db.accounts[syncId] = account
    end
    Apply(function()
        if diff.oldKey then
            MoveAccount(account, payload.key)
        end
        for _, charname in ipairs(diff.removed) do
            lib.RemoveCharFromBtag(charname, account.key)
            account.accepted[charname] = nil
        end
        for _, charname in ipairs(diff.added) do
            lib.AddCharToBtag(charname, account.key)
            account.accepted[charname] = true
        end
        if diff.name ~= nil then
            -- a name the user set themself stays, the shared one is only suggested then
            local customName = GetCustomName(account.key)
            if (diff.name or customName) and (not customName or customName == account.name) then
                lib.Set(account.key, diff.name or nil)
            end
            account.name = diff.name or nil
        end
    end)
    -- characters the guildmate doesn't share anymore don't have to be remembered as removed
    if account.excluded then
        local offered = {}
        for _, charname in ipairs(payload.chars) do
            offered[charname] = true
        end
        for charname in pairs(account.excluded) do
            if not offered[charname] then
                account.excluded[charname] = nil
            end
        end
    end
    account.display = payload.display
    account.btag = payload.btag
    account.sender = payload.sender
    account.lastHash = payload.hash
    account.lastSeen = payload.receivedAt
    if trust then
        account.trusted = true
    end
    db.pending[syncId] = nil
    db.declined[syncId] = nil
    Changed()
    return true
end

---@param syncId string
Sync.Decline = function(syncId)
    local db = private.db
    local payload = db.pending[syncId]
    if not payload then return end
    db.declined[syncId] = payload.hash
    db.pending[syncId] = nil
    Changed()
end

---Ignores everything the guildmate sends from now on, what was accepted before stays
---@param syncId string
Sync.Block = function(syncId)
    local db = private.db
    local payload = db.pending[syncId]
    local account = db.accounts[syncId]
    local source = payload or account or {}
    db.blocked[syncId] = { display = source.display, sender = source.sender }
    db.pending[syncId] = nil
    if account then
        account.trusted = false
    end
    Changed()
end

---@param syncId string
Sync.Unblock = function(syncId)
    private.db.blocked[syncId] = nil
    Changed()
end

---@param syncId string
---@param trusted boolean
Sync.SetTrusted = function(syncId, trusted)
    local account = private.db.accounts[syncId]
    if not account then return end
    account.trusted = trusted and true or false
    if trusted and private.db.pending[syncId] then
        Sync.Accept(syncId)
    else
        Changed()
    end
end

---Removes everything that was accepted from a guildmate
---@param syncId string
Sync.Forget = function(syncId)
    local db = private.db
    local account = db.accounts[syncId]
    if account then
        Apply(function()
            for charname in pairs(account.accepted) do
                lib.RemoveCharFromBtag(charname, account.key)
            end
            local customName = GetCustomName(account.key)
            local isAnon = account.key:sub(1, #private.ANON_PREFIX) == private.ANON_PREFIX
            if customName and (isAnon or customName == account.name) then
                lib.Set(account.key)
            end
        end)
    end
    db.accounts[syncId] = nil
    db.pending[syncId] = nil
    db.declined[syncId] = nil
    Changed()
end

---Handles a DATA message that passed the checks of Comm
---@param sender string
---@param message table
Sync.OnData = function(sender, message)
    local db = private.db
    local payload = ReadPayload(sender, message)
    if not payload or db.blocked[payload.id] then return end
    if not Sync.WantsData(payload.id, payload.hash) then return end

    local account = db.accounts[payload.id]
    db.pending[payload.id] = payload
    local diff = Sync.GetDiff(payload.id)
    if IsEmpty(diff) then
        -- nothing to ask about, only remember that this state was seen
        db.pending[payload.id] = nil
        if account then
            account.lastHash, account.lastSeen, account.sender = payload.hash, payload.receivedAt, sender
            account.display = payload.display
            account.name = payload.name
        end
        Changed()
        return
    end
    if account and account.trusted then
        Sync.Accept(payload.id)
        private.Print(private.getLocalisation("ChatAutoApplied"):format(payload.display))
        return
    end
    if account and #diff.added + #diff.removed == 0 and diff.name then
        private.Print(private.getLocalisation("ChatPendingName"):format(payload.display, diff.name))
    elseif account then
        private.Print(private.getLocalisation("ChatPendingChange"):format(payload.display, #diff.added, #diff.removed))
    else
        private.Print(private.getLocalisation("ChatPending"):format(payload.display, #payload.chars))
    end
    Changed()
end

---@param key string -- key of an account in CustomNames
---@return string? syncId
---@return table? account
Sync.FindByKey = function(key)
    for syncId, account in pairs(private.db.accounts) do
        if account.key == key then
            return syncId, account
        end
    end
    return nil
end

---Uses the name the guildmate shares as the custom name, replacing what the user set
---@param syncId string
Sync.UseSharedName = function(syncId)
    local account = private.db.accounts[syncId]
    if not account or not account.name then return end
    Apply(function()
        lib.Set(account.key, account.name)
    end)
    Changed()
end

---Removes one accepted character from a guildmate, later shares don't offer it again
---@param syncId string
---@param charname string
Sync.RemoveChar = function(syncId, charname)
    local account = private.db.accounts[syncId]
    if not account or not account.accepted[charname] then return end
    -- Char_Unlinked below records the removal, it also catches removals on the BattleTags tab
    lib.RemoveCharFromBtag(charname, account.key, true)
end

-- a character of a synced account was removed in CustomNames (by the user, here or on the BattleTags tab)
local callbackOwner = {}
lib.RegisterCallback(callbackOwner, "Char_Unlinked", function(_, charname, btag)
    if applying or not private.db then return end
    local _, account = Sync.FindByKey(btag)
    if not account or not account.accepted[charname] then return end
    account.accepted[charname] = nil
    account.excluded = account.excluded or {}
    account.excluded[charname] = true
    Changed()
end)
