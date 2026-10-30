local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local AceLocale = LibStub("AceLocale-3.0")

local L = AceLocale:NewLocale(appName, "enUS", true)

if L then
    -- chat output
    L["ChatPrefix"] = "|cff00aeffCustomNames|r: "
    L["ChatPending"] = "%s wants to share %d characters with you. Type /cn and open the Guild tab to accept or decline."
    L["ChatPendingChange"] = "%s changed the characters they share (%d new, %d removed). Type /cn and open the Guild tab to review."
    L["ChatPendingName"] = "%s now shares the name \"%s\". Type /cn and open the Guild tab to review."
    L["ChatAutoApplied"] = "Applied the characters %s shares with you (trusted)."
    L["ChatNicknamePending"] = "%s shares the nickname \"%s\" through Northern Sky Raid Tools. Type /cn and open the Guild tab to accept or decline."
    L["ChatNicknameAutoApplied"] = "Applied the nickname %s shares (trusted): \"%s\"."
    L["ChatUnsupported"] = "Guild sync is not available on this game version."
    L["ChatOutdated"] = "CustomNames_GuildSync needs a newer version of CustomNames, please update it."

    -- first run popup
    L["PopupTitle"] = "CustomNames Guild Sync"
    L["PopupSetup"] = "Share your characters with guildmates that also use CustomNames_GuildSync? They have to accept them before they are saved.\n\nWith your BattleTag they merge with what Battle.net friends see, anonymously only an account id is sent.\n\nYou can change this later in the Guild tab of /cn."
    L["PopupShareBattleTag"] = "Share with BattleTag"
    L["PopupShareAnonymous"] = "Share anonymously"
    L["PopupReceiveOnly"] = "Receive only"

    -- list
    L["You"] = "You"
    L["SharingOff"] = "Receive only"
    L["SharingBattleTag"] = "Shared with BattleTag"
    L["SharingAnonymous"] = "Shared anonymously"
    L["SharingWithName"] = "%s, with your name"
    L["NotConfigured"] = "Not set up yet"
    L["Changes"] = "%d changes"
    L["NewAccount"] = "New"
    L["NicknameChanged"] = "Changed"
    L["Blocked"] = "Blocked"
    L["NotSet"] = "Not set"
    L["CharacterCount"] = "%d characters"
    L["CharacterCountOne"] = "1 character"
    L["AccountsCount"] = "%d guildmates"
    L["PendingCount"] = "%d guildmates, %d waiting for you"
    L["SyncNow"] = "Sync now"
    L["SyncSent"] = "Asked your guild for their characters"
    L["SyncLockdown"] = "Addon messages are blocked right now, the sync is sent as soon as possible"
    L["DetailEmpty"] = "Select a guildmate on the left.\n\nGuildmates that run CustomNames_GuildSync show up here once they share their characters."

    -- own account
    L["OwnTitle"] = "Your characters"
    L["OwnCaption"] = "What your guild receives"
    L["SetupFirst"] = "Choose how you want to share your characters first."
    L["SetupButton"] = "Set up guild sync"
    L["ShareToggle"] = "Share my characters with my guild"
    L["ShareBattleTagToggle"] = "Share my BattleTag (merges with Battle.net friends)"
    L["NoBattleTag"] = "Your BattleTag is not available right now, an anonymous id is shared instead."
    L["ShareNameToggle"] = "Share my custom name (also with Northern Sky Raid Tools users)"
    L["ShareNameHint"] = "Guildmates are offered \"%s\" as the name of your account."
    L["NoOwnName"] = "You haven't given yourself a custom name yet, set one for yourself in CustomNames."
    L["SharedCharacters"] = "Shared characters"
    L["ReceiveOnlyHint"] = "Nothing is sent. Characters your guildmates share are still offered to you."

    -- guildmate
    L["KindAnonymous"] = "Guildmate · anonymous account"
    L["KindBattleTag"] = "Guildmate · %s"
    L["SharedBy"] = "Last shared by %s"
    L["CustomNameLabel"] = "Custom name"
    L["EnterToSave"] = "Press Enter to save"
    L["Saved"] = "Saved"
    L["ErrorCustomNameMissing"] = "Enter a custom name first."
    L["PendingTitle"] = "Waiting for you"
    L["PendingGroupAdded"] = "New"
    L["PendingGroupRemoved"] = "Removed"
    L["PendingGroupConflicts"] = "Skipped, already linked to another account"
    L["PendingMoved"] = "Now shared under a different account id, the %d characters you accepted move with it."
    L["PendingName"] = "Shares the name \"%s\". A custom name you set yourself is kept."
    L["PendingNameRemoved"] = "Doesn't share a name anymore."
    L["SuggestedName"] = "Shares the name \"%s\""
    L["UseSuggestedName"] = "Use it"
    L["KindNickname"] = "Guildmate · Northern Sky Raid Tools nickname"
    L["NicknameLabel"] = "Nickname"
    L["NicknameRemoved"] = "Doesn't share a nickname anymore."
    L["NicknameKept"] = "You set \"%s\" yourself, accepting won't change it."
    L["Accept"] = "Accept"
    L["AcceptTrust"] = "Accept & trust"
    L["Decline"] = "Decline"
    L["Block"] = "Block"
    L["Unblock"] = "Unblock"
    L["Forget"] = "Forget"
    L["TrustToggle"] = "Trust this guildmate (apply future changes without asking)"
    L["LinkedCharacters"] = "Linked characters"
    L["NoLinkedCharacters"] = "Nothing accepted yet."
    L["CharacterRemoved"] = "%s removed, it won't be offered again"
    L["BlockedHint"] = "Everything this guildmate sends is ignored."
    L["StatusAccepted"] = "Characters of %s saved"
    L["StatusDeclined"] = "Declined"
    L["StatusBlocked"] = "%s is blocked"
    L["StatusForgotten"] = "%s was forgotten"

    private.localisation = L
end
