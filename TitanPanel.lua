-- ForeverLootTracker — Titan Panel integration via LibDataBroker-1.1.
-- Titan auto-converts LDB data sources into panel buttons (see TitanLDB.lua).
-- Bar text is the session net gold gain/loss.
local FLT = ForeverLootTracker

local LDB_NAME = "ForeverLootTracker"
local ICON = "Interface\\Icons\\INV_Misc_Bag_10"

-- Compact coin string for the bar (omit trailing zero units).
local function FormatNetCompact(copper)
	copper = math.floor(tonumber(copper) or 0)
	local neg = copper < 0
	copper = math.abs(copper)
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100
	local body
	if g > 0 then
		body = (s > 0) and ("%dg %ds"):format(g, s) or ("%dg"):format(g)
	elseif s > 0 then
		body = (c > 0) and ("%ds %dc"):format(s, c) or ("%ds"):format(s)
	else
		body = ("%dc"):format(c)
	end
	if neg then
		return "|cffff6666-" .. body .. "|r", "-" .. body
	end
	return "|cff00ff00+" .. body .. "|r", "+" .. body
end

local function FormatNetFull(copper)
	copper = tonumber(copper) or 0
	if copper >= 0 then
		return "|cff00ff00+" .. FLT.FormatMoney(copper) .. "|r"
	end
	return "|cffff6666-" .. FLT.FormatMoney(-copper) .. "|r"
end

local function SessionSummary()
	if not FLT.db or not FLT.GetSession then
		return 0, 0, 0, 0, false
	end
	local session = FLT.GetSession()
	local m = session.stats and session.stats.copper or FLT.DefaultMoneyStats()
	return #session.items,
		#session.money,
		#(session.currencies or {}),
		m.total or 0,
		FLT.IsRecording and FLT.IsRecording()
end

function FLT.UpdateTitanPlugin()
	local obj = FLT.ldbObject
	if not obj then
		return
	end
	local items, _, _, net, recording = SessionSummary()
	local colored, plain = FormatNetCompact(net)
	local pause = (recording == false) and " |cffff8800P|r" or ""
	-- Primary bar display: session net gain/loss (what Titan shows as regular text).
	obj.text = "Net " .. colored .. pause
	obj.value = plain
	obj.suffix = "net"
	obj.label = "FLT"
	obj.icon = ICON
	-- Extra attrs some displays read:
	obj.fltNet = net
	obj.fltItems = items
end

local function BuildTooltip(tt)
	if not tt or not tt.AddLine then
		return
	end
	local items, money, curs, net, recording = SessionSummary()
	tt:AddLine("ForeverLootTracker", 1, 0.82, 0)
	tt:AddLine(" ")
	if FLT.db and FLT.GetSession then
		local session = FLT.GetSession()
		tt:AddDoubleLine("Session", session.label or "Default", 1, 1, 1, 0.9, 0.9, 0.9)
		tt:AddDoubleLine("Net (session)", FormatNetFull(net), 1, 1, 1, 1, 1, 1)
		local m = session.stats and session.stats.copper
		if m then
			tt:AddDoubleLine("Earned", FLT.FormatMoney(m.earned or 0), 1, 1, 1, 0.2, 1, 0.2)
			tt:AddDoubleLine("Spent", FLT.FormatMoney(m.spent or 0), 1, 1, 1, 1, 0.4, 0.4)
			tt:AddDoubleLine("Per hour", FLT.FormatMoney(m.perHour or 0), 1, 1, 1, 0.9, 0.9, 0.9)
		end
		tt:AddLine(" ")
		tt:AddDoubleLine("Items", tostring(items), 1, 1, 1, 0.9, 0.9, 0.9)
		tt:AddDoubleLine("Gold events", tostring(money), 1, 1, 1, 0.9, 0.9, 0.9)
		tt:AddDoubleLine("Currency events", tostring(curs), 1, 1, 1, 0.9, 0.9, 0.9)
		tt:AddDoubleLine("Recording", recording and "|cff00ff00On|r" or "|cffff8800Paused|r", 1, 1, 1, 1, 1, 1)
		local q = FLT.QueueSize and FLT.QueueSize() or 0
		if q > 0 then
			tt:AddDoubleLine("Queue", tostring(q) .. " pending", 1, 1, 1, 1, 0.8, 0)
		end
	else
		tt:AddLine("Loading…", 0.7, 0.7, 0.7)
	end
	tt:AddLine(" ")
	local fmt = FLT.FormatClickHints or function(s) return s end
	tt:AddLine(fmt("Left Click: Open tracker"), 0.2, 1, 0.2)
	tt:AddLine(fmt("Right Click: Pause / Resume recording"), 0.2, 1, 0.2)
	tt:AddLine(fmt("Shift+Left Click: Export"), 0.2, 1, 0.2)
end

local function OnClick(_, button)
	if button == "LeftButton" then
		if IsShiftKeyDown() and FLT.UI and FLT.UI.ShowExport then
			FLT.UI.ShowExport()
		elseif FLT.UI and FLT.UI.Toggle then
			FLT.UI.Toggle()
		end
	elseif button == "RightButton" then
		if FLT.ToggleRecording then
			FLT.ToggleRecording()
			FLT.UpdateTitanPlugin()
		end
	end
end

function FLT.RegisterTitanPlugin()
	if FLT.ldbObject then
		FLT.UpdateTitanPlugin()
		return true
	end
	local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
	if not LDB then
		return false
	end
	local obj = LDB:NewDataObject(LDB_NAME, {
		type = "data source",
		text = "Net +0c",
		value = "+0c",
		suffix = "net",
		label = "FLT",
		icon = ICON,
		OnClick = OnClick,
		OnTooltipShow = BuildTooltip,
	})
	if not obj then
		obj = LDB:GetDataObjectByName(LDB_NAME)
	end
	if not obj then
		return false
	end
	FLT.ldbObject = obj
	FLT.UpdateTitanPlugin()
	if FLT.Debug then
		FLT.Debug("Titan/LDB plugin registered.")
	end
	return true
end

local attempts = 0
local function TryRegister()
	if FLT.RegisterTitanPlugin() then
		-- Keep the bar live even when the FLT window is closed.
		if C_Timer and C_Timer.NewTicker and not FLT._titanTicker then
			FLT._titanTicker = C_Timer.NewTicker(2, function()
				FLT.UpdateTitanPlugin()
			end)
		end
		return
	end
	attempts = attempts + 1
	if attempts < 15 and C_Timer and C_Timer.After then
		C_Timer.After(1, TryRegister)
	end
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_MONEY")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function(_, event, name)
	if event == "PLAYER_LOGIN" then
		TryRegister()
	elseif event == "PLAYER_MONEY" then
		-- Wallet changed — refresh net immediately.
		if FLT.UpdateTitanPlugin then
			-- Defer one frame so FLT.OnPlayerMoney has updated stats first.
			if C_Timer and C_Timer.After then
				C_Timer.After(0, FLT.UpdateTitanPlugin)
			else
				FLT.UpdateTitanPlugin()
			end
		end
	elseif event == "ADDON_LOADED" and (name == "Titan" or name == "TitanPanel") then
		TryRegister()
	end
end)

do
	local UI = FLT.UI
	if UI and UI.Refresh then
		local old = UI.Refresh
		function UI.Refresh(...)
			old(...)
			FLT.UpdateTitanPlugin()
		end
	end
	if UI and UI.RefreshIfShown then
		local old = UI.RefreshIfShown
		function UI.RefreshIfShown(...)
			old(...)
			FLT.UpdateTitanPlugin()
		end
	end
end
