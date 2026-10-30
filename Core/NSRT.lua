local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local lib = LibStub("CustomNames")
local Comm = private.Comm

-- Speaks the nickname messages of Northern Sky Raid Tools (NSRT), so guildmates that only run NSRT can be named
-- and see the own name. NSRT doesn't have to be installed for this.
-- Messages are { event, args } serialized to CBOR, deflated and url safe base64 encoded, sent on the prefix NSI_MSG:
-- { event = "NSI_NICKNAMES_COMMS", args = { n = 6, unitID, nickname, name, realm, requestback, channel } }
-- A nickname becomes the custom name of that one character, the user accepts it like the characters of an account
local PREFIX = "NSI_MSG"
local EVENT = "NSI_NICKNAMES_COMMS"
local ADDON = "NorthernSkyRaidTools"
local variables = {
    maxMessageLength = 2000,
    replyCooldown = 60, -- seconds between two answers to nicknames of guildmates
}

---@class CustomNamesGuildSyncNSRT
local NSRT = {}
private.NSRT = NSRT
private.NSRT_BLOCK_PREFIX = "nsrt:" -- followed by Name-Realm, nicknames are blocked in db.blocked next to accounts

local supported = not private.unsupported and Enum.Base64Variant ~= nil and Enum.CompressionMethod ~= nil and Enum.CompressionLevel ~= nil
local sentNickname -- what NSRT users got from us this session
local lastReply = 0

---@param text string
---@return table? payload -- nil if the text is not a nickname message of NSRT
local function Decode(text)
    local success, payload = pcall(function()
        local data = C_EncodingUtil.DecodeBase64(text, Enum.Base64Variant.StandardUrlSafe)
        data = C_EncodingUtil.DecompressString(data, Enum.CompressionMethod.Deflate)
        return C_EncodingUtil.DeserializeCBOR(data)
    end)
    if not success or type(payload) ~= "table" or payload.event ~= EVENT or type(payload.args) ~= "table" then return nil end
    return payload
end

---@param payload table
---@return string text
local function Encode(payload)
    local data = C_EncodingUtil.SerializeCBOR(payload)
    data = C_EncodingUtil.CompressString(data, Enum.CompressionMethod.Deflate, Enum.CompressionLevel.OptimizeForSize)
    return C_EncodingUtil.EncodeBase64(data, Enum.Base64Variant.StandardUrlSafe)
end

---@return boolean loaded -- NSRT sends its own nickname then, ours would fight with it
local function IsNSRTLoaded()
    local IsLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    return IsLoaded ~= nil and IsLoaded(ADDON) and true or false
end

local function Changed()
    lib.RefreshWindow()
end

---@param charname string
---@return string? customName -- set directly on the character in CustomNames
local function GetCharName(charname)
    return lib.GetCharList()[charname]
end

---@param charname string
---@return boolean blocked
NSRT.IsBlocked = function(charname)
    return private.db.blocked[private.NSRT_BLOCK_PREFIX .. charname] ~= nil
end

---Sends the shared own name to the guild, or that there is none anymore
NSRT.SendNickName = function()
    if not supported or not Comm.IsActive() or IsNSRTLoaded() then return end
    local shortName, fullName = private.GetPlayerShortName(), private.GetPlayerName()
    if not shortName or not fullName then return end
    local nickname = private.GetSharedName()
    if not nickname and not sentNickname then return end
    nickname = nickname or ""
    local raidIndex = UnitInRaid("player")
    local unitID = raidIndex and ("raid" .. raidIndex) or shortName
    local realm = fullName:sub(#shortName + 2)
    local text = Encode({ event = EVENT, args = { n = 6, unitID, nickname, shortName, realm, false, "GUILD" } })
    Comm.SendText(PREFIX, "N", text, "GUILD")
    sentNickname = nickname ~= "" and nickname or nil
end

---@param charname string
---@return boolean covered -- the character belongs to a synced account that shares its name
local function IsNamedBySync(charname)
    for _, account in pairs(private.db.accounts) do
        if account.name and account.accepted[charname] then
            return true
        end
    end
    return false
end

---Writes the nickname that waits for the user into CustomNames
---@param charname string
---@param trust boolean? -- also trust the guildmate from now on
NSRT.Accept = function(charname, trust)
    local entry = private.db.nicknames[charname]
    if not entry or entry.offer == nil then return end
    local nickname = entry.offer or nil
    local customName = GetCharName(charname)
    -- a name the user set themself stays, the nickname is only suggested then
    if (nickname or customName) and (not customName or customName == entry.nickname) then
        lib.Set(charname, nickname)
    end
    entry.nickname = nickname
    entry.offer = nil
    entry.declined = nil
    if trust then
        entry.trusted = true
    end
    if not entry.nickname and not entry.trusted then
        private.db.nicknames[charname] = nil
    end
    Changed()
end

---@param charname string
NSRT.Decline = function(charname)
    local entry = private.db.nicknames[charname]
    if not entry or entry.offer == nil then return end
    entry.declined = entry.offer
    entry.offer = nil
    Changed()
end

---Ignores every nickname of the character from now on, what was accepted before stays
---@param charname string
NSRT.Block = function(charname)
    local db = private.db
    db.blocked[private.NSRT_BLOCK_PREFIX .. charname] = { display = charname, sender = charname }
    local entry = db.nicknames[charname]
    if entry then
        entry.offer = nil
        entry.trusted = false
    end
    Changed()
end

---@param charname string
---@param trusted boolean
NSRT.SetTrusted = function(charname, trusted)
    local entry = private.db.nicknames[charname]
    if not entry then return end
    entry.trusted = trusted and true or false
    if trusted and entry.offer ~= nil then
        NSRT.Accept(charname)
    else
        Changed()
    end
end

---Removes the accepted nickname of a character
---@param charname string
NSRT.Forget = function(charname)
    local entry = private.db.nicknames[charname]
    if entry and entry.nickname and GetCharName(charname) == entry.nickname then
        lib.Set(charname)
    end
    private.db.nicknames[charname] = nil
    Changed()
end

---Uses the nickname as the custom name of the character, replacing what the user set
---@param charname string
NSRT.UseNickname = function(charname)
    local entry = private.db.nicknames[charname]
    if not entry or not entry.nickname then return end
    lib.Set(charname, entry.nickname)
    Changed()
end

---@param charname string -- Name-Realm, checked to be the sender
---@param value any -- nickname as it was sent, "" if it was removed
local function OnNickname(charname, value)
    local db = private.db
    if NSRT.IsBlocked(charname) or IsNamedBySync(charname) then return end
    local nickname = private.SanitizeName(value, private.MAX_NAME_CHARS)
    local entry = db.nicknames[charname]
    if not entry then
        if not nickname then return end
        entry = { trusted = false }
        db.nicknames[charname] = entry
    end
    local offer = nickname or false
    if nickname == entry.nickname then
        -- the guildmate went back to what was accepted, nothing waits anymore
        if entry.offer ~= nil then
            entry.offer = nil
            Changed()
        end
        return
    end
    if entry.offer == offer or entry.declined == offer then return end
    entry.offer = offer
    entry.lastSeen = time()
    if entry.trusted then
        NSRT.Accept(charname)
        if nickname then
            private.Print(private.getLocalisation("ChatNicknameAutoApplied"):format(charname, nickname))
        end
        return
    end
    if nickname then
        private.Print(private.getLocalisation("ChatNicknamePending"):format(charname, nickname))
    end
    Changed()
end

---@param prefix string
---@param text string
---@param distribution string
---@param sender string
local function OnMessage(prefix, text, distribution, sender)
    -- secret values raise an error on comparisons, so every argument is checked before anything else
    if not (private.IsReadable(prefix) and private.IsReadable(text) and private.IsReadable(distribution) and private.IsReadable(sender)) then return end
    if prefix ~= PREFIX or distribution ~= "GUILD" or not Comm.IsActive() then return end
    if type(text) ~= "string" or #text > variables.maxMessageLength or type(sender) ~= "string" then return end
    if text:find("[^%w_%-=]") then return end
    sender = private.FullName(sender)
    if Comm.IsOwnCharacter(sender) or not Comm.IsGuildMember(sender, distribution) then return end

    local payload = Decode(text)
    if not payload then return end
    local nickname, name, realm = payload.args[2], payload.args[3], payload.args[4]
    if type(nickname) ~= "string" or type(name) ~= "string" or type(realm) ~= "string" then return end
    -- NSRT believes whoever the message says it is from, only the sender may name itself here
    if private.FullName(name .. "-" .. realm) ~= sender then return end
    OnNickname(sender, nickname)

    -- the guildmate probably just logged in and missed our nickname
    local now = GetTime()
    if now - lastReply > variables.replyCooldown then
        lastReply = now
        NSRT.SendNickName()
    end
end

if supported then
    private.OnReady(function()
        Comm:RegisterComm(PREFIX, OnMessage)
    end)
end
