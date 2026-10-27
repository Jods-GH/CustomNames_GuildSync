local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local lib = LibStub("CustomNames")
local AceComm = LibStub("AceComm-3.0")

-- Messages are tables, serialized to CBOR, compressed and base64 encoded (addon messages can't carry "\0").
-- v is the protocol version:
-- HELLO  { t = "H", v, id, hash, q? } -- "this is what I share", to the guild or as an answer to q (query) by whisper
-- REQ    { t = "R", v }                -- "send me your characters", by whisper
-- DATA   { t = "D", v, id, key, btag?, display, chars, hash } -- by whisper, only if sharing is enabled
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
local queue = {} -- [distribution .. target .. type] = { text, distribution, target }
local retryTicker

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

---@return boolean locked -- addon messages can't be sent right now (retail, in instances during encounters and similar)
local function InLockdown()
    return C_ChatInfo.InChatMessagingLockdown ~= nil and C_ChatInfo.InChatMessagingLockdown()
end

local function FlushQueue()
    if InLockdown() then return end
    for queueKey, entry in pairs(queue) do
        queue[queueKey] = nil
        Comm:SendCommMessage(PREFIX, entry.text, entry.distribution, entry.target, "BULK")
    end
    if retryTicker and not next(queue) then
        retryTicker:Cancel()
        retryTicker = nil
    end
end

---@param message table
---@param distribution "GUILD"|"WHISPER"
---@param target string? -- Name-Realm for whispers
---@return boolean sent -- false if it waits for the lockdown to end
local function Send(message, distribution, target)
    if not IsActive() then return false end
    message.v = PROTOCOL
    local text = Encode(message)
    if InLockdown() then
        -- only the newest message of a kind to a target is kept
        queue[distribution .. (target or "") .. message.t] = { text = text, distribution = distribution, target = target }
        if not retryTicker then
            retryTicker = C_Timer.NewTicker(variables.retryInterval, FlushQueue)
        end
        return false
    end
    Comm:SendCommMessage(PREFIX, text, distribution, target, "BULK")
    return true
end

---@return table message -- the HELLO of this account
local function BuildHello()
    local key = private.GetOwnKey()
    return { t = "H", id = private.db.syncId, hash = private.HashPayload(key, private.GetOwnChars()) }
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
    if not private.db.share then return end
    local key, battleTag = private.GetOwnKey()
    local chars = private.GetOwnChars()
    Send({
        t = "D",
        id = private.db.syncId,
        key = key,
        btag = battleTag,
        display = (UnitName("player")),
        chars = chars,
        hash = private.HashPayload(key, chars),
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
    if sender == private.GetPlayerName() then return true end
    return lib.GetLinkedCharacters(private.SELF_BTAG)[sender] ~= nil
end

---@param keep boolean? -- add to what is known instead of starting over (senders seen in guild chat stay)
local function UpdateRoster(keep)
    if not keep then
        wipe(roster)
    end
    for index = 1, GetNumGuildMembers() do
        local name = GetGuildRosterInfo(index)
        if name and private.IsReadable(name) then
            roster[private.FullName(name)] = true
        end
    end
end

function Comm:OnCommReceived(prefix, text, distribution, sender)
    if prefix ~= PREFIX or not IsActive() then return end
    if not (private.IsReadable(text) and private.IsReadable(sender)) then return end
    if type(text) ~= "string" or #text > variables.maxMessageLength or type(sender) ~= "string" then return end
    if distribution ~= "GUILD" and distribution ~= "WHISPER" then return end
    sender = private.FullName(sender)
    if IsOwnCharacter(sender) then return end
    if distribution == "GUILD" then
        -- the server only delivers guild messages from members, the roster may not be loaded yet
        roster[sender] = true
    elseif not roster[sender] then
        UpdateRoster(true)
        if not roster[sender] then return end
    end

    local message = Decode(text)
    if not message or message.v ~= PROTOCOL then return end

    if message.t == "H" then
        if message.q then
            AnswerQuery(sender)
        end
        if type(message.id) == "string" and type(message.hash) == "string" and private.Sync.WantsData(message.id, message.hash) then
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
