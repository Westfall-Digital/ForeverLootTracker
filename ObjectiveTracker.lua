-- ForeverLootTracker — Objective Tracker "Watched Loot" accordion for watched items.
-- Mirrors WildStar FSLootTracker's objective-tracker watched-loot panel.
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
		return true
	end

	function mixin:LayoutContents()
		if not FLT.db or not FLT.db.options or FLT.db.options.showInObjectiveTracker == false then
			return
		end
		local watched = FLT.GetWatchedList and FLT.GetWatchedList()
		if not watched or not next(watched) then
			return
		end

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
				elseif FLT.UI.frame and FLT.UI.frame.watchBtn then
					FLT.UI.frame.watchBtn:Click()
				end
			end
		end
	end

	return mixin
end

local function TemplateExists(name)
	if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
		local info = C_XMLUtil.GetTemplateInfo(name)
		return info ~= nil
	end
	-- Optimistic fallback: CreateFrame will error if missing; caller pcalls.
	return true
end

local function TryRegisterObjectiveModule()
	if FLT.objectiveTrackerRegistered then
		return true
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
		local ok, frame = pcall(CreateFrame, "Frame", "ForeverLootObjectiveTracker", nil, "ObjectiveTrackerModuleTemplate")
		if not ok or not frame then
			FLT.Debug("Could not create ObjectiveTrackerModuleTemplate frame: " .. tostring(frame))
			return false
		end
		module = frame
	end

	Mixin(module, mixin)
	if module.OnLoad then
		-- Template OnLoad already ran; ensure header text is set.
	end
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
regFrame:SetScript("OnEvent", function(_, event, arg1)
	if event == "ADDON_LOADED" and arg1 ~= "Blizzard_ObjectiveTracker" then
		return
	end
	if TryRegisterObjectiveModule() then
		regFrame:UnregisterAllEvents()
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
