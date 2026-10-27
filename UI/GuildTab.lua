local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local lib = LibStub("CustomNames")
local Sync = private.Sync

-- Fills the guild tab of the CustomNames window. CustomNames owns the window and hands over the list,
-- the right side (through the toolkit of lib.GetUIToolkit) and the footer
local KEY_YOU = "GuildSync:you"
local KEY_BLOCKED = "GuildSync:blocked:" -- followed by the sync id
local variables = {
    separator = " · ",
}

local pendingNotice -- { key = string, text = string } shown once the detail of that key gets rebuilt

if not (lib.RegisterTabProvider and lib.RemoveCharFromBtag and lib.GetUIToolkit) then
    private.outdated = true
    C_Timer.After(5, function()
        private.Print(private.getLocalisation("ChatOutdated"))
    end)
    return
end

---@param key string? -- custom name key of CustomNames, or one of the keys above
---@return string? syncId
---@return string? kind -- "you", "pending", "account" or "blocked"
local function ResolveKey(key)
    if not key then return nil end
    if key == KEY_YOU then return nil, "you" end
    if key:sub(1, #KEY_BLOCKED) == KEY_BLOCKED then
        return key:sub(#KEY_BLOCKED + 1), "blocked"
    end
    local db = private.db
    for syncId, payload in pairs(db.pending) do
        local account = db.accounts[syncId]
        if (account and account.key or payload.key) == key then
            return syncId, "pending"
        end
    end
    local syncId = Sync.FindByKey(key)
    if syncId then return syncId, "account" end
    return nil
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

local function MatchesSearch(search, ...)
    if search == "" then return true end
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if value and tostring(value):lower():find(search, 1, true) then
            return true
        end
    end
    return false
end

---@param search string
---@param chars table? -- list or set of Name-Realm
---@return boolean
local function CharsMatch(search, chars)
    if not chars or search == "" then return false end
    for key, value in pairs(chars) do
        local charname = type(key) == "string" and key or value
        if charname:lower():find(search, 1, true) then
            return true
        end
    end
    return false
end

---@return string text -- how the own characters are shared right now
local function GetSharingText()
    local db = private.db
    if not db.configured then
        return private.getLocalisation("NotConfigured")
    elseif not db.share then
        return private.getLocalisation("SharingOff")
    end
    local _, battleTag = private.GetOwnKey()
    return private.getLocalisation(battleTag and "SharingBattleTag" or "SharingAnonymous")
end

local provider = {}

---@param search string -- trimmed and lowercased
---@return table items
---@return string countText
provider.GetItems = function(search)
    local db = private.db
    local Theme = lib.GetUIToolkit().Theme
    local items = {}
    local ownChars = private.GetOwnChars()
    if MatchesSearch(search, private.getLocalisation("You")) or CharsMatch(search, ownChars) then
        table.insert(items, {
            key = KEY_YOU,
            title = private.getLocalisation("You"),
            subtitle = GetSharingText(),
            value = db.share and db.configured and private.FormatCharacterCount(#ownChars) or nil,
        })
    end

    local pendingItems, accountItems, blockedItems = {}, {}, {}
    local pendingCount, accountCount = 0, 0
    for syncId, payload in pairs(db.pending) do
        pendingCount = pendingCount + 1
        local account = db.accounts[syncId]
        local key = account and account.key or payload.key
        if MatchesSearch(search, payload.display, key, GetCustomName(key)) or CharsMatch(search, payload.chars) then
            local diff = Sync.GetDiff(syncId)
            local changes = #diff.added + #diff.removed + #diff.conflicts
            table.insert(pendingItems, {
                key = key,
                title = payload.display,
                subtitle = GetCustomName(key) or payload.sender,
                value = account and private.getLocalisation("Changes"):format(changes) or private.getLocalisation("NewAccount"),
                valueColor = Theme.colors.accent,
            })
        end
    end
    for syncId, account in pairs(db.accounts) do
        if not db.pending[syncId] and not db.blocked[syncId] then
            accountCount = accountCount + 1
            local customName = GetCustomName(account.key)
            if MatchesSearch(search, account.display, account.key, customName) or CharsMatch(search, account.accepted) then
                local count = 0
                for _ in pairs(account.accepted) do
                    count = count + 1
                end
                table.insert(accountItems, {
                    key = account.key,
                    title = account.display or account.key,
                    subtitle = private.FormatCharacterCount(count),
                    value = customName or private.getLocalisation("NotSet"),
                    valueColor = not customName and Theme.colors.disabled or nil,
                })
            end
        end
    end
    for syncId, info in pairs(db.blocked) do
        if MatchesSearch(search, info.display, info.sender) then
            table.insert(blockedItems, {
                key = KEY_BLOCKED .. syncId,
                title = info.display or syncId,
                subtitle = info.sender,
                value = private.getLocalisation("Blocked"),
                valueColor = Theme.colors.disabled,
            })
        end
    end

    local function ByTitle(a, b)
        return a.title:lower() < b.title:lower()
    end
    for _, group in ipairs({ pendingItems, accountItems, blockedItems }) do
        table.sort(group, ByTitle)
        for _, item in ipairs(group) do
            table.insert(items, item)
        end
    end

    local countText
    if pendingCount > 0 then
        countText = private.getLocalisation("PendingCount"):format(accountCount + pendingCount, pendingCount)
    else
        countText = private.getLocalisation("AccountsCount"):format(accountCount)
    end
    return items, countText
end

---@param ui table -- toolkit of CustomNames
local function ShowYou(ui)
    local db = private.db
    local Theme, margins = ui.Theme, ui.margins
    ui.Begin("guild:you")
    ui.AddHeader(private.getLocalisation("OwnTitle"), private.getLocalisation("OwnCaption"))

    if not db.configured then
        ui.Add(ui.CreateLabel(private.getLocalisation("SetupFirst"), "body", Theme.colors.muted), margins.fieldMargin)
        local line = ui.CreateLine()
        line:AddChild(ui.CreateButton(private.getLocalisation("SetupButton"), "primary", function()
            private.ShowSetupPopup()
        end))
        ui.Add(line, margins.groupMargin)
        ui.Finish()
        return
    end

    ui.Add(ui.CreateToggle(private.getLocalisation("ShareToggle"), db.share, function(value)
        db.share = value
        private.Comm.BroadcastHello()
        ui.Refresh(true)
    end), margins.fieldMargin)

    if not db.share then
        ui.Add(ui.CreateLabel(private.getLocalisation("ReceiveOnlyHint"), "small", Theme.colors.muted), margins.noticeMargin)
        ui.Finish()
        return
    end

    ui.Add(ui.CreateToggle(private.getLocalisation("ShareBattleTagToggle"), db.shareBattleTag, function(value)
        db.shareBattleTag = value
        private.Comm.BroadcastHello()
        ui.Refresh(true)
    end), margins.noticeMargin)
    if db.shareBattleTag and not private.GetOwnBattleTag() then
        ui.Add(ui.CreateLabel(private.getLocalisation("NoBattleTag"), "small", Theme.colors.muted), margins.noticeMargin)
    end

    ui.Add(ui.CreateCaption(private.getLocalisation("SharedCharacters")), margins.sectionMargin)
    ui.AddCharacterGrid(private.GetOwnChars())
    ui.Finish()
end

---@param ui table
---@param groups table -- groups of the character grid that are filled
---@param chars table -- sorted list of Name-Realm
---@param titleKey string -- localisation key of the heading
---@param color table
local function AddDiffGroup(ui, groups, chars, titleKey, color)
    if #chars == 0 then return end
    local items = {}
    for index, charname in ipairs(chars) do
        -- the cells are too narrow for long realm names, the tooltip shows the whole name
        local name = ui.SplitCharName(charname)
        items[index] = { text = name, classFile = ui.GetClass(charname), tooltip = charname }
    end
    table.insert(groups, { title = ui.Theme.Colorize(private.getLocalisation(titleKey), color), items = items })
end

---@param ui table
---@param key string
---@param syncId string
---@param isPending boolean
local function ShowAccount(ui, key, syncId, isPending)
    local db = private.db
    local Theme, margins = ui.Theme, ui.margins
    local account = db.accounts[syncId]
    local payload = db.pending[syncId]
    local source = payload or account
    local pending = pendingNotice and pendingNotice.key == key and pendingNotice or nil
    pendingNotice = nil

    ui.Begin("guild:" .. syncId)
    local kind
    if key:sub(1, #private.ANON_PREFIX) == private.ANON_PREFIX then
        kind = private.getLocalisation("KindAnonymous")
    else
        kind = private.getLocalisation("KindBattleTag"):format(key)
    end
    ui.AddHeader(source.display or key, kind)
    if source.sender then
        ui.Add(ui.CreateLabel(private.getLocalisation("SharedBy"):format(source.sender), "small", Theme.colors.muted), margins.noticeMargin)
    end

    -- the custom name is only offered once something was accepted, before that the key holds nothing
    local notice
    if account then
        local customName = GetCustomName(account.key)
        local customNameBox = ui.Add(ui.CreateEditBox(private.getLocalisation("CustomNameLabel"), private.getLocalisation("NotSet")), margins.fieldMargin)
        customNameBox:SetText(customName)
        customNameBox:SetCallback("OnEnterPressed", function(_, _, text)
            local newName = strtrim(text or "")
            if newName == "" then
                ui.SetNotice(notice, private.getLocalisation("ErrorCustomNameMissing"), Theme.colors.danger)
            elseif newName ~= customName then
                lib.Set(account.key, newName)
                pendingNotice = { key = key, text = private.getLocalisation("Saved") }
                ui.Refresh(true)
            end
        end)
        if pending then
            notice = ui.CreateLabel(pending.text, "small", Theme.colors.success)
        else
            notice = ui.CreateLabel(private.getLocalisation("EnterToSave"), "small", Theme.colors.disabled)
        end
        ui.Add(notice, margins.noticeMargin)
    end

    -- docked to the bottom, has to be added before whatever fills the rest
    local bottomLine = ui.CreateLine()
    bottomLine:AddChild(ui.CreateSpacer())
    bottomLine:AddChild(ui.CreateButton(private.getLocalisation("Block"), "danger", function()
        Sync.Block(syncId)
        ui.Refresh(true)
    end))
    if account then
        bottomLine:AddChild(ui.CreateButton(private.getLocalisation("Forget"), "danger", function()
            Sync.Forget(syncId)
            ui.Refresh(true)
        end))
    end
    ui.Add(bottomLine, 0, "BOTTOM")

    if isPending then
        -- the decision stays at the bottom, the changes scroll in between however many characters there are
        local diff = Sync.GetDiff(syncId)
        local line = ui.CreateLine()
        line:AddChild(ui.CreateButton(private.getLocalisation("Accept"), "primary", function()
            Sync.Accept(syncId)
            ui.Refresh(true)
        end))
        line:AddChild(ui.CreateButton(private.getLocalisation("AcceptTrust"), "ghost", function()
            Sync.Accept(syncId, true)
            ui.Refresh(true)
        end))
        line:AddChild(ui.CreateButton(private.getLocalisation("Decline"), "ghost", function()
            Sync.Decline(syncId)
            ui.Refresh(true)
        end))
        ui.Add(line, margins.groupMargin, "BOTTOM")

        ui.Add(ui.CreateCaption(private.getLocalisation("PendingTitle")), margins.sectionMargin)
        if diff.oldKey and diff.moved > 0 then
            ui.Add(ui.CreateLabel(private.getLocalisation("PendingMoved"):format(diff.moved), "small", Theme.colors.text), margins.noticeMargin)
        end
        local groups = {}
        AddDiffGroup(ui, groups, diff.added, "PendingGroupAdded", Theme.colors.success)
        AddDiffGroup(ui, groups, diff.removed, "PendingGroupRemoved", Theme.colors.danger)
        AddDiffGroup(ui, groups, diff.conflicts, "PendingGroupConflicts", Theme.colors.muted)
        ui.AddGrid(groups)
    elseif account then
        ui.Add(ui.CreateToggle(private.getLocalisation("TrustToggle"), account.trusted, function(value)
            Sync.SetTrusted(syncId, value)
            ui.Refresh(true)
        end), margins.sectionMargin)
        ui.Add(ui.CreateCaption(private.getLocalisation("LinkedCharacters")), margins.sectionMargin)
        local chars = private.SortedKeys(account.accepted)
        if #chars == 0 then
            ui.Add(ui.CreateLabel(private.getLocalisation("NoLinkedCharacters"), "small", Theme.colors.muted), margins.noticeMargin)
        else
            ui.AddCharacterGrid(chars, nil, function(charname)
                Sync.RemoveChar(syncId, charname)
                pendingNotice = { key = key, text = private.getLocalisation("CharacterRemoved"):format(charname) }
                ui.Refresh(true)
            end)
        end
    end
    ui.Finish()
end

---@param ui table
---@param syncId string
local function ShowBlocked(ui, syncId)
    local Theme, margins = ui.Theme, ui.margins
    local info = private.db.blocked[syncId] or {}
    ui.Begin("guild:blocked:" .. syncId)
    ui.AddHeader(info.display or syncId, private.getLocalisation("Blocked"))
    ui.Add(ui.CreateLabel(private.getLocalisation("BlockedHint"), "body", Theme.colors.muted), margins.fieldMargin)
    local line = ui.CreateLine()
    line:AddChild(ui.CreateButton(private.getLocalisation("Unblock"), "ghost", function()
        Sync.Unblock(syncId)
        ui.Refresh(true)
    end))
    ui.Add(line, margins.groupMargin)
    ui.Finish()
end

---@param key string
---@param ui table
provider.ShowDetail = function(key, ui)
    local syncId, kind = ResolveKey(key)
    if kind == "you" then
        ShowYou(ui)
    elseif kind == "blocked" then
        ShowBlocked(ui, syncId)
    elseif syncId then
        ShowAccount(ui, key, syncId, kind == "pending")
    else
        provider.ShowEmpty(ui)
    end
end

---@param ui table
provider.ShowEmpty = function(ui)
    ui.Begin("guild:empty")
    local hint = ui.CreateLabel(private.getLocalisation("DetailEmpty"), "body", ui.Theme.colors.muted)
    hint:SetJustifyH("CENTER")
    ui.Add(hint, ui.margins.emptyMargin)
    ui.Finish()
end

---@return table buttons
provider.GetFooterButtons = function()
    return {
        {
            text = private.getLocalisation("SyncNow"),
            variant = "primary",
            onClick = function()
                if not private.db.configured then
                    private.ShowSetupPopup()
                    return
                end
                private.Comm.Start()
                local sent = private.Comm.BroadcastHello(true)
                lib.RefreshWindow()
                private.Print(private.getLocalisation(sent and "SyncSent" or "SyncLockdown"))
            end,
        },
    }
end

---@return number pending -- guildmates that wait for an answer
provider.GetBadge = function()
    local count = 0
    for _ in pairs(private.db.pending) do
        count = count + 1
    end
    return count
end

---@param key string
---@return string? display -- the name an anonymous account is shown with outside of the guild tab
provider.GetAccountDisplay = function(key)
    if key:sub(1, #private.ANON_PREFIX) ~= private.ANON_PREFIX then return nil end
    local _, account = Sync.FindByKey(key)
    return account and account.display or nil
end

private.OnReady(function()
    lib.RegisterTabProvider("guild", provider)
end)
