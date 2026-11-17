-- ForeverLootTracker — minimap ring button (GearQuest / Companion style).
-- Self-contained: no LibDBIcon dependency. Drag around the rim to reposition.
local FLT = ForeverLootTracker
FLT.Minimap = FLT.Minimap or {}
local MM = FLT.Minimap

local ICON = "Interface\\Icons\\INV_Misc_Bag_10"
local ICON_SIZE = 20
local BUTTON_SIZE = 31
local BORDER_OUTSET = 5
local DEFAULT_ANGLE = 210

local function GetRadius()
	if not Minimap then
		return 70
	end
	local w = Minimap:GetWidth() or 140
	local h = Minimap:GetHeight() or w
	return (math.min(w, h) / 2) + BORDER_OUTSET
end

local function GetAngle()
	local ui = FLT.db and FLT.db.ui
	return (ui and ui.minimapAngle) or DEFAULT_ANGLE
end

local function SetAngle(angle)
	if not FLT.db then
		return
	end
	FLT.db.ui = FLT.db.ui or {}
	FLT.db.ui.minimapAngle = angle
end

local function UpdatePosition(button)
	if not button or not Minimap then
		return
	end
	local radius = GetRadius()
	local angle = math.rad(GetAngle())
	local x = math.cos(angle) * radius
	local y = math.sin(angle) * radius
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function IsHidden()
	return FLT.db and FLT.db.options and FLT.db.options.showMinimapButton == false
end

function MM.ApplyVisibility()
	local button = MM.button
	if not button then
		return
	end
	if IsHidden() then
		button:Hide()
		if GameTooltip and GameTooltip.GetOwner and GameTooltip:GetOwner() == button then
			GameTooltip:Hide()
		end
	else
		button:Show()
		UpdatePosition(button)
	end
end

function MM.SetShown(shown)
	if not FLT.db then
		return
	end
	FLT.db.options = FLT.db.options or {}
	FLT.db.options.showMinimapButton = shown and true or false
	MM.ApplyVisibility()
end

function MM.IsShown()
	return not IsHidden()
end

local function OnClick(self, mouseButton)
	if mouseButton == "LeftButton" then
		if IsShiftKeyDown() and FLT.UI and FLT.UI.ShowExport then
			FLT.UI.ShowExport()
		elseif FLT.UI and FLT.UI.Toggle then
			FLT.UI.Toggle()
		end
	elseif mouseButton == "RightButton" then
		if FLT.ToggleRecording then
			FLT.ToggleRecording()
			if FLT.UpdateTitanPlugin then
				FLT.UpdateTitanPlugin()
			end
		end
	end
end

function MM.Init()
	if MM.button or not Minimap then
		if MM.button then
			MM.ApplyVisibility()
		end
		return
	end

	local button = CreateFrame("Button", "ForeverLootTrackerMinimapButton", Minimap)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 8)
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT", 0, 0)

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetSize(20, 20)
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetPoint("CENTER", 0, 1)

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetSize(ICON_SIZE, ICON_SIZE)
	icon:SetTexture(ICON)
	icon:SetPoint("CENTER", 0, 1)
	icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
	button.icon = icon

	if button.RegisterForClicks then
		if not pcall(button.RegisterForClicks, button, "LeftButtonUp", "RightButtonUp") then
			pcall(button.RegisterForClicks, button, "LeftButton", "RightButton")
		end
	end
	button:RegisterForDrag("LeftButton")
	button:SetScript("OnClick", OnClick)

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Forever Loot Tracker", 1, 0.82, 0)
		local fmt = FLT.FormatClickHints or function(s) return s end
		GameTooltip:AddLine(fmt("Left Click: Open tracker"), 0.9, 0.9, 0.9)
		GameTooltip:AddLine(fmt("Right Click: Pause / Resume"), 0.9, 0.9, 0.9)
		GameTooltip:AddLine(fmt("Shift+Left Click: Export"), 0.9, 0.9, 0.9)
		GameTooltip:AddLine("Drag: Move button", 0.6, 0.6, 0.6)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	button:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", function(s)
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			SetAngle(math.deg(math.atan2(py - my, px - mx)))
			UpdatePosition(s)
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:UnlockHighlight()
		self:SetScript("OnUpdate", nil)
	end)

	UpdatePosition(button)
	MM.button = button
	MM.ApplyVisibility()

	if Minimap.HookScript then
		pcall(function()
			Minimap:HookScript("OnSizeChanged", function()
				if MM.button then
					UpdatePosition(MM.button)
				end
			end)
		end)
	end
end
