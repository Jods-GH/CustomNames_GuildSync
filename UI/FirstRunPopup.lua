local appName, app = ...
---@class CustomNamesGuildSyncPrivate
local private = app
local lib = LibStub("CustomNames")
local AceGUI = LibStub("AceGUI-3.0")

-- Asks once per account how the own characters are shared. Until it is answered nothing is sent or received.
-- Built from the widgets of CustomNames instead of StaticPopupDialogs, so the recommended choice can stand out
-- and the popup system of the game is never touched by this addon
local variables = {
    width = 520,
    height = 290,
    padding = 20,
}

local dialog ---@type table?

---@param share boolean
---@param shareBattleTag boolean
local function Configure(share, shareBattleTag)
    local db = private.db
    db.configured = true
    db.share = share
    db.shareBattleTag = shareBattleTag
    private.Comm.Start()
    lib.RefreshWindow()
end

local function CloseDialog()
    -- widgets can't be released from inside their own callbacks
    C_Timer.After(0, function()
        if dialog then
            dialog:Hide()
        end
    end)
end

---@param parent table
---@param textKey string
---@param variant string
---@param share boolean
---@param shareBattleTag boolean
local function AddChoice(parent, textKey, variant, share, shareBattleTag)
    local button = AceGUI:Create("CustomNames-Button")
    button:SetVariant(variant)
    button:SetText(private.getLocalisation(textKey))
    button:SetCallback("OnClick", function()
        Configure(share, shareBattleTag)
        CloseDialog()
    end)
    parent:AddChild(button)
end

---@param parent table
local function AddSpacer(parent)
    local spacer = AceGUI:Create("Label")
    spacer:SetUserData("flex", 1)
    parent:AddChild(spacer)
end

---Shows the popup if the user hasn't answered it yet. Closing it without a choice is not an answer, it comes back next login
private.ShowSetupPopup = function()
    if private.db.configured or private.outdated or private.unsupported or dialog then return end
    local Theme = lib.GetUIToolkit().Theme

    dialog = AceGUI:Create("CustomNames-Window")
    dialog:SetTitle(private.getLocalisation("PopupTitle"))
    dialog:EnableResize(false)
    dialog:SetMinSize(variables.width, variables.height)
    dialog:SetWidth(variables.width)
    dialog:SetHeight(variables.height)
    dialog:SetLayout("CustomNames-Dock")
    dialog:SetCallback("OnClose", function(widget)
        dialog = nil
        AceGUI:Release(widget)
    end)
    dialog:PauseLayout()

    local body = AceGUI:Create("CustomNames-Pane")
    body:SetLayout("CustomNames-Dock")
    body:SetAutoAdjustHeight(false)
    body:SetPadding(variables.padding)
    body:SetUserData("dock", "FILL")
    dialog:AddChild(body)

    -- the buttons are docked to the bottom first, the text takes what is left
    local choices = AceGUI:Create("CustomNames-Pane")
    choices:SetLayout("CustomNames-Columns")
    choices:SetUserData("dock", "BOTTOM")
    AddSpacer(choices)
    AddChoice(choices, "PopupShareAnonymous", "ghost", true, false)
    AddChoice(choices, "PopupShareBattleTag", "primary", true, true)
    AddChoice(choices, "PopupReceiveOnly", "ghost", false, false)
    AddSpacer(choices)
    body:AddChild(choices)

    local text = AceGUI:Create("Label")
    text:SetFontObject(Theme.fonts.body)
    text:SetText(private.getLocalisation("PopupSetup"))
    text:SetUserData("dock", "TOP")
    body:AddChild(text)

    dialog:ResumeLayout()
    dialog:DoLayout()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_GUILD_UPDATE")
frame:SetScript("OnEvent", function(self)
    private.OnReady(function()
        if private.db.configured or private.outdated or private.unsupported then
            self:UnregisterAllEvents()
            return
        end
        -- without a guild there is nobody to share with, the popup waits until there is one
        if IsInGuild() then
            self:UnregisterAllEvents()
            private.ShowSetupPopup()
        end
    end)
end)
