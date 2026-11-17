-- ForeverLootTracker — Money Log, Sessions, Ignored, Add Item, context menu.
local FLT = ForeverLootTracker
FLT.UI = FLT.UI or {}
local UI = FLT.UI
local W = FLT.Widgets

local function Backdrop(frame, a)
	W.Backdrop(frame, a)
end

local function MakeButton(parent, text, width)
	return W.Button(parent, text, width)
end

local function MakeEdit(parent, width)
	return W.EditBox(parent, width or 140, 20)
end

---------------------------------------------------------------------------
-- Money Log panel (+ LibGraph-2.0 cumulative gold chart)
-- Chart approach matches TokenTrend / Recount: embed LibGraph, feed {x,y} series.
---------------------------------------------------------------------------
local GRAPH_WINDOWS = {
	{ value = 30, text = "30m" },
	{ value = 60, text = "1h" },
	{ value = 120, text = "2h" },
	{ value = 240, text = "4h" },
	{ value = -1, text = "Session" },
}

local function CopperToGold(copper)
	return (tonumber(copper) or 0) / 10000
end

-- Build cumulative gold-over-time points for LibGraph ({x minutes, y gold}).
function FLT.BuildMoneyChartSeries(windowMinutes)
	local session = FLT.GetSession()
	local money = session.money or {}
	local now = time()
	local tEnd = math.max(session.lastLoot or 0, now)
	local first = session.firstLoot or (money[1] and money[1].time) or now
	local tStart
	if windowMinutes and windowMinutes > 0 then
		tStart = tEnd - (windowMinutes * 60)
		if tStart < first then
			tStart = first
		end
	else
		tStart = first
	end

	local cum = 0
	for _, entry in ipairs(money) do
		if (entry.time or 0) < tStart then
			cum = cum + (entry.amount or 0)
		end
	end

	local pts = {}
	table.insert(pts, { 0, CopperToGold(cum) })
	for _, entry in ipairs(money) do
		local t = entry.time or 0
		if t >= tStart then
			cum = cum + (entry.amount or 0)
			table.insert(pts, { (t - tStart) / 60, CopperToGold(cum) })
		end
	end

	local xMax = math.max(1, (tEnd - tStart) / 60)
	if #pts == 1 then
		table.insert(pts, { xMax, CopperToGold(cum) })
	elseif pts[#pts][1] < xMax then
		table.insert(pts, { xMax, CopperToGold(cum) })
	end

	return pts, tStart, tEnd, xMax
end

local function RefreshMoneyGraph(mf)
	if not mf or not mf.graph then
		return
	end
	local g = mf.graph
	local window = FLT.db.options.graphWindowMinutes or -1
	local pts, _, _, xMax = FLT.BuildMoneyChartSeries(window)

	local ymin, ymax = 0, 1
	for _, p in ipairs(pts) do
		if p[2] < ymin then
			ymin = p[2]
		end
		if p[2] > ymax then
			ymax = p[2]
		end
	end
	if ymax <= ymin then
		ymax = ymin + 1
	end
	local pad = math.max((ymax - ymin) * 0.08, 0.05)
	ymin = ymin - pad
	ymax = ymax + pad
	-- Zero baseline when the series stays non-negative; include 0 when entirely below.
	if ymin > 0 then
		ymin = 0
	elseif ymax < 0 then
		ymax = 0
	end

	g:ResetData()
	g:SetXAxis(0, xMax)
	g:SetYAxis(ymin, ymax)
	g:SetGridSpacing(math.max(xMax / 6, 0.5), math.max((ymax - ymin) / 4, 0.1))
	-- Gold line (yellow), same role as TokenTrend's price series.
	g:AddDataSeries(pts, { 1.0, 0.82, 0.0, 1.0 })
	if g.RefreshGraph then
		g:RefreshGraph()
	end
	mf.graphEmpty:SetShown(#(FLT.GetSession().money or {}) == 0)
end

function UI.EnsureMoneyPanel(parent)
	if UI.moneyPanel then
		return UI.moneyPanel
	end

	local mf = CreateFrame("Frame", nil, parent)
	mf:SetAllPoints()
	mf:Hide()

	mf.title = mf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	mf.title:SetPoint("TOPLEFT", 12, -8)
	mf.title:SetText("Money Log")
	mf.title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	mf.windowLabel = mf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	mf.windowLabel:SetPoint("LEFT", mf.title, "RIGHT", 16, 0)
	mf.windowLabel:SetText("Window")

	mf.windowDD = W.Dropdown(mf, 90, GRAPH_WINDOWS, function(value)
		FLT.db.options.graphWindowMinutes = value
		RefreshMoneyGraph(mf)
	end)
	mf.windowDD:SetPoint("LEFT", mf.windowLabel, "RIGHT", 6, 0)
	mf.windowDD:SetValue(FLT.db and FLT.db.options.graphWindowMinutes or -1)

	mf.stats = mf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	mf.stats:SetPoint("TOPLEFT", 12, -30)
	mf.stats:SetPoint("TOPRIGHT", -12, -30)
	mf.stats:SetJustifyH("LEFT")

	-- Chart host (LibGraph line chart — same library Recount / TokenTrend use).
	mf.chartHost = CreateFrame("Frame", nil, mf)
	mf.chartHost:SetPoint("TOPLEFT", 8, -50)
	mf.chartHost:SetPoint("TOPRIGHT", -8, -50)
	mf.chartHost:SetHeight(160)
	W.ApplyHeaderBand(mf.chartHost)
	local chartShade = mf.chartHost:CreateTexture(nil, "BACKGROUND", nil, 1)
	chartShade:SetAllPoints()
	chartShade:SetColorTexture(0.01, 0.005, 0.0, 0.55)

	mf.graphEmpty = mf.chartHost:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	mf.graphEmpty:SetPoint("CENTER")
	mf.graphEmpty:SetText("No money events yet — loot, sell, buy, fly, repair, or train to plot.")

	local Graph = LibStub and LibStub("LibGraph-2.0", true)
	if Graph then
		local g = Graph:CreateGraphLine("ForeverLootTrackerMoneyGraph", mf.chartHost, "TOPLEFT", "TOPLEFT", 8, -8, 100, 100)
		g:ClearAllPoints()
		g:SetPoint("TOPLEFT", 8, -8)
		g:SetPoint("BOTTOMRIGHT", -8, 8)
		g:SetAxisDrawing(true, true)
		g:SetAxisColor({ 0.7, 0.7, 0.7, 0.9 })
		g:SetGridColor({ 0.35, 0.35, 0.4, 0.45 })
		if g.SetYLabels then
			g:SetYLabels(true, false)
		end
		mf.graph = g
	else
		mf.graphMissing = mf.chartHost:CreateFontString(nil, "OVERLAY", "GameFontRedSmall")
		mf.graphMissing:SetPoint("CENTER")
		mf.graphMissing:SetText("LibGraph-2.0 failed to load.")
		mf.graphEmpty:Hide()
	end

	-- Spreadsheet header + rows under the chart (same pattern as Items).
	mf.listHeader = CreateFrame("Frame", nil, mf)
	mf.listHeader:SetPoint("TOPLEFT", mf.chartHost, "BOTTOMLEFT", 0, -4)
	mf.listHeader:SetPoint("TOPRIGHT", mf.chartHost, "BOTTOMRIGHT", -20, -4)
	mf.listHeader:SetHeight(22)
	W.ApplyHeaderBand(mf.listHeader)
	mf.listHeader.buttons = {}

	mf.scroll = W.CreateScrollFrame(mf, "ForeverLootTrackerMoneyScroll")
	mf.scroll:SetPoint("TOPLEFT", mf.listHeader, "BOTTOMLEFT", 0, -2)
	mf.scroll:SetPoint("BOTTOMRIGHT", -28, 8)
	mf.child = CreateFrame("Frame", nil, mf.scroll)
	mf.child:SetSize(800, 1)
	mf.scroll:SetScrollChild(mf.child)
	mf.rows = {}

	mf.empty = mf:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	mf.empty:SetPoint("CENTER", mf.scroll, "CENTER")
	mf.empty:SetText("No money events yet.")

	UI.moneyPanel = mf
	return mf
end

-- Money log spreadsheet columns.
local MONEY_COLS = {
	{ key = "type", label = "Type", width = 70, x = 6 },
	{ key = "amount", label = "Amount", width = 120, x = 80 },
	{ key = "name", label = "Name", width = 120, x = 204 },
	{ key = "category", label = "Category", width = 100, x = 328 },
	{ key = "source", label = "Source", width = 120, x = 432 },
	{ key = "zone", label = "Zone", width = 100, x = 556 },
	{ key = "time", label = "Time", width = 120, x = 660 },
}

local function SetMoneyHeaderSortArrow(button, active, ascending)
	if not button or not button.sortArrow then
		return
	end
	if not active then
		button.sortArrow:Hide()
		return
	end
	button.sortArrow:Show()
	if ascending then
		button.sortArrow:SetTexCoord(0, 0.5625, 1, 0)
	else
		button.sortArrow:SetTexCoord(0, 0.5625, 0, 1)
	end
end

local function EnsureMoneyHeaders(mf)
	local hdr = mf.listHeader
	if not hdr or hdr._built then
		return hdr
	end
	for _, col in ipairs(MONEY_COLS) do
		local b = CreateFrame("Button", nil, hdr)
		b:SetSize(col.width, 20)
		b:SetPoint("LEFT", hdr, "LEFT", col.x, 0)
		b.sortArrow = b:CreateTexture(nil, "ARTWORK")
		b.sortArrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
		b.sortArrow:SetSize(9, 8)
		b.sortArrow:SetPoint("RIGHT", b, "RIGHT", -1, 0)
		b.sortArrow:Hide()
		b.fs = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		b.fs:SetPoint("LEFT", b, "LEFT", 2, 0)
		b.fs:SetPoint("RIGHT", b.sortArrow, "LEFT", -2, 0)
		b.fs:SetJustifyH("LEFT")
		b.fs:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])
		b.colKey = col.key
		b:SetScript("OnClick", function(self)
			local ui = FLT.db.ui
			if ui.moneySortKey == self.colKey then
				ui.moneySortAsc = not ui.moneySortAsc
			else
				ui.moneySortKey = self.colKey
				ui.moneySortAsc = (self.colKey ~= "time" and self.colKey ~= "amount")
			end
			UI.RefreshMoneyPanel()
		end)
		hdr.buttons[col.key] = b
	end
	hdr._built = true
	return hdr
end

local function RefreshMoneyHeaders(mf)
	local hdr = EnsureMoneyHeaders(mf)
	if not hdr then
		return
	end
	local ui = FLT.db and FLT.db.ui
	for _, col in ipairs(MONEY_COLS) do
		local b = hdr.buttons[col.key]
		if b then
			b.fs:SetText(col.label)
			SetMoneyHeaderSortArrow(b, ui and ui.moneySortKey == col.key, ui and ui.moneySortAsc)
		end
	end
end

local MONEY_KIND_OPTIONS = {
	{ value = "Loot", text = "Loot" },
	{ value = "Vendor", text = "Vendor" },
	{ value = "Repair", text = "Repair" },
	{ value = "Flight", text = "Flight" },
	{ value = "Training", text = "Training" },
	{ value = "Trade", text = "Trade" },
	{ value = "Mail", text = "Mail" },
	{ value = "Auction", text = "Auction" },
	{ value = "Quest", text = "Quest" },
	{ value = "Bank", text = "Bank" },
	{ value = "GuildBank", text = "Guild Bank" },
	{ value = "Barber", text = "Barber" },
	{ value = "Other", text = "Other" },
	{ value = "Currency", text = "Currency" },
}

local function BuildMoneySheetRows(session)
	local rows = {}
	for i, entry in ipairs(session.money or {}) do
		table.insert(rows, {
			rowType = "Gold",
			amount = entry.amount or 0,
			name = "Gold",
			category = entry.kind or "Other",
			source = entry.source or "?",
			zone = entry.zone or "?",
			time = entry.time or 0,
			entry = entry,
			list = "money",
			listIndex = i,
		})
	end
	for i, entry in ipairs(session.currencies or {}) do
		table.insert(rows, {
			rowType = "Currency",
			amount = entry.amount or 0,
			name = entry.name or ("Currency " .. tostring(entry.currencyID)),
			category = "Currency",
			source = entry.source or "?",
			zone = entry.zone or "?",
			time = entry.time or 0,
			entry = entry,
			list = "currency",
			listIndex = i,
		})
	end
	local ui = FLT.db.ui or {}
	local key = ui.moneySortKey or "time"
	local asc = ui.moneySortAsc and true or false
	table.sort(rows, function(a, b)
		local va, vb
		if key == "amount" or key == "time" then
			va, vb = a[key] or 0, b[key] or 0
		else
			va = string.lower(tostring(a[key] or ""))
			vb = string.lower(tostring(b[key] or ""))
		end
		if va == vb then
			return (a.time or 0) > (b.time or 0)
		end
		if asc then
			return va < vb
		end
		return va > vb
	end)
	return rows
end

local function FormatMoneyCell(row)
	if row.rowType == "Gold" then
		local amt = row.amount or 0
		if amt >= 0 then
			return "|cff00ff00+" .. FLT.FormatMoney(amt) .. "|r"
		end
		return "|cffff6666-" .. FLT.FormatMoney(-amt) .. "|r"
	end
	local amt = row.amount or 0
	if amt >= 0 then
		return "|cff66ccff+" .. tostring(amt) .. "|r"
	end
	return "|cffff66cc" .. tostring(amt) .. "|r"
end

function UI.RefreshMoneyPanel()
	local mf = UI.moneyPanel
	if not mf then
		return
	end
	local session = FLT.GetSession()
	local m = session.stats.copper or FLT.DefaultMoneyStats()
	local net = m.total or 0
	local netStr = (net >= 0 and ("|cff00ff00+" .. FLT.FormatMoney(net) .. "|r"))
		or ("|cffff6666-" .. FLT.FormatMoney(-net) .. "|r")
	mf.stats:SetText(("Net %s  |  Earned |cff00ff00%s|r  |  Spent |cffff6666%s|r  |  /hr %s  |  Gold %d  |  Cur %d"):format(
		netStr,
		FLT.FormatMoney(m.earned or 0),
		FLT.FormatMoney(m.spent or 0),
		FLT.FormatMoney(m.perHour or 0),
		#session.money,
		#(session.currencies or {})
	))
	if mf.windowDD then
		mf.windowDD:SetValue(FLT.db.options.graphWindowMinutes or -1)
	end
	RefreshMoneyGraph(mf)
	RefreshMoneyHeaders(mf)

	for _, row in ipairs(mf.rows) do
		row:Hide()
	end

	local sheet = BuildMoneySheetRows(session)
	local y = -2
	for shown, data in ipairs(sheet) do
		local row = mf.rows[shown]
		if not row then
			row = CreateFrame("Button", nil, mf.child)
			row:SetSize(780, 22)
			row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			W.RowBackground(row, shown)
			row.cells = {}
			for _, col in ipairs(MONEY_COLS) do
				local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
				fs:SetWidth(col.width - 4)
				fs:SetJustifyH("LEFT")
				fs:SetWordWrap(false)
				fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
				row.cells[col.key] = fs
			end
			row:SetScript("OnClick", function(self, button)
				if button == "RightButton" then
					if UI.ShowMoneyContextMenu then
						UI.ShowMoneyContextMenu(self.list, self.listIndex, self)
					end
				else
					if UI.EditMoneyEntry then
						UI.EditMoneyEntry(self.list, self.listIndex)
					end
				end
			end)
			mf.rows[shown] = row
		end
		row.list = data.list
		row.listIndex = data.listIndex
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 4, y)
		row.cells.type:SetText(data.rowType)
		row.cells.amount:SetText(FormatMoneyCell(data))
		row.cells.name:SetText(data.name)
		row.cells.category:SetText(data.category)
		row.cells.source:SetText(data.source)
		row.cells.zone:SetText(data.zone)
		row.cells.time:SetText(FLT.FormatTime(data.time))
		row:Show()
		y = y - 24
	end

	mf.empty:SetShown(#sheet == 0)
	mf.child:SetHeight(math.max(1, -y + 8))
end

---------------------------------------------------------------------------
-- Sessions panel
---------------------------------------------------------------------------
function UI.EnsureSessionsPanel(parent)
	if UI.sessionsPanel then
		return UI.sessionsPanel
	end

	local sf = CreateFrame("Frame", nil, parent)
	sf:SetAllPoints()
	sf:Hide()

	sf.title = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	sf.title:SetPoint("TOPLEFT", 12, -10)
	sf.title:SetText("Sessions")
	sf.title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	sf.help = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	sf.help:SetPoint("TOPLEFT", 12, -34)
	sf.help:SetPoint("TOPRIGHT", -12, -34)
	sf.help:SetJustifyH("LEFT")
	sf.help:SetText("Save archives the current session. Load replaces the current session (optionally archiving it first).")

	sf.nameLabel = sf:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	sf.nameLabel:SetPoint("TOPLEFT", 12, -58)
	sf.nameLabel:SetText("Label")
	sf.nameBox = MakeEdit(sf, 200)
	sf.nameBox:SetPoint("LEFT", sf.nameLabel, "RIGHT", 8, 0)

	sf.saveBtn = MakeButton(sf, "Save Current", 110)
	sf.saveBtn:SetPoint("LEFT", sf.nameBox, "RIGHT", 8, 0)
	sf.saveBtn:SetScript("OnClick", function()
		local label = sf.nameBox:GetText()
		if label == "" then
			label = nil
		end
		FLT.SaveCurrentSession(label)
		UI.RefreshSessionsPanel()
		UI.Refresh()
	end)

	sf.newBtn = MakeButton(sf, "New (Save)", 90)
	sf.newBtn:SetPoint("LEFT", sf.saveBtn, "RIGHT", 6, 0)
	sf.newBtn:SetScript("OnClick", function()
		local lbl = sf.nameBox:GetText()
		if lbl == "" then
			lbl = nil
		end
		FLT.StartNewSession(lbl, true)
		UI.RefreshSessionsPanel()
	end)

	sf.resetBtn = MakeButton(sf, "New (Discard)", 100)
	sf.resetBtn:SetPoint("LEFT", sf.newBtn, "RIGHT", 6, 0)
	sf.resetBtn:SetScript("OnClick", function()
		StaticPopupDialogs["FLT_NEW_DISCARD"] = StaticPopupDialogs["FLT_NEW_DISCARD"] or {
			text = "Start a new session and discard the current unsaved data?",
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				local lbl = UI.sessionsPanel and UI.sessionsPanel.nameBox:GetText()
				if lbl == "" then
					lbl = nil
				end
				FLT.StartNewSession(lbl, false)
				UI.RefreshSessionsPanel()
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
		StaticPopup_Show("FLT_NEW_DISCARD")
	end)

	sf.scroll = W.CreateScrollFrame(sf, "ForeverLootTrackerSessionsScroll")
	sf.scroll:SetPoint("TOPLEFT", 8, -90)
	sf.scroll:SetPoint("BOTTOMRIGHT", -28, 8)
	sf.child = CreateFrame("Frame", nil, sf.scroll)
	sf.child:SetSize(620, 1)
	sf.scroll:SetScrollChild(sf.child)
	sf.rows = {}

	sf.empty = sf:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	sf.empty:SetPoint("CENTER", sf.scroll, "CENTER")
	sf.empty:SetText("No saved sessions yet.")

	UI.sessionsPanel = sf
	return sf
end

function UI.RefreshSessionsPanel()
	local sf = UI.sessionsPanel
	if not sf then
		return
	end
	local session = FLT.GetSession()
	sf.nameBox:SetText(session.label or "")

	for _, row in ipairs(sf.rows) do
		row:Hide()
	end

	local list = FLT.ListSavedSessions()
	local y = -2
	for i, entry in ipairs(list) do
		local row = sf.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, sf.child)
			row:SetSize(600, 40)
			W.RowBackground(row, i)

			row.label = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			row.label:SetPoint("TOPLEFT", 8, -4)
			row.label:SetPoint("RIGHT", -210, 0)
			row.label:SetJustifyH("LEFT")

			row.meta = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			row.meta:SetPoint("BOTTOMLEFT", 8, 4)
			row.meta:SetPoint("RIGHT", -210, 0)
			row.meta:SetJustifyH("LEFT")

			row.load = MakeButton(row, "Load", 60)
			row.load:SetPoint("RIGHT", -140, 0)
			row.load:SetScript("OnClick", function(self)
				local id = self:GetParent().sessionId
				StaticPopupDialogs["FLT_LOAD_SESSION"] = StaticPopupDialogs["FLT_LOAD_SESSION"] or {
					text = "Load saved session #%s?\nCurrent session will be archived first.",
					button1 = YES,
					button2 = NO,
					OnAccept = function(_, data)
						FLT.LoadSavedSession(data.id, true)
						UI.RefreshSessionsPanel()
					end,
					timeout = 0,
					whileDead = true,
					hideOnEscape = true,
					preferredIndex = 3,
				}
				StaticPopup_Show("FLT_LOAD_SESSION", tostring(id), nil, { id = id })
			end)

			row.del = MakeButton(row, "Delete", 60)
			row.del:SetPoint("RIGHT", -70, 0)
			row.del:SetScript("OnClick", function(self)
				local id = self:GetParent().sessionId
				StaticPopupDialogs["FLT_DELETE_SESSION"] = StaticPopupDialogs["FLT_DELETE_SESSION"] or {
					text = "Delete saved session #%s?",
					button1 = YES,
					button2 = NO,
					OnAccept = function(_, data)
						FLT.DeleteSavedSession(data.id)
						UI.RefreshSessionsPanel()
					end,
					timeout = 0,
					whileDead = true,
					hideOnEscape = true,
					preferredIndex = 3,
				}
				StaticPopup_Show("FLT_DELETE_SESSION", tostring(id), nil, { id = id })
			end)

			sf.rows[i] = row
		end

		row.sessionId = entry.id
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 4, y)
		row.label:SetText(("#%s  %s"):format(tostring(entry.id), entry.label or "?"))
		row.meta:SetText(("%d items  |  %d money  |  saved %s"):format(
			entry.itemCount or 0,
			entry.moneyCount or 0,
			FLT.FormatTime(entry.savedAt or entry.created)
		))
		row:Show()
		y = y - 44
	end
	sf.empty:SetShown(#list == 0)
	sf.child:SetHeight(math.max(1, -y + 8))
end

---------------------------------------------------------------------------
-- Ignored rules panel (item / name / source / type)
---------------------------------------------------------------------------
local IGNORE_KIND_OPTIONS = {
	{ value = "item", text = "Item ID" },
	{ value = "name", text = "Name contains" },
	{ value = "source", text = "Source contains" },
	{ value = "type", text = "Type" },
}

local IGNORE_TYPE_OPTIONS = {
	{ value = "st:0", text = "Dropped" },
	{ value = "st:1", text = "Rolled" },
	{ value = "st:2", text = "Master" },
	{ value = "st:3", text = "Crafted" },
	{ value = "st:4", text = "Purchased" },
	{ value = "st:-1", text = "Entered" },
	{ value = "sk:Gathering", text = "Gather" },
	{ value = "sk:Fishing", text = "Fish" },
	{ value = "sk:Mail", text = "Mail" },
	{ value = "sk:Quest", text = "Quest" },
	{ value = "sk:Disenchant", text = "Disenchant" },
	{ value = "sk:ItemBox", text = "Box" },
}

local function IgnoreKindLabel(kind)
	if kind == "item" then
		return "Item"
	elseif kind == "name" then
		return "Name"
	elseif kind == "source" then
		return "Source"
	elseif kind == "type" then
		return "Type"
	end
	return tostring(kind or "?")
end

local function FormatIgnoreRuleText(rule)
	local kind = rule.kind or "item"
	local value = tostring(rule.value or "")
	if kind == "item" then
		local label = rule.label or ("Item " .. value)
		return ("%s  |cff888888ID %s|r"):format(label, value)
	elseif kind == "name" then
		return ("contains \"%s\""):format(value)
	elseif kind == "source" then
		return ("contains \"%s\""):format(value)
	elseif kind == "type" then
		return FLT.IgnoreTypeLabel and FLT.IgnoreTypeLabel(value) or value
	end
	return value
end

local function SyncIgnoredAddControls(ig)
	local kind = ig.kindDD and ig.kindDD:GetValue() or "name"
	local isType = (kind == "type")
	if ig.valueBox then
		ig.valueBox:SetShown(not isType)
	end
	if ig.typeDD then
		ig.typeDD:SetShown(isType)
	end
	if ig.addBtn then
		ig.addBtn:ClearAllPoints()
		if isType then
			ig.addBtn:SetPoint("LEFT", ig.typeDD, "RIGHT", 10, 0)
		else
			ig.addBtn:SetPoint("LEFT", ig.valueBox, "RIGHT", 10, 0)
		end
	end
	if ig.valueHint then
		if kind == "item" then
			ig.valueHint:SetText("Item ID")
		elseif kind == "name" then
			ig.valueHint:SetText("Partial name match")
		elseif kind == "source" then
			ig.valueHint:SetText("Partial source match")
		else
			ig.valueHint:SetText("Loot type")
		end
	end
end

function UI.EnsureIgnoredPanel(parent)
	if UI.ignoredPanel then
		return UI.ignoredPanel
	end

	local ig = CreateFrame("Frame", nil, parent)
	ig:SetAllPoints()
	ig:Hide()

	ig.title = ig:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	ig.title:SetPoint("TOPLEFT", 12, -10)
	ig.title:SetText("Ignore Rules")
	ig.title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	ig.help = ig:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ig.help:SetPoint("TOPLEFT", 12, -34)
	ig.help:SetPoint("TOPRIGHT", -160, -34)
	ig.help:SetJustifyH("LEFT")
	ig.help:SetText("Ignore exact items, partial name/source matches, or loot types. Matching loot is never recorded.")

	ig.clearAll = MakeButton(ig, "Clear All", 90)
	ig.clearAll:SetPoint("TOPRIGHT", -12, -8)
	ig.clearAll:SetScript("OnClick", function()
		StaticPopupDialogs["FLT_CLEAR_IGNORED"] = StaticPopupDialogs["FLT_CLEAR_IGNORED"] or {
			text = "Clear all ignore rules?",
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				FLT.ClearIgnoreRules()
				UI.RefreshIgnoredPanel()
				FLT.Print("Ignore rules cleared.")
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
		StaticPopup_Show("FLT_CLEAR_IGNORED")
	end)

	ig.addLabel = ig:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	ig.addLabel:SetPoint("TOPLEFT", 12, -58)
	ig.addLabel:SetText("Add rule")

	ig.kindDD = W.Dropdown(ig, 130, IGNORE_KIND_OPTIONS, function()
		SyncIgnoredAddControls(ig)
	end)
	ig.kindDD:SetPoint("TOPLEFT", 12, -80)
	ig.kindDD:SetValue("name")

	ig.valueHint = ig:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	ig.valueHint:SetPoint("LEFT", ig.kindDD, "RIGHT", 10, 8)

	ig.valueBox = MakeEdit(ig, 220)
	ig.valueBox:SetPoint("LEFT", ig.kindDD, "RIGHT", 10, -4)

	ig.typeDD = W.Dropdown(ig, 140, IGNORE_TYPE_OPTIONS)
	ig.typeDD:SetPoint("LEFT", ig.kindDD, "RIGHT", 10, 0)
	ig.typeDD:SetValue("st:0")
	ig.typeDD:Hide()

	ig.addBtn = MakeButton(ig, "Add", 60)
	ig.addBtn:SetPoint("LEFT", ig.valueBox, "RIGHT", 10, 0)
	ig.addBtn:SetScript("OnClick", function()
		local kind = ig.kindDD:GetValue() or "name"
		local value, label
		if kind == "type" then
			value = ig.typeDD:GetValue() or "st:0"
			label = FLT.IgnoreTypeLabel and FLT.IgnoreTypeLabel(value) or value
		else
			value = (ig.valueBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
			label = value
			if kind == "item" then
				local itemID = tonumber(value)
				if not itemID then
					FLT.Print("Enter a numeric item ID.")
					return
				end
				value = tostring(itemID)
				local cached = FLT.CacheItem and FLT.CacheItem(itemID)
				label = (cached and cached.name) or ("Item " .. value)
			end
		end
		if not value or value == "" then
			FLT.Print("Enter a value for the ignore rule.")
			return
		end
		local rule = FLT.AddIgnoreRule(kind, value, label)
		if rule then
			FLT.PurgeSessionItemsMatchingIgnore(rule)
			if UI.Refresh then
				UI.Refresh()
			end
			UI.RefreshIgnoredPanel()
			FLT.Print("Ignored " .. FormatIgnoreRuleText(rule))
			ig.valueBox:SetText("")
		end
	end)

	SyncIgnoredAddControls(ig)

	ig.scroll = W.CreateScrollFrame(ig, "ForeverLootTrackerIgnoredScroll")
	ig.scroll:SetPoint("TOPLEFT", 8, -112)
	ig.scroll:SetPoint("BOTTOMRIGHT", -28, 8)
	ig.child = CreateFrame("Frame", nil, ig.scroll)
	ig.child:SetSize(620, 1)
	ig.scroll:SetScrollChild(ig.child)
	ig.rows = {}

	ig.empty = ig:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	ig.empty:SetPoint("CENTER", ig.scroll, "CENTER")
	ig.empty:SetText("No ignore rules.")

	UI.ignoredPanel = ig
	return ig
end

function UI.RefreshIgnoredPanel()
	local ig = UI.ignoredPanel
	if not ig then
		return
	end
	for _, row in ipairs(ig.rows) do
		row:Hide()
	end

	local rules = FLT.GetIgnoreRules and FLT.GetIgnoreRules() or {}
	local entries = {}
	for _, rule in ipairs(rules) do
		table.insert(entries, rule)
	end
	table.sort(entries, function(a, b)
		local ka = IgnoreKindLabel(a.kind) .. " " .. tostring(a.label or a.value or "")
		local kb = IgnoreKindLabel(b.kind) .. " " .. tostring(b.label or b.value or "")
		return ka:lower() < kb:lower()
	end)

	ig.title:SetText(("Ignore Rules (%d)"):format(#entries))
	local y = -2
	for i, rule in ipairs(entries) do
		local row = ig.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, ig.child)
			row:SetSize(600, 32)
			W.RowBackground(row, i)
			row.kind = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			row.kind:SetPoint("LEFT", 8, 0)
			row.kind:SetWidth(64)
			row.kind:SetJustifyH("LEFT")
			row.kind:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])
			row.icon = row:CreateTexture(nil, "ARTWORK")
			row.icon:SetSize(20, 20)
			row.icon:SetPoint("LEFT", 74, 0)
			row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			row.name:SetPoint("LEFT", 100, 0)
			row.name:SetPoint("RIGHT", -90, 0)
			row.name:SetJustifyH("LEFT")
			row.remove = MakeButton(row, "Remove", 70)
			row.remove:SetPoint("RIGHT", -8, 0)
			row.remove:SetScript("OnClick", function(self)
				local parent = self:GetParent()
				if parent.ruleId then
					FLT.RemoveIgnoreRule(parent.ruleId)
					UI.RefreshIgnoredPanel()
					FLT.Print("Removed ignore rule.")
				end
			end)
			ig.rows[i] = row
		end
		row.ruleId = rule.id
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 4, y)
		row.kind:SetText(IgnoreKindLabel(rule.kind))
		row.name:SetText(FormatIgnoreRuleText(rule))

		local icon
		if rule.kind == "item" then
			local itemID = tonumber(rule.value)
			if itemID then
				if C_Item and C_Item.GetItemIconByID then
					icon = C_Item.GetItemIconByID(itemID)
				end
				if not icon then
					local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(itemID)
					icon = tex
				end
			end
		end
		if rule.kind == "item" then
			row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
			row.icon:Show()
			row.name:SetPoint("LEFT", 100, 0)
		else
			row.icon:Hide()
			row.name:SetPoint("LEFT", 78, 0)
		end
		row:Show()
		y = y - 34
	end
	ig.empty:SetShown(#entries == 0)
	ig.child:SetHeight(math.max(1, -y + 8))
end

---------------------------------------------------------------------------
-- Manual Add Item dialog
---------------------------------------------------------------------------
function UI.ShowAddItem()
	if UI.addFrame then
		UI.addFrame:Hide()
		UI.addFrame = nil
	end

	local af = W.DialogFrame("ForeverLootTrackerAddFrame", 380, 280)

	local title = af:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -12)
	title:SetText("Add Item")
	title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	local help = af:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 16, -40)
	help:SetPoint("TOPRIGHT", -16, -40)
	help:SetJustifyH("LEFT")
	help:SetText("Enter an item ID, or Shift-click an item link into the Item field.")

	local function LabeledEdit(labelText, y, width)
		local label = af:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		label:SetPoint("TOPLEFT", 16, y)
		label:SetText(labelText)
		local box = MakeEdit(af, width or 200)
		box:SetPoint("LEFT", label, "RIGHT", 12, 0)
		return box
	end

	local itemBox = LabeledEdit("Item", -70, 220)
	local countBox = LabeledEdit("Count", -100, 80)
	countBox:SetText("1")
	local looterBox = LabeledEdit("Looter", -130, 180)
	looterBox:SetText((FLT.UnitDisplayName and FLT.UnitDisplayName("player")) or UnitName("player") or "")
	local costBox = LabeledEdit("Cost", -160, 80)
	costBox:SetText(tostring(FLT.db.options.defaultCost or 0))
	local sourceBox = LabeledEdit("Source", -190, 180)
	sourceBox:SetText("Entered")

	-- Accept pasted item links in the Item field.
	itemBox:SetScript("OnTextChanged", function(self)
		local text = self:GetText() or ""
		local id = text:match("item:(%d+)")
		if id then
			self:SetText(id)
		end
	end)

	local add = MakeButton(af, "Add", 80)
	add:SetPoint("BOTTOMLEFT", 16, 16)
	add:SetScript("OnClick", function()
		local raw = itemBox:GetText() or ""
		local itemID = tonumber(raw:match("(%d+)"))
		if FLT.AddManualItem(itemID, countBox:GetText(), looterBox:GetText(), costBox:GetText(), sourceBox:GetText()) then
			af:Hide()
		end
	end)

	local cancel = MakeButton(af, "Cancel", 80)
	cancel:SetPoint("BOTTOMRIGHT", -16, 16)
	cancel:SetScript("OnClick", function()
		af:Hide()
	end)

	UI.addFrame = af
	af:Show()
	itemBox:SetFocus()
end

---------------------------------------------------------------------------
-- Money / currency edit + context menu
---------------------------------------------------------------------------
local function GetMoneyListEntry(list, index)
	local session = FLT.GetSession()
	if list == "money" then
		return session.money and session.money[index], session.money, "Gold"
	elseif list == "currency" then
		return session.currencies and session.currencies[index], session.currencies, "Currency"
	end
	return nil
end

local function DeleteMoneyEntry(list, index)
	local entry, arr = GetMoneyListEntry(list, index)
	if not entry or not arr then
		return
	end
	table.remove(arr, index)
	FLT.RebuildStats()
	UI.Refresh()
	if FLT.UpdateTitanPlugin then
		FLT.UpdateTitanPlugin()
	end
end

function UI.EditMoneyEntry(list, index)
	local entry = GetMoneyListEntry(list, index)
	if not entry then
		return
	end

	if UI.editMoneyFrame then
		UI.editMoneyFrame:Hide()
		UI.editMoneyFrame:SetParent(nil)
		UI.editMoneyFrame = nil
	end

	local isGold = (list == "money")
	local ef = W.DialogFrame("ForeverLootTrackerEditMoneyFrame", 380, 260)

	local title = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -12)
	title:SetText(isGold and "Edit Gold Entry" or "Edit Currency Entry")
	title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	local info = ef:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	info:SetPoint("TOPLEFT", 16, -40)
	info:SetPoint("TOPRIGHT", -16, -40)
	info:SetJustifyH("LEFT")
	if isGold then
		info:SetText("Amount is copper (10000 = 1g). Negative = spend.")
	else
		info:SetText((entry.name or ("Currency " .. tostring(entry.currencyID or "?")))
			.. "\nID: " .. tostring(entry.currencyID or "?"))
	end

	local amountLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	amountLabel:SetPoint("TOPLEFT", 16, -78)
	amountLabel:SetText("Amount")
	local amountBox = MakeEdit(ef, 120)
	amountBox:SetPoint("LEFT", amountLabel, "RIGHT", 12, 0)
	amountBox:SetText(tostring(entry.amount or 0))

	local sourceLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	sourceLabel:SetPoint("TOPLEFT", 16, -110)
	sourceLabel:SetText("Source")
	local sourceBox = MakeEdit(ef, 220)
	sourceBox:SetPoint("LEFT", sourceLabel, "RIGHT", 12, 0)
	sourceBox:SetText(entry.source or "")

	local typeLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	typeLabel:SetPoint("TOPLEFT", 16, -142)
	typeLabel:SetText("Type")
	local typeDD = W.Dropdown(ef, 160, MONEY_KIND_OPTIONS)
	typeDD:SetPoint("LEFT", typeLabel, "RIGHT", 12, 0)
	typeDD:SetValue(isGold and (entry.kind or "Other") or "Currency")

	local zoneLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	zoneLabel:SetPoint("TOPLEFT", 16, -174)
	zoneLabel:SetText("Zone")
	local zoneBox = MakeEdit(ef, 220)
	zoneBox:SetPoint("LEFT", zoneLabel, "RIGHT", 12, 0)
	zoneBox:SetText(entry.zone or "")

	local save = MakeButton(ef, "Save", 80)
	save:SetPoint("BOTTOMLEFT", 16, 16)
	save:SetScript("OnClick", function()
		entry.amount = tonumber(amountBox:GetText()) or entry.amount or 0
		entry.source = sourceBox:GetText() or entry.source
		entry.zone = zoneBox:GetText() or entry.zone
		if isGold then
			local kind = typeDD:GetValue()
			if kind and kind ~= "Currency" then
				entry.kind = kind
			end
		end
		FLT.RebuildStats()
		ef:Hide()
		UI.Refresh()
		if FLT.UpdateTitanPlugin then
			FLT.UpdateTitanPlugin()
		end
	end)

	local del = MakeButton(ef, "Delete", 80)
	del:SetPoint("LEFT", save, "RIGHT", 8, 0)
	del:SetScript("OnClick", function()
		StaticPopupDialogs["FLT_CONFIRM_DELETE_MONEY"] = StaticPopupDialogs["FLT_CONFIRM_DELETE_MONEY"] or {
			text = "Delete this money log entry?",
			button1 = YES,
			button2 = NO,
			OnAccept = function(_, data)
				if data then
					DeleteMoneyEntry(data.list, data.index)
				end
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
		ef:Hide()
		StaticPopup_Show("FLT_CONFIRM_DELETE_MONEY", nil, nil, { list = list, index = index })
	end)

	local cancel = MakeButton(ef, "Cancel", 80)
	cancel:SetPoint("BOTTOMRIGHT", -16, 16)
	cancel:SetScript("OnClick", function()
		ef:Hide()
	end)

	UI.editMoneyFrame = ef
	ef:Show()
end

local function FallbackMoneyContextMenu(anchor, list, index, label)
	if UI.ctxMenu then
		UI.ctxMenu:Hide()
	end
	local menu = CreateFrame("Frame", "ForeverLootTrackerMoneyContextMenu", UIParent, "BackdropTemplate")
	menu:SetSize(160, 100)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	Backdrop(menu, 0.98)
	menu:EnableMouse(true)
	menu:SetClampedToScreen(true)

	local function Close()
		menu:Hide()
	end

	local opts = {
		{ "Edit", function()
			UI.EditMoneyEntry(list, index)
		end },
		{ "Delete Entry", function()
			StaticPopupDialogs["FLT_CONFIRM_DELETE_MONEY"] = StaticPopupDialogs["FLT_CONFIRM_DELETE_MONEY"] or {
				text = "Delete this money log entry?",
				button1 = YES,
				button2 = NO,
				OnAccept = function(_, data)
					if data then
						DeleteMoneyEntry(data.list, data.index)
					end
				end,
				timeout = 0,
				whileDead = true,
				hideOnEscape = true,
				preferredIndex = 3,
			}
			StaticPopup_Show("FLT_CONFIRM_DELETE_MONEY", nil, nil, { list = list, index = index })
		end },
		{ "Cancel", Close },
	}

	local y = -6
	for _, opt in ipairs(opts) do
		local b = MakeButton(menu, opt[1], 140)
		b:SetPoint("TOP", 0, y)
		b:SetScript("OnClick", function()
			Close()
			opt[2]()
		end)
		y = y - 28
	end
	menu:SetHeight(-y + 6)

	local x, yy = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, yy / scale)
	menu:Show()
	UI.ctxMenu = menu

	menu:SetScript("OnEvent", function(self, event)
		if event == "GLOBAL_MOUSE_DOWN" and not self:IsMouseOver() then
			Close()
		end
	end)
	if menu.RegisterEvent then
		pcall(function()
			menu:RegisterEvent("GLOBAL_MOUSE_DOWN")
		end)
	end
end

function UI.ShowMoneyContextMenu(list, index, anchor)
	local entry = GetMoneyListEntry(list, index)
	if not entry then
		return
	end
	local label = (list == "money") and "Gold entry" or (entry.name or "Currency entry")

	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(anchor or UI.frame, function(_, root)
			root:CreateTitle(label)
			root:CreateButton("Edit", function()
				UI.EditMoneyEntry(list, index)
			end)
			root:CreateButton("Delete Entry…", function()
				StaticPopupDialogs["FLT_CONFIRM_DELETE_MONEY"] = StaticPopupDialogs["FLT_CONFIRM_DELETE_MONEY"] or {
					text = "Delete this money log entry?",
					button1 = YES,
					button2 = NO,
					OnAccept = function(_, data)
						if data then
							DeleteMoneyEntry(data.list, data.index)
						end
					end,
					timeout = 0,
					whileDead = true,
					hideOnEscape = true,
					preferredIndex = 3,
				}
				StaticPopup_Show("FLT_CONFIRM_DELETE_MONEY", nil, nil, { list = list, index = index })
			end)
			root:CreateDivider()
			root:CreateButton("Cancel", function() end)
		end)
		return
	end

	FallbackMoneyContextMenu(anchor, list, index, label)
end

---------------------------------------------------------------------------
-- Context menu (right-click loot row)
---------------------------------------------------------------------------
local function FallbackContextMenu(anchor, index, itemID, name, item)
	if UI.ctxMenu then
		UI.ctxMenu:Hide()
	end
	local menu = CreateFrame("Frame", "ForeverLootTrackerContextMenu", UIParent, "BackdropTemplate")
	menu:SetSize(180, 230)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	Backdrop(menu, 0.98)
	menu:EnableMouse(true)
	menu:SetClampedToScreen(true)

	local function Close()
		menu:Hide()
	end

	local source = (item and item.source) or ""
	local typeKey = FLT.ItemTypeIgnoreKey and FLT.ItemTypeIgnoreKey(item and item.sourceType, item and item.sourceKind) or "st:0"
	local typeLabel = FLT.IgnoreTypeLabel and FLT.IgnoreTypeLabel(typeKey) or typeKey

	local opts = {
		{ "Edit", function()
			UI.EditItem(index)
		end },
		{ FLT.IsWatched(itemID) and "Unwatch" or "Watch", function()
			UI.ToggleWatch(itemID, name)
			UI.Refresh()
		end },
		{ "Ignore Item", function()
			UI.PromptIgnoreRule("item", tostring(itemID), name, itemID)
		end },
		{ "Ignore Name…", function()
			UI.ShowIgnorePatternDialog("name", name, itemID)
		end },
		{ "Ignore Source…", function()
			UI.ShowIgnorePatternDialog("source", source, itemID)
		end },
		{ "Ignore Type", function()
			UI.PromptIgnoreRule("type", typeKey, typeLabel, itemID)
		end },
		{ "Delete Entry", function()
			StaticPopupDialogs["FLT_CONFIRM_DELETE_ENTRY"] = StaticPopupDialogs["FLT_CONFIRM_DELETE_ENTRY"] or {
				text = "Delete tracked loot entry \"%s\"?",
				button1 = YES,
				button2 = NO,
				OnAccept = function(_, data)
					if not data or not data.index then
						return
					end
					table.remove(FLT.GetSession().items, data.index)
					FLT.RebuildStats()
					UI.Refresh()
					if FLT.RefreshObjectiveTracker then
						FLT.RefreshObjectiveTracker()
					end
				end,
				timeout = 0,
				whileDead = true,
				hideOnEscape = true,
				preferredIndex = 3,
			}
			StaticPopup_Show("FLT_CONFIRM_DELETE_ENTRY", name, nil, { index = index })
		end },
		{ "Cancel", Close },
	}

	local y = -6
	for i, opt in ipairs(opts) do
		local b = MakeButton(menu, opt[1], 140)
		b:SetPoint("TOP", 0, y)
		b:SetScript("OnClick", function()
			Close()
			opt[2]()
		end)
		y = y - 28
	end
	menu:SetHeight(-y + 6)

	local x, yy = GetCursorPosition()
	local scale = UIParent:GetEffectiveScale()
	menu:ClearAllPoints()
	menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale, yy / scale)
	menu:Show()
	UI.ctxMenu = menu

	menu:SetScript("OnEvent", function(self, event)
		if event == "GLOBAL_MOUSE_DOWN" then
			if not self:IsMouseOver() then
				Close()
			end
		end
	end)
	if menu.RegisterEvent then
		pcall(function()
			menu:RegisterEvent("GLOBAL_MOUSE_DOWN")
		end)
	end
end

function UI.ShowItemContextMenu(index, anchor)
	local session = FLT.GetSession()
	local item = session.items[index]
	if not item then
		return
	end
	local itemID = item.itemID
	local cached = session.itemCache[itemID]
	local name = cached and cached.name or ("Item " .. tostring(itemID))

	if IsShiftKeyDown() then
		UI.ToggleWatch(itemID, name)
		UI.Refresh()
		return
	end

	local source = item.source or ""
	local typeKey = FLT.ItemTypeIgnoreKey and FLT.ItemTypeIgnoreKey(item.sourceType, item.sourceKind) or "st:0"
	local typeLabel = FLT.IgnoreTypeLabel and FLT.IgnoreTypeLabel(typeKey) or typeKey

	if MenuUtil and MenuUtil.CreateContextMenu then
		MenuUtil.CreateContextMenu(anchor or UI.frame, function(_, root)
			root:CreateTitle(name)
			root:CreateButton("Edit", function()
				UI.EditItem(index)
			end)
			root:CreateButton(FLT.IsWatched(itemID) and "Unwatch" or "Watch", function()
				UI.ToggleWatch(itemID, name)
				UI.Refresh()
			end)
			root:CreateButton("Ignore Item", function()
				UI.PromptIgnoreRule("item", tostring(itemID), name, itemID)
			end)
			root:CreateButton("Ignore Name…", function()
				UI.ShowIgnorePatternDialog("name", name, itemID)
			end)
			root:CreateButton("Ignore Source…", function()
				UI.ShowIgnorePatternDialog("source", source, itemID)
			end)
			root:CreateButton("Ignore Type (" .. typeLabel .. ")", function()
				UI.PromptIgnoreRule("type", typeKey, typeLabel, itemID)
			end)
			root:CreateButton("Delete Entry…", function()
				StaticPopupDialogs["FLT_CONFIRM_DELETE_ENTRY"] = StaticPopupDialogs["FLT_CONFIRM_DELETE_ENTRY"] or {
					text = "Delete tracked loot entry \"%s\"?",
					button1 = YES,
					button2 = NO,
					OnAccept = function(_, data)
						if not data or not data.index then
							return
						end
						table.remove(FLT.GetSession().items, data.index)
						FLT.RebuildStats()
						UI.Refresh()
						if FLT.RefreshObjectiveTracker then
							FLT.RefreshObjectiveTracker()
						end
					end,
					timeout = 0,
					whileDead = true,
					hideOnEscape = true,
					preferredIndex = 3,
				}
				StaticPopup_Show("FLT_CONFIRM_DELETE_ENTRY", name, nil, { index = index })
			end)
			root:CreateDivider()
			root:CreateButton("Cancel", function() end)
		end)
		return
	end

	FallbackContextMenu(anchor, index, itemID, name, item)
end

---------------------------------------------------------------------------
-- Recording button helper
---------------------------------------------------------------------------
function UI.RefreshRecordingButton()
	local f = UI.frame
	if not f or not f.recBtn then
		return
	end
	local fs = f.recBtn.GetFontString and f.recBtn:GetFontString()
	if FLT.IsRecording() then
		f.recBtn:SetText("Pause")
		-- Warm warning tint while actively recording (Pause available).
		if fs then
			local w = W.COLORS.warning
			fs:SetTextColor(w[1], w[2], w[3])
		end
	else
		f.recBtn:SetText("Resume")
		if fs then
			fs:SetTextColor(1, 0.82, 0.1)
		end
	end
end
