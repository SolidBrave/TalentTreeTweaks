local _, TTT = ...;
--- @type TalentTreeTweaks_Main
local Main = TTT.Main;

local Module = Main:NewModule('ImportIntoCurrentLoadout', 'AceHook-3.0');

local LOADOUT_SERIALIZATION_VERSION;
function Module:OnInitialize()
    LOADOUT_SERIALIZATION_VERSION = C_Traits.GetLoadoutSerializationVersion and C_Traits.GetLoadoutSerializationVersion() or 1;

    StaticPopupDialogs["TALENT_TREE_TWEAKS_LOADOUT_IMPORT_ERROR_DIALOG"] = {
        text = "%s",
        button1 = OKAY,
        button2 = nil,
        timeout = 0,
        OnAccept = function() end,
        OnCancel = function() end,
        whileDead = 1,
        hideOnEscape = 1,
    };
end

function Module:OnEnable()
    EventUtil.ContinueOnAddOnLoaded('Blizzard_ClassTalentUI', function()
        self:SetupHook();
    end);
end

function Module:OnDisable()
    self:UnhookAll()
    if self.checkbox then
        self.checkbox:Hide();
        ClassTalentLoadoutImportDialog.NameControl:SetShown(true);
        ClassTalentLoadoutImportDialog:UpdateAcceptButtonEnabledState();
    end
end

function Module:GetDescription()
    return 'Allows you to import talent loadouts into the currently selected loadout.';
end

function Module:GetName()
    return 'Import into current loadout';
end

function Module:GetOptions(defaultOptionsTable, db)
    self.db = db;
    defaultOptionsTable.args.importIntoCurrentLoadoutCheckedByDefault = {
        type = 'toggle',
        name = 'Import into current loadout by default',
        desc = 'When enabled, the "Import into current loadout" checkbox will be checked by default.',
        width = 'double',
        get = function() return db.defaultCheckboxState; end,
        set = function(_, value)
            db.defaultCheckboxState = value;
            if self.checkbox then
                self.checkbox:SetChecked(value);
                self:OnCheckboxClick(self.checkbox);
            end
        end,
    };

    return defaultOptionsTable;
end

function Module:SetupHook()
    local dialog = ClassTalentLoadoutImportDialog;
    self:CreateCheckbox(dialog);
    self.checkbox:SetChecked(self.db.defaultCheckboxState);
    self:OnCheckboxClick(self.checkbox);

    self:RawHookScript(dialog.AcceptButton, 'OnClick', function(acceptButton, button, down)
        local importString = dialog.ImportControl:GetText();

        if self.checkbox:GetChecked() then
            if self:ImportLoadout(importString) then
                ClassTalentLoadoutImportDialog:OnCancel();
            end
        else
            self.hooks[acceptButton].OnClick(acceptButton, button, down);
        end
    end);
end

function Module:OnCheckboxClick(checkbox)
    local dialog = checkbox:GetParent();
    dialog.NameControl:SetShown(not checkbox:GetChecked());
    dialog.NameControl:SetText(checkbox:GetChecked() and 'TalentTreeTweaks' or '');
    dialog:UpdateAcceptButtonEnabledState();
end

function Module:CreateCheckbox(dialog)
    if self.checkbox then
        self.checkbox:Show();
        return
    end

    local checkbox = CreateFrame('CheckButton', nil, dialog, 'UICheckButtonTemplate');
    checkbox:SetPoint('TOPLEFT', dialog.NameControl, 'BOTTOMLEFT', 0, 5);
    checkbox:SetSize(24, 24);
    checkbox:SetScript('OnClick', function(cb) self:OnCheckboxClick(cb); end);
    checkbox:SetScript('OnEnter', function(self)
        GameTooltip:SetOwner(self, 'ANCHOR_RIGHT');
        GameTooltip:SetText('Import into current loadout');
        GameTooltip:AddLine('If checked, the imported build will be imported into the currently selected loadout.', 1, 1, 1);
        GameTooltip:Show();
    end);
    checkbox:SetScript('OnLeave', function()
        GameTooltip:Hide();
    end);
    checkbox.text = checkbox:CreateFontString(nil, 'ARTWORK', 'GameFontNormal');
    checkbox.text:SetPoint('LEFT', checkbox, 'RIGHT', 0, 1);
    checkbox.text:SetText('Import into current loadout');
    checkbox:SetHitRectInsets(-10, -checkbox.text:GetStringWidth(), -5, 0);

    self.checkbox = checkbox;
end

function Module:GetTreeID()
    local configInfo = C_Traits.GetConfigInfo(C_ClassTalents.GetActiveConfigID());

    return configInfo and configInfo.treeIDs and configInfo.treeIDs[1];
end

function Module:PurchaseLoadoutEntryInfo(configID, loadoutEntryInfo)
    local removed = 0
    for i, nodeEntry in pairs(loadoutEntryInfo) do
        local success = false
        if nodeEntry.selectionEntryID then
            success = C_Traits.SetSelection(configID, nodeEntry.nodeID, nodeEntry.selectionEntryID);
        elseif nodeEntry.ranksPurchased then
            for rank = 1, nodeEntry.ranksPurchased do
                success = C_Traits.PurchaseRank(configID, nodeEntry.nodeID);
            end
        end
        if success then
            removed = removed + 1
            loadoutEntryInfo[i] = nil
        end
    end

    return removed
end

function Module:DoImport(loadoutEntryInfo)
    local configID = C_ClassTalents.GetActiveConfigID()
    if not configID then
        return false;
    end
    C_Traits.ResetTree(configID, self:GetTreeID());
    while(true) do
        local removed = self:PurchaseLoadoutEntryInfo(configID, loadoutEntryInfo);
        if(removed == 0) then
            break;
        end
    end

    -- just simulate pressing Apply Changes, this will be the cleanest user experience in the end
    ClassTalentFrame.TalentsTab:ApplyConfig();

    return true;
end


----- copied and adapted from Blizzard_ClassTalentImportExport.lua -----
function Module:ShowImportError(errorString)
    StaticPopup_Show("TALENT_TREE_TWEAKS_LOADOUT_IMPORT_ERROR_DIALOG", errorString);
end

function Module:ImportLoadout(importText)
    local ImportExportMixin = ClassTalentImportExportMixin;

    local importStream = ExportUtil.MakeImportDataStream(importText);

    local headerValid, serializationVersion, specID, treeHash = ImportExportMixin:ReadLoadoutHeader(importStream);

    if(not headerValid) then
        self:ShowImportError(LOADOUT_ERROR_BAD_STRING);
        return false;
    end

    if(serializationVersion ~= LOADOUT_SERIALIZATION_VERSION) then
        self:ShowImportError(LOADOUT_ERROR_SERIALIZATION_VERSION_MISMATCH);
        return false;
    end

    if(specID ~= PlayerUtil.GetCurrentSpecID()) then
        self:ShowImportError(LOADOUT_ERROR_WRONG_SPEC);
        return false;
    end

    local treeID = self:GetTreeID();
    if not ImportExportMixin:IsHashEmpty(treeHash) then
        -- allow third-party sites to generate loadout strings with an empty tree hash, which bypasses hash validation
        if not ImportExportMixin:HashEquals(treeHash, C_Traits.GetTreeHash(treeID)) then
            self:ShowImportError(LOADOUT_ERROR_TREE_CHANGED);
            return false;
        end
    end

    local loadoutContent = ImportExportMixin:ReadLoadoutContent(importStream, treeID);
    local loadoutEntryInfo = self:ConvertToImportLoadoutEntryInfo(treeID, loadoutContent);

    return self:DoImport(loadoutEntryInfo);
end

-- converts from compact bit-packing format to LoadoutEntryInfo format to pass to ImportLoadout API
function Module:ConvertToImportLoadoutEntryInfo(treeID, loadoutContent)
    local results = {};
    local treeNodes = C_Traits.GetTreeNodes(treeID);
    local configID = C_ClassTalents.GetActiveConfigID();
    local count = 1;
    for i, treeNodeID in ipairs(treeNodes) do

        local indexInfo = loadoutContent[i];

        if (indexInfo.isNodeSelected) then
            local treeNode = C_Traits.GetNodeInfo(configID, treeNodeID);
            local result = {};
            result.nodeID = treeNode.ID;
            result.ranksPurchased = indexInfo.isPartiallyRanked and indexInfo.partialRanksPurchased or treeNode.maxRanks;
            -- minor change from default UI, only add in case of choice nodes
            result.selectionEntryID = indexInfo.isChoiceNode and treeNode.entryIDs[indexInfo.choiceNodeSelection] or nil;
            results[count] = result;
            count = count + 1;
        end

    end

    return results;
end