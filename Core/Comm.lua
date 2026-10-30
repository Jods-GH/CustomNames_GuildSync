local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local lib = LibStub("CustomNames")
local AceComm = LibStub("AceComm-3.0")

-- Messages are tables, serialized to CBOR, compressed and base64 encoded (addon messages can't carry "\0").
-- v is the protocol version:
-- HELLO  { t = "H", v, id, hash, h2?, q? } -- "this is what I share", to the guild or as an answer to q (query) by whisper
-- REQ    { t = "R", v }                -- "send me your characters", by whisper
-- DATA   { t = "D", v, id, key, btag?, display, name?, chars, hash } -- by whisper, only if sharing is enabled
-- hash leaves the name out so versions that don't know it don't ask again and again, h2 includes it
local PREFIX = "CNGuildSync"
local PROTOCOL = 1
local variables = {
    helloDelay = 10, -- seconds after login before the first HELLO, the guild roster needs a moment
    answerDelay = 8, -- answers to a query are spread over this many seconds so not everyone whispers at once
    requestCooldown = 60, -- seconds between two REQ to the same guildmate
    queryCooldown = 30, -- seconds between two queries of the same guildmate that get answered
    retryInterval = 15, -- seconds between tries to send what was held back by the messaging lockdown
    maxMessageLength = 20000,
}

local Comm = {}
AceComm:Embed(Comm)
private.Comm = Comm

local roster = {} -- [Name-Realm] = true for every member of the own guild
local lastRequest = {} -- [sender] = GetTime() of the last REQ
local lastAnswer = {} -- [sender] = GetTime() of the last answer to a query
local queue = {} -- [prefix .. distribution .. target .. type] = { prefix, text, distribution, target }
local retryTicker
local lastSharedName -- the own name the last HELLO was built with

-- every client in the toc has it except possibly some classic ones, those can't take part in the sync
if not (C_EncodingUtil and C_EncodingUtil.SerializeCBOR) then
    private.unsupported = true
    C_Timer.After(5, function()
        private.Print(private.getLocalisation("ChatUnsupported"))
    end)
end

---@param message table
---@return string text
local function Encode(message)
    local data = C_EncodingUtil.SerializeCBOR(message)
    return C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(data))
end

---@param text string
---@return table? message -- nil if the text is not a message of this addon
local function Decode(text)
    -- whatever comes in may be broken or made up, the decoders raise errors for that
    local success, message = pcall(function()
        local data = C_EncodingUtil.DecompressString(C_EncodingUtil.DecodeBase64(text))
        return C_EncodingUtil.DeserializeCBOR(data)
    end)
    if success and type(message) == "table" then
        return message
    end
    return nil
end

---@return boolean active -- the user answered the first run popup and CustomNames is new enough
local function IsActive()
    return private.db and private.db.configured and not private.outdated and not private.unsupported and IsInGuild()
end
Comm.IsActive = IsActive

---@return boolean locked -- addon messages can't be sent right now (retail, in instances during encounters and similar)
local function InLockdown()
    return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown()
end

local LOCKDOWN_RESULT = Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.AddOnMessageLockdown
local FlushQueue

---Keeps a message until the lockdown is over, only the newest message of a kind to a target is kept
---@param queueKey string
---@param entry table -- { prefix, text, distribution, target }
local function Hold(queueKey, entry)
    queue[queueKey] = { prefix = entry.prefix, text = entry.text, distribution = entry.distribution, target = entry.target }
    if not retryTicker then
        retryTicker = C_Timer.NewTicker(variables.retryInterval, FlushQueue)
    end
end

---@param queueKey string
---@param entry table -- { prefix, text, distribution, target }
local function Transmit(queueKey, entry)
    local held = false
    -- ChatThrottleLib sends later than it is asked to. A lockdown that starts in between makes the game refuse
    -- the message and ChatThrottleLib drops it, so it is held and sent again as a whole once the lockdown is over
    -- depending on the versions of AceComm and ChatThrottleLib the last argument is the result code or only "did send"
    Comm:SendCommMessage(entry.prefix, entry.text, entry.distribution, entry.target, "BULK", function(_, _, _, sendResult)
        local refused = (LOCKDOWN_RESULT and sendResult == LOCKDOWN_RESULT) or (sendResult == false and InLockdown())
        if not held and refused then
            held = true
            Hold(queueKey, entry)
        end
    end)
end

FlushQueue = function()
    if InLockdown() then return end
    for queueKey, entry in pairs(queue) do
        queue[queueKey] = nil
        Transmit(queueKey, entry)
    end
    if retryTicker and not next(queue) then
        retryTicker:Cancel()
        retryTicker = nil
    end
end

---Sends already encoded text, also used for the messages of other addons (see NSRT.lua)
---@param prefix string
---@param kind string -- only the newest message of a kind to a target waits for the lockdown to end
---@param text string
---@param distribution "GUILD"|"WHISPER"
---@param target string? -- Name-Realm for whispers
---@return boolean sent -- false if it waits for the lockdown to end
Comm.SendText = function(prefix, kind, text, distribution, target)
    if not IsActive() then return false end
    local entry = { prefix = prefix, text = text, distribution = distribution, target = target }
    local queueKey = prefix .. distribution .. (target or "") .. kind
    if InLockdown() then
        Hold(queueKey, entry)
        return false
    end
    Transmit(queueKey, entry)
    return true
end

---@param message table
---@param distribution "GUILD"|"WHISPER"
---@param target string? -- Name-Realm for whispers
---@return boolean sent -- false if it waits for the lockdown to end
local function Send(message, distribution, target)
    if not IsActive() then return false end
    message.v = PROTOCOL
    return Comm.SendText(PREFIX, message.t, Encode(message), distribution, target)
end

---@return table message -- the HELLO of this account
local function BuildHello()
    local key = private.GetOwnKey()
    local chars = private.GetOwnChars()
    local name = private.GetSharedName()
    return {
        t = "H",
        id = private.db.syncId,
        hash = private.HashPayload(key, chars),
        h2 = name and private.HashPayload(key, chars, name) or nil,
    }
end

---Tells the guild what this account shares
---@param query boolean? -- also ask everyone to answer with their HELLO
---@return boolean sent
Comm.BroadcastHello = function(query)
    local message
    if private.db.share then
        message = BuildHello()
    else
        message = { t = "H" } -- receive only accounts still ask the others
    end
    message.q = query or nil
    lastSharedName = private.GetSharedName()
    if private.NSRT then
        private.NSRT.SendNickName()
    end
    return Send(message, "GUILD")
end

---@param sender string
local function Request(sender)
    local now = GetTime()
    if lastRequest[sender] and now - lastRequest[sender] < variables.requestCooldown then return end
    lastRequest[sender] = now
    Send({ t = "R" }, "WHISPER", sender)
end

---@param sender string
local function SendData(sender)
    local display = private.GetPlayerShortName()
    if not private.db.share or not display then return end
    local key, battleTag = private.GetOwnKey()
    local chars = private.GetOwnChars()
    local name = private.GetSharedName()
    Send({
        t = "D",
        id = private.db.syncId,
        key = key,
        btag = battleTag,
        display = display,
        name = name,
        chars = chars,
        hash = private.HashPayload(key, chars, name),
    }, "WHISPER", sender)
end

---@param sender string
local function AnswerQuery(sender)
    if not private.db.share then return end
    local now = GetTime()
    if lastAnswer[sender] and now - lastAnswer[sender] < variables.queryCooldown then return end
    lastAnswer[sender] = now
    C_Timer.After(math.random() * variables.answerDelay, function()
        Send(BuildHello(), "WHISPER", sender)
    end)
end

---@param sender string -- Name-Realm
---@return boolean own -- the message came from this account
local function IsOwnCharacter(sender)
    local playerName = private.GetPlayerName()
    -- without the own name a message of the own account can't be told apart, so it is dropped
    if not playerName or sender == playerName then return true end
    return lib.GetLinkedCharacters(private.SELF_BTAG)[sender] ~= nil
end
Comm.IsOwnCharacter = IsOwnCharacter

---@param keep boolean? -- add to what is known instead of starting over (senders seen in guild chat stay)
local function UpdateRoster(keep)
    -- the roster functions have no documentation about secrets, so nothing they return is used before it was checked
    local count = GetNumGuildMembers()
    if not private.IsReadable(count) or type(count) ~= "number" then return end
    if not keep then
        wipe(roster)
    end
    for index = 1, count do
        local name = GetGuildRosterInfo(index)
        if private.IsReadable(name) and type(name) == "string" then
            roster[private.FullName(name)] = true
        end
    end
end

---Checks the sender of an addon message before anything in it is used
---@param sender string -- Name-Realm
---@param distribution string
---@return boolean member
Comm.IsGuildMember = function(sender, distribution)
    if distribution == "GUILD" then
        -- the server only delivers guild messages from members, the roster may not be loaded yet
        roster[sender] = true
        return true
    end
    if not roster[sender] then
        UpdateRoster(true)
    end
    return roster[sender] == true
end

function Comm:OnCommReceived(prefix, text, distribution, sender)
    -- secret values raise an error on comparisons, so every argument is checked before anything else
    if not (private.IsReadable(prefix) and private.IsReadable(text) and private.IsReadable(distribution) and private.IsReadable(sender)) then return end
    if prefix ~= PREFIX or not IsActive() then return end
    if type(text) ~= "string" or #text > variables.maxMessageLength or type(sender) ~= "string" then return end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then return end
    sender = private.FullName(sender)
    if IsOwnCharacter(sender) or not Comm.IsGuildMember(sender, distribution) then return end

    local message = Decode(text)
    if not message or message.v ~= PROTOCOL then return end

    if message.t == "H" then
        if message.q then
            AnswerQuery(sender)
        end
        local hash = type(message.h2) == "string" and message.h2 or message.hash
        if type(message.id) == "string" and type(hash) == "string" and private.Sync.WantsData(message.id, hash) then
            Request(sender)
        end
    elseif message.t == "R" and distribution == "WHISPER" then
        SendData(sender)
    elseif message.t == "D" and distribution == "WHISPER" then
        private.Sync.OnData(sender, message)
    end
end

local helloSent = false

---Sends the first HELLO of the session once everything it needs is there
Comm.Start = function()
    if helloSent or not IsActive() then return end
    helloSent = true
    -- the roster is not requested with C_GuildInfo.GuildRoster(): the guild events it fires run in our (tainted)
    -- context and Blizzard_GuildControlUI then gets blocked from protected calls. The game requests it on its own
    C_Timer.After(variables.helloDelay, function()
        UpdateRoster()
        Comm.BroadcastHello(true)
    end)
end

local nameChangeQueued = false

-- CustomNames fires the name events for every character of an account, a change of the own name only goes out once
---@param name string -- Name-Realm or btag the event is about
local function OnNameEvent(_, name)
    if nameChangeQueued or not helloSent or not private.db or not private.db.shareName then return end
    if not private.IsReadable(name) or type(name) ~= "string" then return end
    if name ~= private.SELF_BTAG and not lib.GetLinkedCharacters(private.SELF_BTAG)[name] then return end
    nameChangeQueued = true
    C_Timer.After(1, function()
        nameChangeQueued = false
        if private.GetSharedName() == lastSharedName then return end
        Comm.BroadcastHello()
        lib.RefreshWindow()
    end)
end

local callbackOwner = {}
lib.RegisterCallback(callbackOwner, "Name_Added", OnNameEvent)
lib.RegisterCallback(callbackOwner, "Name_Update", OnNameEvent)
lib.RegisterCallback(callbackOwner, "Name_Removed", OnNameEvent)

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("GUILD_ROSTER_UPDATE")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
if C_EventUtils and C_EventUtils.IsEventValid and C_EventUtils.IsEventValid("ENCOUNTER_END") then
    frame:RegisterEvent("ENCOUNTER_END")
end
frame:SetScript("OnEvent", function(self, event)
    if event == "GUILD_ROSTER_UPDATE" then
        UpdateRoster()
    elseif event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_GUILD_UPDATE" then
        private.OnReady(Comm.Start)
    else
        FlushQueue()
    end
end)

private.OnReady(function()
    Comm:RegisterComm(PREFIX)
end)
