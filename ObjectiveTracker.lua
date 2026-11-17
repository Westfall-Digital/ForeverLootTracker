-- ForeverLootTracker — Objective Tracker "Watched Loot" accordion for watched items.
-- Only attaches to the shared OT while watches exist. An empty registered module
-- was blocking quest objective updates until the player toggled "All Objectives".
local FLT = ForeverLootTracker

local function DashShow()
	return OBJECTIVE_DASH_STYLE_SHOW or 1
end

local function ColorNormal()
	return (OBJECTIVE_TRACKER_COLOR and OBJECTIVE_TRACKER_COLOR["Normal"]) or nil
end

local function ColorComplete()
	return (OBJECTIVE_TRACKER_COLOR and OBJECTIVE_TRACKER_COLOR["Complete"]) or ColorNormal()
end

local function InCombat()
	return InCombatLockdown and InCombatLockdown()
end

local function HasWatchedItems()
	if not FLT.db or not FLT.db.options or FLT.db.options.showInObjectiveTracker == false then
		return false
	end
	local watched = FLT.GetWatchedList and FLT.GetWatchedList()
	return watched ~= nil and next(watched) ~= nil
end

local function NudgeQuestObjectiveTracker()
	-- After we attach/detach, force Blizzard quest modules to reflow.
	for _, mod in ipairs({
		QuestObjectiveTracker,
		CampaignQuestObjectiveTracker,
		BonusObjectiveTracker,
		WorldQuestObjectiveTracker,
	}) do
		if mod and mod.MarkDirty then
			pcall(mod.MarkDirty, mod)
		end
	end
	if ObjectiveTrackerFrame and ObjectiveTrackerFrame.Update then
		pcall(ObjectiveTrackerFrame.Update, ObjectiveTrackerFrame)
	end
end

function FLT.GetWatchCounts()
	local counts = {}
	local watched = FLT.GetWatchedList and FLT.GetWatchedList()
	if not watched then
		return counts
	end
	for id in pairs(watched) do
		local key = tonumber(id) or id
		counts[key] = 0
	end
	local session = FLT.GetSession and FLT.GetSession()
	if not session then
		return counts
	end
	for _, item in ipairs(session.items or {}) do
		if FLT.IsWatched(item.itemID) then
			local key = tonumber(item.itemID) or item.itemID
			counts[key] = (counts[key] or 0) + (item.count or 1)
		end
	end
	return counts
end

local function BuildMixin()
	if not ObjectiveTrackerModuleMixin then
		return nil
	end

	local mixin = CreateFromMixins(ObjectiveTrackerModuleMixin, {
		headerText = "Watched Loot",
		events = {},
		blockTemplate = "ObjectiveTrackerBlockTemplate",
		lineTemplate = "ObjectiveTrackerLineTemplate",
	})

	function mixin:InitModule()
	end

	-- Default CanUpdate is fine — we unregister when empty instead of returning false.

	function mixin:LayoutContents()
		if not HasWatchedItems() then
			return
		end

		local watched = FLT.GetWatchedList()
		local counts = FLT.GetWatchCounts()
		local entries = {}
		for id, name in pairs(watched) do
			local itemID = tonumber(id) or id
			table.insert(entries, {
				itemID = itemID,
				name = name or ("Item " .. tostring(itemID)),
				count = counts[itemID] or 0,
			})
		end
		table.sort(entries, function(a, b)
			return tostring(a.name) < tostring(b.name)
		end)

		for _, entry in ipairs(entries) do
			local block = self:GetBlock(entry.itemID)
			block:SetHeader(entry.name)

			local text
			local color
			if entry.count > 0 then
				text = ("Looted this session: %d"):format(entry.count)
				color = ColorComplete()
			else
				text = "Waiting for drop..."
				color = ColorNormal()
			end
			block:AddObjective(1, text, nil, nil, DashShow(), color)

			if not self:LayoutBlock(block) then
				return
			end
		end
	end

	function mixin:OnBlockHeaderClick(block, mouseButton)
		local itemID = block and block.id
		if not itemID then
			return
		end
		if InCombat() then
			return
		end
		local name = FLT.GetListValue(FLT.GetWatchedList(), itemID) or ("Item " .. tostring(itemID))

		if mouseButton == "RightButton" then
			if MenuUtil and MenuUtil.CreateContextMenu then
				MenuUtil.CreateContextMenu(self, function(_, rootDescription)
					rootDescription:CreateTitle(tostring(name))
					rootDescription:CreateButton("Open ForeverLootTracker", function()
						if FLT.UI and FLT.UI.Toggle then
							FLT.UI.Toggle()
						end
					end)
					rootDescription:CreateButton("Stop Watching", function()
						if FLT.UI and FLT.UI.ToggleWatch then
							FLT.UI.ToggleWatch(itemID, name)
							if FLT.UI.Refresh then
								FLT.UI.Refresh()
							end
						end
						FLT.RefreshObjectiveTracker()
					end)
				end)
			else
				if FLT.UI and FLT.UI.ToggleWatch then
					FLT.UI.ToggleWatch(itemID, name)
					if FLT.UI.Refresh then
						FLT.UI.Refresh()
					end
				end
				FLT.RefreshObjectiveTracker()
			end
		elseif IsModifiedClick and IsModifiedClick("CHATLINK") then
			local _, link = GetItemInfo(itemID)
			if link and ChatEdit_InsertLink then
				ChatEdit_InsertLink(link)
			end
		else
			if FLT.UI and FLT.UI.Toggle then
				if not (FLT.UI.frame and FLT.UI.frame:IsShown()) then
					FLT.UI.Toggle()
				end
				if FLT.UI.ShowPanel then
					FLT.UI.ShowPanel("watch")
				end
			end
		end
	end

	local baseUpdate = mixin.Update or ObjectiveTrackerModuleMixin.Update
	if baseUpdate then
		function mixin:Update(...)
			if InCombat() then
				FLT.objectiveTrackerPending = true
				if self.GetContentsHeight and self.IsTruncated then
					return self:GetContentsHeight(), self:IsTruncated()
				end
				return 0, false
			end
			return baseUpdate(self, ...)
		end
	end

	return mixin
end

local function TemplateExists(name)
	if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
		local info = C_XMLUtil.GetTemplateInfo(name)
		return info ~= nil
	end
	return true
end

local function EnsureModuleFrame()
	local module = _G.ForeverLootObjectiveTracker
	if module then
		return module
	end
	if not TemplateExists("ObjectiveTrackerModuleTemplate") then
		return nil
	end
	local mixin = BuildMixin()
	if not mixin then
		return nil
	end
	local ok, frame = pcall(CreateFrame, "Frame", "ForeverLootObjectiveTracker", UIParent, "ObjectiveTrackerModuleTemplate")
	if not ok or not frame then
		FLT.Debug("Could not create ObjectiveTrackerModuleTemplate frame: " .. tostring(frame))
		return nil
	end
	Mixin(frame, mixin)
	frame.headerText = "Watched Loot"
	if frame.SetHeader then
		frame:SetHeader("Watched Loot")
	elseif frame.Header and frame.Header.Text then
		frame.Header.Text:SetText("Watched Loot")
	end
	local questOrder = (QuestObjectiveTracker and QuestObjectiveTracker.uiOrder)
		or (CampaignQuestObjectiveTracker and CampaignQuestObjectiveTracker.uiOrder)
		or 5
	frame.uiOrder = questOrder - 0.5
	return frame
end

local function AttachModule()
	if FLT.objectiveTrackerRegistered then
		return true
	end
	if InCombat() then
		return false
	end
	if not ObjectiveTrackerManager or not ObjectiveTrackerFrame then
		return false
	end
	if not ObjectiveTrackerManager.containers or not ObjectiveTrackerManager.containers[ObjectiveTrackerFrame] then
		return false
	end

	local module = EnsureModuleFrame()
	if not module then
		return false
	end

	ObjectiveTrackerManager:SetModuleContainer(module, ObjectiveTrackerFrame)
	FLT.objectiveTrackerRegistered = true
	FLT.Debug("Objective Tracker Watched Loot module attached.")
	return true
end

local function DetachModule()
	local module = _G.ForeverLootObjectiveTracker
	if not module or not FLT.objectiveTrackerRegistered then
		FLT.objectiveTrackerRegistered = false
		return
	end
	if InCombat() then
		FLT.objectiveTrackerPending = true
		return
	end
	-- Leave the container entirely so an empty module can't stall quest updates.
	if ObjectiveTrackerManager and ObjectiveTrackerManager.SetModuleContainer then
		pcall(ObjectiveTrackerManager.SetModuleContainer, ObjectiveTrackerManager, module, nil)
	end
	FLT.objectiveTrackerRegistered = false
	FLT.Debug("Objective Tracker Watched Loot module detached.")
	NudgeQuestObjectiveTracker()
end

function FLT.RefreshObjectiveTracker()
	if InCombat() then
		FLT.objectiveTrackerPending = true
		return
	end

	if HasWatchedItems() then
		if not AttachModule() then
			FLT.objectiveTrackerPending = true
			return
		end
		local module = _G.ForeverLootObjectiveTracker
		if module and module.MarkDirty then
			module:MarkDirty()
		end
	else
		DetachModule()
	end
end

local function FlushPendingObjectiveTracker()
	if not FLT.objectiveTrackerPending then
		return
	end
	if InCombat() then
		return
	end
	FLT.objectiveTrackerPending = false
	FLT.RefreshObjectiveTracker()
end

local function TrySyncObjectiveModule()
	-- Attach only when watches exist; otherwise stay out of the OT.
	if HasWatchedItems() then
		if not AttachModule() then
			return false
		end
		FLT.RefreshObjectiveTracker()
		return true
	end
	if FLT.objectiveTrackerRegistered then
		DetachModule()
	end
	return true
end

local regFrame = CreateFrame("Frame")
regFrame:RegisterEvent("PLAYER_LOGIN")
regFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
regFrame:RegisterEvent("ADDON_LOADED")
regFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
regFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "PLAYER_REGEN_ENABLED" then
		FlushPendingObjectiveTracker()
		return
	end
	if event == "ADDON_LOADED" and arg1 ~= "Blizzard_ObjectiveTracker" then
		return
	end
	-- Wait until SavedVariables / char DB exist before reading watches.
	if not FLT.db then
		return
	end
	TrySyncObjectiveModule()
	if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LOGIN" then
		local tries = 0
		C_Timer.NewTicker(0.5, function(ticker)
			tries = tries + 1
			if (FLT.db and TrySyncObjectiveModule()) or tries >= 30 then
				ticker:Cancel()
			end
		end)
	end
end)
