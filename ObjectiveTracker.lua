-- ForeverLootTracker — Objective Tracker "Watched Loot" accordion for watched items.
-- Mirrors WildStar FSLootTracker's objective-tracker watched-loot panel.
-- Careful with combat/taint: an always-dirty empty module breaks quest OT updates.
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

function FLT.RefreshObjectiveTracker()
	local module = _G.ForeverLootObjectiveTracker
	if not module or not module.MarkDirty then
		return
	end
	-- Avoid thrashing the shared OT when we have nothing to show and already cleared.
	if not HasWatchedItems() and not FLT.objectiveTrackerHadContent then
		return
	end
	if InCombat() then
		FLT.objectiveTrackerPending = true
		return
	end
	module:MarkDirty()
end

local function FlushPendingObjectiveTracker()
	if not FLT.objectiveTrackerPending then
		return
	end
	if InCombat() then
		return
	end
	FLT.objectiveTrackerPending = false
	local module = _G.ForeverLootObjectiveTracker
	if module and module.MarkDirty then
		module:MarkDirty()
	end
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

	function mixin:CanUpdate()
		-- Stay in the layout pass one more time after the last watch is removed
		-- so unused blocks are freed and our header collapses.
		if HasWatchedItems() then
			return true
		end
		return FLT.objectiveTrackerHadContent == true
	end

	function mixin:LayoutContents()
		if not HasWatchedItems() then
			FLT.objectiveTrackerHadContent = false
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

		FLT.objectiveTrackerHadContent = true
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
				-- Prefer ShowPanel — never :Click() a button (taints OT / quest UI).
				if FLT.UI.ShowPanel then
					FLT.UI.ShowPanel("watch")
				end
			end
		end
	end

	-- Defer native layout during combat so we don't taint quest OT updates.
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

local function TryRegisterObjectiveModule()
	if FLT.objectiveTrackerRegistered then
		return true
	end
	if InCombat() then
		return false
	end
	if not ObjectiveTrackerManager or not ObjectiveTrackerFrame then
		return false
	end
	if not ObjectiveTrackerModuleMixin then
		return false
	end
	if not ObjectiveTrackerManager.containers or not ObjectiveTrackerManager.containers[ObjectiveTrackerFrame] then
		return false
	end
	if not TemplateExists("ObjectiveTrackerModuleTemplate") then
		return false
	end

	local mixin = BuildMixin()
	if not mixin then
		return false
	end

	local module = _G.ForeverLootObjectiveTracker
	if not module then
		local ok, frame = pcall(CreateFrame, "Frame", "ForeverLootObjectiveTracker", UIParent, "ObjectiveTrackerModuleTemplate")
		if not ok or not frame then
			FLT.Debug("Could not create ObjectiveTrackerModuleTemplate frame: " .. tostring(frame))
			return false
		end
		module = frame
	end

	Mixin(module, mixin)
	module.headerText = "Watched Loot"
	if module.SetHeader then
		module:SetHeader("Watched Loot")
	elseif module.Header and module.Header.Text then
		module.Header.Text:SetText("Watched Loot")
	end
	-- Lower uiOrder = higher on the tracker. Sit just above Quests.
	local questOrder = (QuestObjectiveTracker and QuestObjectiveTracker.uiOrder)
		or (CampaignQuestObjectiveTracker and CampaignQuestObjectiveTracker.uiOrder)
		or 5
	module.uiOrder = questOrder - 0.5

	ObjectiveTrackerManager:SetModuleContainer(module, ObjectiveTrackerFrame)
	FLT.objectiveTrackerRegistered = true
	FLT.objectiveTrackerHadContent = HasWatchedItems()
	FLT.RefreshObjectiveTracker()
	if FLT.Print and FLT.db and FLT.db.user and FLT.db.user.debug then
		FLT.Debug("Objective Tracker Watched Loot module registered.")
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
		if not FLT.objectiveTrackerRegistered then
			TryRegisterObjectiveModule()
		end
		FlushPendingObjectiveTracker()
		return
	end
	if event == "ADDON_LOADED" and arg1 ~= "Blizzard_ObjectiveTracker" then
		return
	end
	if TryRegisterObjectiveModule() then
		if event ~= "PLAYER_ENTERING_WORLD" then
			-- Keep REGEN + PEW for deferred flushes; drop load churn once registered.
			regFrame:UnregisterEvent("ADDON_LOADED")
			regFrame:UnregisterEvent("PLAYER_LOGIN")
		end
		return
	end
	if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LOGIN" then
		local tries = 0
		C_Timer.NewTicker(0.5, function(ticker)
			tries = tries + 1
			if TryRegisterObjectiveModule() or tries >= 30 then
				ticker:Cancel()
			end
		end)
	end
end)
