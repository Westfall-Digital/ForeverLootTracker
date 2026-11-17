-- ForeverLootTracker — main tracker / options / export UI.
local FLT = ForeverLootTracker
FLT.UI = FLT.UI or {}
local UI = FLT.UI
local W = FLT.Widgets

local FRAME_W, FRAME_H = 920, 560

-- GearQuest-style scene art: oversized PNG, center-cropped to the frame aspect.
local LOG_SCENE_PATH = "Interface\\AddOns\\ForeverLootTracker\\Art\\FLT-LogScene.png"
local LOG_SCENE_W, LOG_SCENE_H = 1440, 736

local function Backdrop(frame, a)
	W.Backdrop(frame, a)
end

local function ApplyLogSceneCrop(tex, frame)
	local viewW = (frame:GetWidth() or 0) - 4
	local viewH = (frame:GetHeight() or 0) - 4
	if viewW <= 1 or viewH <= 1 then
		tex:SetTexCoord(0, 1, 0, 1)
		return
	end
	local viewAspect = viewW / viewH
	local texAspect = LOG_SCENE_W / LOG_SCENE_H
	if viewAspect < texAspect then
		-- Frame is taller/narrower than art → crop left/right, keep center.
		local pad = (1 - (viewAspect / texAspect)) * 0.5
		tex:SetTexCoord(pad, 1 - pad, 0, 1)
	else
		-- Frame is wider/shorter than art → crop top/bottom, keep center.
		local pad = (1 - (texAspect / viewAspect)) * 0.5
		tex:SetTexCoord(0, 1, pad, 1 - pad)
	end
end

local function EnsureLogScene(frame)
	if frame.fltLogScene then
		ApplyLogSceneCrop(frame.fltLogScene, frame)
		return
	end
	local tex = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
	tex:SetPoint("TOPLEFT", frame, "TOPLEFT", 2, -2)
	tex:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
	tex:SetTexture(LOG_SCENE_PATH)
	ApplyLogSceneCrop(tex, frame)
	frame.fltLogScene = tex

	-- Soft darken so chrome / lists stay readable over the busy treasure pile.
	local shade = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
	shade:SetAllPoints(tex)
	shade:SetColorTexture(0.02, 0.01, 0.0, 0.42)
	frame.fltLogSceneShade = shade

	frame:HookScript("OnSizeChanged", function(self)
		if self.fltLogScene then
			ApplyLogSceneCrop(self.fltLogScene, self)
		end
	end)
end

local function MakeButton(parent, text, width)
	return W.Button(parent, text, width)
end

local function MakeCheck(parent, label)
	return W.Checkbox(parent, label)
end

local function QualityText(q, name)
	local color = FLT.QUALITY_COLORS[q or 1] or "|cffffffff"
	return color .. (name or "?") .. "|r"
end

-- Spreadsheet-style columns (WildStar sort headers). No external grid lib required —
-- lib-ScrollingTable was considered; a light in-addon column layout keeps Forever deps minimal.
-- Cost is optional (options.showCost) and packs at the far right when visible.
-- flex columns absorb leftover (or shrink) so the row always fills the list width.
local ITEM_COL_DEFS = {
	{ key = "name", label = "Name", width = 156, flex = 3 },
	{ key = "count", label = "Qty", width = 36 },
	{ key = "source", label = "Source", width = 90, flex = 2 },
	{ key = "type", label = "Type", width = 64 },
	{ key = "looter", label = "Player", width = 120, flex = 2 },
	{ key = "zone", label = "Zone", width = 84, flex = 1 },
	{ key = "time", label = "Time", width = 120, flex = 1 },
	{ key = "cost", label = "Cost", width = 48, optional = "showCost" },
}

local ITEM_ICON_PAD = 34

local function GetItemListLayoutWidth(f)
	f = f or UI.frame
	if f and f.itemHeader then
		local w = f.itemHeader:GetWidth()
		if w and w > 100 then
			return w
		end
	end
	if f and f.listBg then
		local w = f.listBg:GetWidth()
		if w and w > 100 then
			return math.max(200, w - 34) -- leave room for scrollbar gutter
		end
	end
	return 780
end

local function GetVisibleItemCols(f)
	local cols = {}
	local showCost = FLT.db and FLT.db.options and FLT.db.options.showCost == true
	local baseTotal = 0
	local flexWeight = 0
	for _, def in ipairs(ITEM_COL_DEFS) do
		if def.optional == "showCost" and not showCost then
			-- skip entirely; do not reserve width
		else
			local flex = tonumber(def.flex) or 0
			table.insert(cols, {
				key = def.key,
				label = def.label,
				width = def.width,
				flex = flex,
			})
			baseTotal = baseTotal + def.width
			flexWeight = flexWeight + flex
		end
	end

	local usable = math.max(200, GetItemListLayoutWidth(f) - ITEM_ICON_PAD)
	local slack = usable - baseTotal
	if flexWeight > 0 and slack ~= 0 then
		local assigned = 0
		local flexCount = 0
		for _, col in ipairs(cols) do
			if col.flex > 0 then
				flexCount = flexCount + 1
			end
		end
		local n = 0
		for _, col in ipairs(cols) do
			if col.flex > 0 then
				n = n + 1
				local share
				if n < flexCount then
					share = math.floor(slack * (col.flex / flexWeight))
					assigned = assigned + share
				else
					share = slack - assigned -- last flex column absorbs rounding remainder
				end
				col.width = math.max(28, col.width + share)
			end
		end
	end

	local x = ITEM_ICON_PAD
	for _, col in ipairs(cols) do
		col.x = x
		x = x + col.width
	end
	return cols
end

-- Friz Quadrata has no Unicode arrows; Blizzard's UI-SortArrow texture is the supported indicator.
local function SetHeaderSortArrow(button, active, ascending)
	if not button or not button.sortArrow then
		return
	end
	if not active then
		button.sortArrow:Hide()
		return
	end
	button.sortArrow:Show()
	if ascending then
		button.sortArrow:SetTexCoord(0, 0.5625, 1, 0) -- point up
	else
		button.sortArrow:SetTexCoord(0, 0.5625, 0, 1) -- point down
	end
end

local function EnsureItemHeaders(f)
	if f.itemHeader then
		return f.itemHeader
	end
	local hdr = CreateFrame("Frame", nil, f.listBg)
	hdr:SetPoint("TOPLEFT", 6, -4)
	hdr:SetPoint("TOPRIGHT", -28, -4)
	hdr:SetHeight(22)
	W.ApplyHeaderBand(hdr)
	hdr.buttons = {}

	for _, def in ipairs(ITEM_COL_DEFS) do
		local b = CreateFrame("Button", nil, hdr)
		b:SetSize(def.width, 20)
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
		b.fs:SetText(def.label)
		b.colKey = def.key
		b:SetScript("OnClick", function(self)
			local ui = FLT.db.ui
			if ui.sortKey == self.colKey then
				ui.sortAsc = not ui.sortAsc
			else
				ui.sortKey = self.colKey
				ui.sortAsc = (self.colKey == "name" or self.colKey == "source" or self.colKey == "looter" or self.colKey == "zone" or self.colKey == "type")
			end
			UI.Refresh()
		end)
		hdr.buttons[def.key] = b
	end
	f.itemHeader = hdr
	return hdr
end

local function LayoutItemColumns(f)
	local hdr = EnsureItemHeaders(f)
	local cols = GetVisibleItemCols(f)
	f._itemCols = cols
	for _, b in pairs(hdr.buttons) do
		b:Hide()
	end
	local ui = FLT.db and FLT.db.ui
	for _, col in ipairs(cols) do
		local b = hdr.buttons[col.key]
		if b then
			b:SetSize(col.width, 20)
			b:ClearAllPoints()
			b:SetPoint("LEFT", hdr, "LEFT", col.x, 0)
			b.fs:SetText(col.label)
			SetHeaderSortArrow(b, ui and ui.sortKey == col.key, ui and ui.sortAsc)
			b:Show()
		end
	end
	return cols
end

local function RefreshItemHeaders(f)
	LayoutItemColumns(f)
end

local function ItemSortValue(item, cached, key)
	if key == "name" then
		return string.lower((cached and cached.name) or ("item " .. tostring(item.itemID)))
	elseif key == "count" then
		return tonumber(item.count) or 0
	elseif key == "source" then
		return string.lower(item.source or "")
	elseif key == "type" then
		local t = FLT.SOURCE_NAMES[item.sourceType] or ""
		if item.rollType then
			t = t .. " " .. item.rollType
		end
		if item.sourceKind == "ItemBox" then
			t = t .. " box"
		elseif item.sourceKind == "Mail" then
			t = "mail"
		elseif item.sourceKind == "Quest" then
			t = "quest"
		elseif item.sourceKind == "Disenchant" then
			t = "disenchant"
		end
		return string.lower(t)
	elseif key == "looter" then
		return string.lower(item.looter or "")
	elseif key == "zone" then
		return string.lower(item.zone or "")
	elseif key == "cost" then
		return tonumber(item.cost) or 0
	else -- time
		return tonumber(item.time) or 0
	end
end

local function SortedItemIndices(session)
	local ui = FLT.db.ui or {}
	local key = ui.sortKey or "time"
	local asc = ui.sortAsc and true or false
	local idxs = {}
	for i = 1, #session.items do
		idxs[i] = i
	end
	table.sort(idxs, function(a, b)
		local ia, ib = session.items[a], session.items[b]
		local ca = session.itemCache[ia.itemID]
		local cb = session.itemCache[ib.itemID]
		local va, vb = ItemSortValue(ia, ca, key), ItemSortValue(ib, cb, key)
		if va == vb then
			return a > b -- stable-ish: newer index first on ties
		end
		if asc then
			return va < vb
		end
		return va > vb
	end)
	return idxs
end

local function MakeRowCell(row, width)
	local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	fs:SetWidth(width)
	fs:SetJustifyH("LEFT")
	fs:SetWordWrap(false)
	return fs
end

local function RefreshItemList()
	local f = UI.frame
	if not f then
		return
	end
	local session = FLT.GetSession()
	RefreshItemHeaders(f)
	for _, row in ipairs(f.itemRows) do
		row:Hide()
	end

	local y = -2
	local shown = 0
	local order = SortedItemIndices(session)
	for _, i in ipairs(order) do
		local item = session.items[i]
		shown = shown + 1
		local row = f.itemRows[shown]
		if not row then
			row = CreateFrame("Button", nil, f.listChild)
			row:SetSize(GetItemListLayoutWidth(f), 22)
			row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
			W.RowBackground(row, shown)
			row.watchGlow = row:CreateTexture(nil, "ARTWORK", nil, 1)
			row.watchGlow:SetAllPoints()
			row.watchGlow:SetColorTexture(0.05, 0.45, 0.12, 0.35)
			row.watchGlow:Hide()

			row.icon = row:CreateTexture(nil, "ARTWORK")
			row.icon:SetSize(18, 18)
			row.icon:SetPoint("LEFT", 4, 0)

			row.cells = {}
			for _, def in ipairs(ITEM_COL_DEFS) do
				local fs = MakeRowCell(row, def.width - 4)
				fs:SetPoint("LEFT", row, "LEFT", ITEM_ICON_PAD, 0)
				row.cells[def.key] = fs
			end

			row:SetScript("OnEnter", function(self)
				if self.link then
					GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
					GameTooltip:SetHyperlink(self.link)
					GameTooltip:Show()
				end
			end)
			row:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			row:SetScript("OnClick", function(self, button)
				if button == "LeftButton" and IsShiftKeyDown() and self.link then
					if ChatEdit_InsertLink then
						ChatEdit_InsertLink(self.link)
					end
					return
				end
				if button == "RightButton" then
					if UI.ShowItemContextMenu then
						UI.ShowItemContextMenu(self.index, self)
					else
						UI.ShowItemMenu(self.index)
					end
				else
					UI.EditItem(self.index)
				end
			end)

			f.itemRows[shown] = row
		end
		if not row._stripeLeft then
			W.RowBackground(row, shown)
		end

		local cached = session.itemCache[item.itemID]
		row.index = i
		row.link = item.link
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 4, y)

		if cached and cached.icon then
			row.icon:SetTexture(cached.icon)
		else
			row.icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
		end

		local watched = FLT.IsWatched(item.itemID)
		local name = (cached and cached.name) or ("Item " .. item.itemID)
		-- Raid-target star texture (Friz has no ★ glyph).
		local watchTag = watched and " |TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t" or ""
		local typeKey = FLT.ItemTypeIgnoreKey and FLT.ItemTypeIgnoreKey(item.sourceType, item.sourceKind)
		local typeName = (FLT.IgnoreTypeLabel and FLT.IgnoreTypeLabel(typeKey))
			or FLT.SOURCE_NAMES[item.sourceType]
			or "?"
		if item.rollType then
			typeName = typeName .. "/" .. item.rollType
		end

		local cols = f._itemCols or GetVisibleItemCols(f)
		row:SetWidth(GetItemListLayoutWidth(f))
		for _, fs in pairs(row.cells) do
			fs:Hide()
		end
		local values = {
			name = QualityText(cached and cached.quality, name) .. watchTag,
			count = tostring(item.count or 1),
			source = item.source or "?",
			type = typeName,
			looter = item.looter or "?",
			zone = item.zone or "?",
			time = FLT.FormatTime(item.time),
			cost = tostring(item.cost or 0),
		}
		for _, col in ipairs(cols) do
			local fs = row.cells[col.key]
			if fs then
				fs:SetWidth(math.max(12, col.width - 4))
				fs:ClearAllPoints()
				fs:SetPoint("LEFT", row, "LEFT", col.x, 0)
				fs:SetText(values[col.key] or "")
				fs:Show()
			end
		end

		if row.watchGlow then
			row.watchGlow:SetShown(watched)
		end

		row:Show()
		y = y - 24
	end

	f.listChild:SetHeight(math.max(1, -y + 8))
end

local function RefreshStats()
	local f = UI.frame
	if not f then
		return
	end
	local session = FLT.GetSession()
	local m = session.stats.copper or FLT.DefaultMoneyStats()
	local net = m.total or 0
	local netText = (net >= 0 and ("Net: |cff00ff00+" .. FLT.FormatMoney(net) .. "|r"))
		or ("Net: |cffff6666-" .. FLT.FormatMoney(-net) .. "|r")
	f.statTotal:SetText(netText)
	f.statHour:SetText("/hr: " .. FLT.FormatMoney(m.perHour or 0))
	f.statAvg:SetText("Earned: |cff00ff00" .. FLT.FormatMoney(m.earned or 0) .. "|r")
	f.statMax:SetText("Spent: |cffff6666" .. FLT.FormatMoney(m.spent or 0) .. "|r")
	f.statJunk:SetText(("Junk %s  |  Largest +%s / -%s"):format(
		FLT.FormatMoney(session.stats.junkValue or 0),
		FLT.FormatMoney(m.largest or 0),
		FLT.FormatMoney(m.largestLoss or 0)
	))
	f.sessionLabel:SetText("Session: " .. (session.label or "Default"))
end

-- Type dropdown values: "st:<sourceType>" or "sk:<sourceKind>" for display overrides.
local ITEM_TYPE_OPTIONS = {
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

local function ItemTypeDropdownValue(item)
	local kind = item.sourceKind
	if kind == "Gathering" or kind == "Fishing" or kind == "Mail"
		or kind == "Quest" or kind == "Disenchant" or kind == "ItemBox" then
		return "sk:" .. kind
	end
	if kind == "Vendor" then
		return "st:4"
	end
	if kind == "Crafted" then
		return "st:3"
	end
	local st = tonumber(item.sourceType)
	if st == nil then
		st = FLT.SOURCE.Dropped
	end
	return "st:" .. tostring(st)
end

local function ApplyItemTypeDropdownValue(item, value)
	value = tostring(value or "")
	local kind = value:match("^sk:(.+)$")
	if kind then
		item.sourceKind = kind
		if kind == "Disenchant" then
			item.sourceType = FLT.SOURCE.Crafted
		elseif kind == "Mail" or kind == "Quest" or kind == "Gathering" or kind == "Fishing" or kind == "ItemBox" then
			item.sourceType = FLT.SOURCE.Dropped
		end
		return
	end
	local st = tonumber(value:match("^st:(%-?%d+)$"))
	if st ~= nil then
		item.sourceType = st
		if st == FLT.SOURCE.Crafted then
			item.sourceKind = "Crafted"
		elseif st == FLT.SOURCE.Purchased then
			item.sourceKind = "Vendor"
		else
			item.sourceKind = nil
		end
	end
end

function UI.EditItem(index)
	local session = FLT.GetSession()
	local item = session.items[index]
	if not item then
		return
	end

	if UI.editFrame then
		UI.editFrame:Hide()
		UI.editFrame:SetParent(nil)
		UI.editFrame = nil
	end

	local ef = W.DialogFrame("ForeverLootTrackerEditFrame", 380, 320)

	local title = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -12)
	title:SetText("Edit Loot Entry")
	title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	local cached = session.itemCache[item.itemID]
	local info = ef:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	info:SetPoint("TOPLEFT", 16, -40)
	info:SetPoint("TOPRIGHT", -16, -40)
	info:SetJustifyH("LEFT")
	info:SetText((cached and cached.name or ("Item " .. item.itemID)) .. "\nID: " .. tostring(item.itemID))

	local costLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	costLabel:SetPoint("TOPLEFT", 16, -86)
	costLabel:SetText("Cost")
	local costBox = CreateFrame("EditBox", nil, ef, "InputBoxTemplate")
	costBox:SetSize(80, 20)
	costBox:SetPoint("LEFT", costLabel, "RIGHT", 12, 0)
	costBox:SetAutoFocus(false)
	costBox:SetText(tostring(item.cost or 0))

	local looterLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	looterLabel:SetPoint("TOPLEFT", 16, -116)
	looterLabel:SetText("Looter")
	local looterBox = CreateFrame("EditBox", nil, ef, "InputBoxTemplate")
	looterBox:SetSize(200, 20)
	looterBox:SetPoint("LEFT", looterLabel, "RIGHT", 12, 0)
	looterBox:SetAutoFocus(false)
	looterBox:SetText(item.looter or "")

	local sourceLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	sourceLabel:SetPoint("TOPLEFT", 16, -146)
	sourceLabel:SetText("Source")
	local sourceBox = CreateFrame("EditBox", nil, ef, "InputBoxTemplate")
	sourceBox:SetSize(220, 20)
	sourceBox:SetPoint("LEFT", sourceLabel, "RIGHT", 12, 0)
	sourceBox:SetAutoFocus(false)
	sourceBox:SetText(item.source or "")

	local typeLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	typeLabel:SetPoint("TOPLEFT", 16, -176)
	typeLabel:SetText("Type")
	local typeDD = W.Dropdown(ef, 160, ITEM_TYPE_OPTIONS)
	typeDD:SetPoint("LEFT", typeLabel, "RIGHT", 12, 0)
	typeDD:SetValue(ItemTypeDropdownValue(item))

	local watchName = (cached and cached.name) or ("Item " .. tostring(item.itemID))
	local watchBtn = MakeButton(ef, FLT.IsWatched(item.itemID) and "Unwatch" or "Watch", 80)
	watchBtn:SetPoint("TOPLEFT", 16, -214)
	watchBtn:SetScript("OnClick", function(self)
		local watching = UI.ToggleWatch(item.itemID, watchName)
		self:SetText(watching and "Unwatch" or "Watch")
		UI.Refresh()
	end)

	local save = MakeButton(ef, "Save", 80)
	save:SetPoint("BOTTOMLEFT", 16, 16)
	save:SetScript("OnClick", function()
		item.cost = tonumber(costBox:GetText()) or item.cost
		item.looter = looterBox:GetText() or item.looter
		item.source = sourceBox:GetText() or item.source
		ApplyItemTypeDropdownValue(item, typeDD:GetValue())
		ef:Hide()
		UI.Refresh()
	end)

	local del = MakeButton(ef, "Delete", 80)
	del:SetPoint("LEFT", save, "RIGHT", 8, 0)
	del:SetScript("OnClick", function()
		local name = (cached and cached.name) or ("Item " .. tostring(item.itemID))
		StaticPopupDialogs["FLT_CONFIRM_DELETE_ENTRY"] = StaticPopupDialogs["FLT_CONFIRM_DELETE_ENTRY"] or {
			text = "Delete tracked loot entry \"%s\"?",
			button1 = YES,
			button2 = NO,
			OnAccept = function(_, data)
				if not data or not data.index then
					return
				end
				local sess = FLT.GetSession()
				table.remove(sess.items, data.index)
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
		ef:Hide()
		StaticPopup_Show("FLT_CONFIRM_DELETE_ENTRY", name, nil, { index = index })
	end)

	local cancel = MakeButton(ef, "Cancel", 80)
	cancel:SetPoint("BOTTOMRIGHT", -16, 16)
	cancel:SetScript("OnClick", function()
		ef:Hide()
	end)

	UI.editFrame = ef
	ef:Show()
end

StaticPopupDialogs["FLT_CONFIRM_IGNORE_RULE"] = {
	text = "Ignore %s and remove all matching tracked entries?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, data)
		if not data or not data.kind or not data.value then
			return
		end
		if data.kind == "item" and data.itemID then
			FLT.SetListValue(FLT.GetWatchedList(), data.itemID, nil)
		end
		local rule = FLT.AddIgnoreRule(data.kind, data.value, data.label)
		if rule then
			FLT.PurgeSessionItemsMatchingIgnore(rule)
		end
		UI.Refresh()
		if UI.RefreshIgnoredPanel then
			UI.RefreshIgnoredPanel()
		end
		if FLT.RefreshObjectiveTracker then
			FLT.RefreshObjectiveTracker()
		end
		FLT.Print("Ignored " .. tostring(data.label or data.value))
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

-- Back-compat alias for older callers.
StaticPopupDialogs["FLT_CONFIRM_IGNORE_ITEM"] = StaticPopupDialogs["FLT_CONFIRM_IGNORE_RULE"]

function UI.PromptIgnoreRule(kind, value, label, itemID)
	kind = tostring(kind or "item")
	value = tostring(value or "")
	label = label or value
	if value == "" then
		return
	end
	local desc
	if kind == "item" then
		desc = ("item %s"):format(label)
	elseif kind == "name" then
		desc = ("names containing \"%s\""):format(value)
	elseif kind == "source" then
		desc = ("sources containing \"%s\""):format(value)
	elseif kind == "type" then
		desc = ("type %s"):format(FLT.IgnoreTypeLabel and FLT.IgnoreTypeLabel(value) or label)
	else
		desc = tostring(label)
	end
	StaticPopup_Show("FLT_CONFIRM_IGNORE_RULE", desc, nil, {
		kind = kind,
		value = value,
		label = label,
		itemID = itemID,
	})
end

function UI.ShowIgnorePatternDialog(kind, defaultValue, itemID)
	if UI.ignorePatternFrame then
		UI.ignorePatternFrame:Hide()
		UI.ignorePatternFrame = nil
	end
	kind = tostring(kind or "name")
	local titleText = (kind == "source") and "Ignore Source Match" or "Ignore Name Match"
	local helpText = (kind == "source")
		and "Ignore future loot whose Source contains this text (partial match)."
		or "Ignore future loot whose Name contains this text (partial match)."

	local ef = W.DialogFrame("ForeverLootTrackerIgnorePattern", 420, 180)
	local title = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText(titleText)
	title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	local help = ef:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	help:SetPoint("TOPLEFT", 16, -44)
	help:SetPoint("TOPRIGHT", -16, -44)
	help:SetJustifyH("LEFT")
	help:SetText(helpText)

	local box = W.EditBox(ef, 360)
	box:SetPoint("TOPLEFT", 20, -78)
	box:SetText(tostring(defaultValue or ""))
	box:HighlightText()
	box:SetFocus()

	local cancel = MakeButton(ef, "Cancel", 80)
	cancel:SetPoint("BOTTOMRIGHT", -16, 16)
	cancel:SetScript("OnClick", function()
		ef:Hide()
	end)

	local ok = MakeButton(ef, "Ignore", 80)
	ok:SetPoint("RIGHT", cancel, "LEFT", -8, 0)
	local function Accept()
		local needle = box:GetText() or ""
		needle = needle:gsub("^%s+", ""):gsub("%s+$", "")
		ef:Hide()
		if needle == "" then
			return
		end
		UI.PromptIgnoreRule(kind, needle, needle, itemID)
	end
	ok:SetScript("OnClick", Accept)
	box:SetScript("OnEnterPressed", Accept)

	UI.ignorePatternFrame = ef
	ef:Show()
end

function UI.ToggleWatch(itemID, name)
	name = name or ("Item " .. tostring(itemID))
	if FLT.IsWatched(itemID) then
		FLT.SetListValue(FLT.GetWatchedList(), itemID, nil)
		FLT.Print("Removed watch: " .. name)
		if FLT.RefreshObjectiveTracker then
			FLT.RefreshObjectiveTracker()
		end
		return false
	end
	FLT.SetListValue(FLT.GetWatchedList(), itemID, name)
	FLT.SetListValue(FLT.db.user.ignored, itemID, nil)
	-- Drop any exact-item ignore rule so watch can receive the item again.
	if FLT.GetIgnoreRules then
		for _, rule in ipairs(FLT.GetIgnoreRules()) do
			if rule.kind == "item" and tostring(rule.value) == tostring(itemID) then
				FLT.RemoveIgnoreRule(rule.id)
				break
			end
		end
	end
	FLT.Print("|cff00ff00Watching:|r " .. name .. " — you'll get an alert when it drops again.")
	if FLT.RefreshObjectiveTracker then
		FLT.RefreshObjectiveTracker()
	end
	return true
end

-- Legacy ignore shortcut kept for callers that still expect ShowItemMenu.
function UI.ShowItemMenu(index)
	if UI.ShowItemContextMenu then
		UI.ShowItemContextMenu(index)
		return
	end
	local session = FLT.GetSession()
	local item = session.items[index]
	if not item then
		return
	end
	local itemID = item.itemID
	local cached = session.itemCache[itemID]
	local name = cached and cached.name or ("Item " .. itemID)
	if IsShiftKeyDown() then
		UI.ToggleWatch(itemID, name)
		UI.Refresh()
		return
	end
	UI.PromptIgnoreRule("item", tostring(itemID), name, itemID)
end

function UI.ShowExport()
	if UI.exportFrame then
		UI.exportFrame:Hide()
		UI.exportFrame = nil
	end

	local ef = W.DialogFrame("ForeverLootTrackerExportFrame", 520, 420)

	local title = ef:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -12)
	title:SetText("Export Loot")
	title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	local selected = FLT.db.options.exportFormat or FLT.EXPORT.csv
	local formatLabel = ef:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	formatLabel:SetPoint("TOPLEFT", 16, -42)
	formatLabel:SetText("Format")

	local formatDD = W.Dropdown(ef, 160, {
		{ value = FLT.EXPORT.csv, text = "CSV" },
		{ value = FLT.EXPORT.json, text = "JSON" },
		{ value = FLT.EXPORT.bbcode, text = "BBCode" },
		{ value = FLT.EXPORT.html, text = "HTML" },
	}, function(value)
		selected = value
		FLT.db.options.exportFormat = value
		ef.box:SetText(FLT.GenerateExportString(selected))
		ef.box:HighlightText()
		ef.box:SetFocus()
	end)
	formatDD:SetPoint("LEFT", formatLabel, "RIGHT", 10, 0)
	formatDD:SetValue(selected)

	local scroll = CreateFrame("ScrollFrame", "ForeverLootTrackerExportScroll", ef, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -70)
	scroll:SetPoint("BOTTOMRIGHT", -36, 50)

	local box = CreateFrame("EditBox", nil, scroll)
	box:SetMultiLine(true)
	box:SetFontObject(GameFontHighlightSmall)
	box:SetWidth(460)
	box:SetAutoFocus(false)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	scroll:SetScrollChild(box)
	ef.box = box
	box:SetText(FLT.GenerateExportString(selected))

	local copyHint = ef:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	copyHint:SetPoint("BOTTOMLEFT", 16, 18)
	copyHint:SetText("Click a format, then Ctrl+C to copy.")

	local close = MakeButton(ef, "Close", 80)
	close:SetPoint("BOTTOMRIGHT", -16, 14)
	close:SetScript("OnClick", function()
		ef:Hide()
	end)

	UI.exportFrame = ef
	ef:Show()
	box:HighlightText()
	box:SetFocus()
end

local function EnsureOptions(parent)
	if UI.optionsFrame then
		return UI.optionsFrame
	end
	local of = CreateFrame("Frame", nil, parent)
	of:SetAllPoints()
	of:Hide()

	local title = of:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 12, -12)
	title:SetText("Options")
	title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	of.persist = MakeCheck(of, "Persist session between logins")
	of.persist:SetPoint("TOPLEFT", 12, -48)
	of.persist:SetScript("OnClick", function(self)
		FLT.db.options.persistSession = self:GetChecked()
	end)

	of.trackMoney = MakeCheck(of, "Track money")
	of.trackMoney:SetPoint("TOPLEFT", 12, -76)
	of.trackMoney:SetScript("OnClick", function(self)
		FLT.db.options.trackMoney = self:GetChecked()
	end)

	of.trackParty = MakeCheck(of, "Track party/raid loot")
	of.trackParty:SetPoint("TOPLEFT", 12, -104)
	of.trackParty:SetScript("OnClick", function(self)
		FLT.db.options.trackPartyLoot = self:GetChecked()
	end)

	of.minimapBtn = MakeCheck(of, "Show minimap button")
	of.minimapBtn:SetPoint("TOPLEFT", 12, -132)
	of.minimapBtn:SetScript("OnClick", function(self)
		if FLT.Minimap and FLT.Minimap.SetShown then
			FLT.Minimap.SetShown(self:GetChecked())
		else
			FLT.db.options.showMinimapButton = self:GetChecked()
		end
	end)

	of.showCost = MakeCheck(of, "Show Cost")
	of.showCost:SetPoint("TOPLEFT", 220, -132)
	of.showCost:SetScript("OnClick", function(self)
		FLT.db.options.showCost = self:GetChecked() and true or false
		UI.Refresh()
	end)

	local timeLabel = of:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	timeLabel:SetPoint("TOPLEFT", 12, -168)
	timeLabel:SetText("Timestamp format")

	of.timeRadios = W.RadioGroup(of, {
		{ value = "12h", text = "12-hour", width = 90 },
		{ value = "24h", text = "24-hour", width = 90 },
	}, function(value)
		FLT.db.options.timeFormat = value
		UI.Refresh()
	end)
	of.timeRadios:SetPoint("TOPLEFT", 12, -188)

	local exportLabel = of:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	exportLabel:SetPoint("TOPLEFT", 220, -168)
	exportLabel:SetText("Default export format")

	of.exportDD = W.Dropdown(of, 160, {
		{ value = FLT.EXPORT.csv, text = "CSV" },
		{ value = FLT.EXPORT.json, text = "JSON" },
		{ value = FLT.EXPORT.bbcode, text = "BBCode" },
		{ value = FLT.EXPORT.html, text = "HTML" },
	}, function(value)
		FLT.db.options.exportFormat = value
	end)
	of.exportDD:SetPoint("TOPLEFT", 220, -188)

	local costLabel = of:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	costLabel:SetPoint("TOPLEFT", 12, -228)
	costLabel:SetText("Default item cost")
	of.costBox = W.EditBox(of, 80)
	of.costBox:SetPoint("LEFT", costLabel, "RIGHT", 12, 0)
	of.costBox:SetScript("OnEnterPressed", function(self)
		FLT.db.options.defaultCost = tonumber(self:GetText()) or 0
		self:ClearFocus()
	end)
	of.costBox:SetScript("OnEditFocusLost", function(self)
		FLT.db.options.defaultCost = tonumber(self:GetText()) or 0
	end)

	local qTitle = of:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	qTitle:SetPoint("TOPLEFT", 12, -268)
	qTitle:SetText("Quality filters")

	of.qualityChecks = {}
	local positions = {
		[0] = { 12, -293 },
		[1] = { 120, -293 },
		[2] = { 240, -293 },
		[3] = { 360, -293 },
		[4] = { 12, -323 },
		[5] = { 120, -323 },
		[6] = { 240, -323 },
		[7] = { 360, -323 },
	}
	for q, pos in pairs(positions) do
		local c = MakeCheck(of, FLT.QUALITY_NAMES[q])
		c:SetPoint("TOPLEFT", pos[1], pos[2])
		c.quality = q
		c:SetScript("OnClick", function(self)
			FLT.db.options.qualityFilters[self.quality] = self:GetChecked()
		end)
		of.qualityChecks[q] = c
	end

	local sTitle = of:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	sTitle:SetPoint("TOPLEFT", 12, -363)
	sTitle:SetText("Source filters")

	of.sourceChecks = {}
	local sources = { 0, 1, 2, 3, 4 } -- Dropped, Rolled, Master, Crafted, Purchased
	local sx = 12
	for _, src in ipairs(sources) do
		local c = MakeCheck(of, FLT.SOURCE_NAMES[src])
		c:SetPoint("TOPLEFT", sx, -388)
		c.source = src
		c:SetScript("OnClick", function(self)
			FLT.db.options.sourceFilters[self.source] = self:GetChecked()
		end)
		of.sourceChecks[src] = c
		sx = sx + 100
	end

	UI.optionsFrame = of
	return of
end

local function EnsureWatchPanel(parent)
	if UI.watchFrame then
		return UI.watchFrame
	end

	local wf = CreateFrame("Frame", nil, parent)
	wf:SetAllPoints()
	wf:Hide()

	wf.title = wf:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	wf.title:SetPoint("TOPLEFT", 12, -12)
	wf.title:SetText("Watch List")
	wf.title:SetTextColor(W.COLORS.gold[1], W.COLORS.gold[2], W.COLORS.gold[3])

	wf.subtitle = wf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	wf.subtitle:SetPoint("TOPLEFT", 12, -34)
	wf.subtitle:SetPoint("TOPRIGHT", -12, -34)
	wf.subtitle:SetJustifyH("LEFT")
	wf.subtitle:SetText("Per-character watches. Alerts in chat / errors / raid warning on drop. Click Remove to unwatch.")

	wf.scroll = W.CreateScrollFrame(wf, "ForeverLootTrackerWatchScroll")
	wf.scroll:SetPoint("TOPLEFT", 8, -58)
	wf.scroll:SetPoint("BOTTOMRIGHT", -28, 40)

	wf.child = CreateFrame("Frame", nil, wf.scroll)
	wf.child:SetSize(620, 1)
	wf.scroll:SetScrollChild(wf.child)
	wf.rows = {}

	wf.empty = wf:CreateFontString(nil, "OVERLAY", "GameFontDisable")
	wf.empty:SetPoint("CENTER", 0, 20)
	wf.empty:SetText(FLT.FormatClickHints(
		"No watched items yet.\nShift+Right Click a loot row, or use Watch in the edit window."
	))

	wf.clearAll = MakeButton(wf, "Clear Watch List", 130)
	wf.clearAll:SetPoint("BOTTOMLEFT", 12, 10)
	wf.clearAll:SetScript("OnClick", function()
		StaticPopupDialogs["FLT_CLEAR_WATCH"] = StaticPopupDialogs["FLT_CLEAR_WATCH"] or {
			text = "Clear this character's watch list?",
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				wipe(FLT.GetWatchedList())
				UI.RefreshWatchList()
				UI.Refresh()
				if FLT.RefreshObjectiveTracker then
					FLT.RefreshObjectiveTracker()
				end
				FLT.Print("Watch list cleared.")
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
		StaticPopup_Show("FLT_CLEAR_WATCH")
	end)

	UI.watchFrame = wf
	return wf
end

function UI.RefreshWatchList()
	local wf = UI.watchFrame
	if not wf then
		return
	end

	for _, row in ipairs(wf.rows) do
		row:Hide()
	end

	local entries = {}
	for id, name in pairs(FLT.GetWatchedList()) do
		local itemID = tonumber(id) or id
		table.insert(entries, { itemID = itemID, name = name or ("Item " .. tostring(itemID)) })
	end
	table.sort(entries, function(a, b)
		return tostring(a.name) < tostring(b.name)
	end)

	wf.title:SetText(("Watch List (%d)"):format(#entries))
	wf.empty:SetShown(#entries == 0)

	local y = -2
	for i, entry in ipairs(entries) do
		local row = wf.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, wf.child)
			row:SetSize(600, 32)
			W.RowBackground(row, i)

			row.icon = row:CreateTexture(nil, "ARTWORK")
			row.icon:SetSize(24, 24)
			row.icon:SetPoint("LEFT", 6, 0)

			row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			row.name:SetPoint("LEFT", 36, 0)
			row.name:SetPoint("RIGHT", -100, 0)
			row.name:SetJustifyH("LEFT")

			row.idfs = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			row.idfs:SetPoint("RIGHT", -100, 0)
			row.idfs:SetWidth(80)
			row.idfs:SetJustifyH("RIGHT")

			row.remove = MakeButton(row, "Remove", 70)
			row.remove:SetPoint("RIGHT", -8, 0)
			row.remove:SetScript("OnClick", function(self)
				local parent = self:GetParent()
				UI.ToggleWatch(parent.itemID, parent.itemName)
				UI.RefreshWatchList()
				UI.Refresh()
			end)

			wf.rows[i] = row
		end

		row.itemID = entry.itemID
		row.itemName = entry.name
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 4, y)

		local icon
		if C_Item and C_Item.GetItemIconByID then
			icon = C_Item.GetItemIconByID(entry.itemID)
		end
		if not icon then
			local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(entry.itemID)
			icon = tex
		end
		row.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
		row.name:SetText("|cff00ff00" .. tostring(entry.name) .. "|r")
		row.idfs:SetText("ID " .. tostring(entry.itemID))
		row:Show()
		y = y - 36
	end

	wf.child:SetHeight(math.max(1, -y + 8))
end

local SIDE_TABS = {
	{ id = "items", tooltip = "Items", icon = "INV_Misc_Bag_10" },
	{ id = "money", tooltip = "Money", icon = "INV_Misc_Coin_02" },
	{ id = "sessions", tooltip = "Sessions", icon = "INV_Misc_Book_09" },
	{ id = "watch", tooltip = "Watch", icon = "Spell_Holy_BorrowedTime" },
	{ id = "ignored", tooltip = "Ignored", icon = "INV_Misc_Bone_HumanSkull_01" },
	{ id = "options", tooltip = "Options", icon = "INV_Misc_Gear_01" },
}

local function SyncOptionsPanel(f)
	local of = f.optionsPanel
	if not of then
		return
	end
	of.persist:SetChecked(FLT.db.options.persistSession)
	of.trackMoney:SetChecked(FLT.db.options.trackMoney)
	of.trackParty:SetChecked(FLT.db.options.trackPartyLoot)
	if of.minimapBtn then
		of.minimapBtn:SetChecked(FLT.db.options.showMinimapButton ~= false)
	end
	if of.showCost then
		of.showCost:SetChecked(FLT.db.options.showCost == true)
	end
	of.timeRadios:SetValue(FLT.db.options.timeFormat or "24h")
	of.exportDD:SetValue(FLT.db.options.exportFormat or FLT.EXPORT.csv)
	of.costBox:SetText(tostring(FLT.db.options.defaultCost or 0))
	for q, c in pairs(of.qualityChecks) do
		c:SetChecked(FLT.db.options.qualityFilters[q] ~= false)
	end
	for s, c in pairs(of.sourceChecks) do
		c:SetChecked(FLT.db.options.sourceFilters[s] ~= false)
	end
end

local function ShowMainPanel(which)
	local f = UI.frame
	if not f then
		return
	end
	f.activePanel = which
	local showItems = (which == "items")
	f.listScroll:SetShown(showItems)
	-- MinimalScrollBar may be a sibling of older frames; always drive it explicitly.
	local itemBar = f.listScroll.ScrollBar or f.listScroll.scrollBar
	if itemBar then
		itemBar:SetShown(showItems)
	end
	if f.itemHeader then
		f.itemHeader:SetShown(showItems)
	end
	if f.addBtn then
		f.addBtn:SetShown(showItems)
	end
	f.optionsPanel:SetShown(which == "options")
	f.watchPanel:SetShown(which == "watch")
	if f.moneyPanel then
		f.moneyPanel:SetShown(which == "money")
		if which == "money" then
			f.moneyPanel:SetFrameLevel((f.listBg:GetFrameLevel() or 1) + 20)
		end
	end
	if f.sessionsPanel then
		f.sessionsPanel:SetShown(which == "sessions")
	end
	if f.ignoredPanel then
		f.ignoredPanel:SetShown(which == "ignored")
	end
	if f.sideTabs then
		for id, tab in pairs(f.sideTabs) do
			tab:SetActive(id == which)
		end
	end
	if f.panelTip then
		-- Tip ends at the leftmost footer action still visible.
		local tipAnchor = (showItems and f.addBtn) or f.recBtn or f.exportBtn
		f.panelTip:ClearAllPoints()
		f.panelTip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 70, 12)
		if tipAnchor then
			f.panelTip:SetPoint("TOPRIGHT", tipAnchor, "TOPLEFT", -10, 0)
		else
			f.panelTip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -220, 12)
		end
		if which == "items" then
			f.panelTip:SetText(UI.ITEMS_PANEL_TIP or "")
			f.panelTip:Show()
		elseif which == "money" then
			f.panelTip:SetText(UI.MONEY_PANEL_TIP or "")
			f.panelTip:Show()
		else
			f.panelTip:SetText("")
			f.panelTip:Hide()
		end
	end
	if which == "options" then
		SyncOptionsPanel(f)
	elseif which == "watch" then
		UI.RefreshWatchList()
	elseif which == "money" and UI.RefreshMoneyPanel then
		UI.RefreshMoneyPanel()
	elseif which == "sessions" and UI.RefreshSessionsPanel then
		UI.RefreshSessionsPanel()
	elseif which == "ignored" and UI.RefreshIgnoredPanel then
		UI.RefreshIgnoredPanel()
	end
end

function UI.ShowPanel(which)
	EnsureFrame()
	ShowMainPanel(which or "items")
end

local function EnsureFrame()
	if UI.frame then
		return UI.frame
	end

	local template = "ButtonFrameTemplate"
	if C_XMLUtil and C_XMLUtil.GetTemplateInfo then
		local ok, info = pcall(C_XMLUtil.GetTemplateInfo, "PortraitFrameTemplate")
		if ok and info then
			template = "PortraitFrameTemplate"
		end
	end

	local f = CreateFrame("Frame", "ForeverLootTrackerFrame", UIParent, template)
	f:SetSize(FRAME_W, FRAME_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, _, x, y = self:GetPoint(1)
		FLT.db.ui.point = point
		FLT.db.ui.x = x
		FLT.db.ui.y = y
	end)
	f:HookScript("OnShow", function(self)
		self:Raise()
		EnsureLogScene(self)
	end)
	f:Hide()
	tinsert(UISpecialFrames, "ForeverLootTrackerFrame")

	EnsureLogScene(f)

	if ButtonFrameTemplate_HidePortrait and template == "PortraitFrameTemplate" then
		pcall(ButtonFrameTemplate_HidePortrait, f)
	elseif f.SetPortraitShown then
		pcall(f.SetPortraitShown, f, false)
	end
	-- Clear stock portrait/button fills so list transparency isn't sitting on an opaque plate.
	for _, key in ipairs({ "Bg", "Background", "BlackBackground" }) do
		local tex = f[key]
		if type(tex) == "table" and tex.Hide then
			tex:Hide()
		end
	end
	if type(f.Inset) == "table" then
		if type(f.Inset.Bg) == "table" and f.Inset.Bg.Hide then
			f.Inset.Bg:Hide()
		end
		if type(f.Inset.NineSlice) == "table" and f.Inset.NineSlice.SetCenterColor then
			pcall(f.Inset.NineSlice.SetCenterColor, f.Inset.NineSlice, 0, 0, 0, 0)
		end
	end

	if f.TitleText then
		f.TitleText:SetText("Forever Loot Tracker")
	elseif f.TitleContainer and f.TitleContainer.TitleText then
		f.TitleContainer.TitleText:SetText("Forever Loot Tracker")
	end
	local portrait = f.portrait or (f.PortraitContainer and f.PortraitContainer.portrait)
	if portrait and portrait.SetTexture then
		portrait:SetTexture("Interface\\Icons\\INV_Misc_Bag_10")
	end
	local close = f.CloseButton
	if type(close) == "table" then
		close:SetScript("OnClick", function()
			f:Hide()
		end)
	end

	f.sessionLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.sessionLabel:SetPoint("TOPLEFT", 18, -32)
	f.countLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.countLabel:SetPoint("LEFT", f.sessionLabel, "RIGHT", 16, 0)

	-- Stats strip (warm header band)
	f.stats = CreateFrame("Frame", nil, f)
	f.stats:SetPoint("TOPLEFT", 70, -56)
	f.stats:SetPoint("TOPRIGHT", -12, -56)
	f.stats:SetHeight(40)
	W.ApplyHeaderBand(f.stats)

	f.statTotal = f.stats:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.statTotal:SetPoint("LEFT", 10, 8)
	f.statHour = f.stats:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.statHour:SetPoint("LEFT", 180, 8)
	f.statAvg = f.stats:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.statAvg:SetPoint("LEFT", 340, 8)
	f.statMax = f.stats:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.statMax:SetPoint("LEFT", 500, 8)
	f.statJunk = f.stats:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.statJunk:SetPoint("LEFT", 10, -10)

	-- Side icon tabs (navigation)
	f.sideTabBar = CreateFrame("Frame", nil, f)
	f.sideTabBar:SetPoint("TOPLEFT", 4, -100)
	f.sideTabBar:SetSize(58, 360)
	f.sideTabs = {}
	for i, def in ipairs(SIDE_TABS) do
		local tab = W.SideTab(f.sideTabBar, 54)
		tab:SetPoint("TOPLEFT", 0, -((i - 1) * 58))
		tab:SetIcon(def.icon)
		tab.tooltip = def.tooltip
		tab.panelId = def.id
		tab:SetScript("OnClick", function(self)
			ShowMainPanel(self.panelId)
			if self.panelId == "items" then
				UI.Refresh()
			end
		end)
		f.sideTabs[def.id] = tab
	end
	-- Compatibility alias for ObjectiveTracker / older callers.
	f.watchBtn = f.sideTabs.watch

	-- Content inset well (semi-transparent so the centered log scene shows through)
	f.listBg = CreateFrame("Frame", nil, f)
	f.listBg:SetPoint("TOPLEFT", 66, -102)
	f.listBg:SetPoint("BOTTOMRIGHT", -12, 42)
	-- Pane stays mostly clear (alpha ~0.33) so semi-transparent rows reveal the scene.
	W.AddInset(f, 66, -102, -12, 42, nil, 0.33)

	EnsureItemHeaders(f)
	f.listScroll = W.CreateScrollFrame(f.listBg, "ForeverLootTrackerListScroll")
	f.listScroll:SetPoint("TOPLEFT", 6, -28)
	f.listScroll:SetPoint("BOTTOMRIGHT", -28, 6)
	f.listChild = CreateFrame("Frame", nil, f.listScroll)
	f.listChild:SetSize(800, 1)
	f.listScroll:SetScrollChild(f.listChild)
	f.itemRows = {}

	f.queueLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	f.queueLabel:SetPoint("TOPRIGHT", -16, -32)
	f.queueLabel:SetText("")

	f.optionsPanel = EnsureOptions(f.listBg)
	f.watchPanel = EnsureWatchPanel(f.listBg)
	f.moneyPanel = UI.EnsureMoneyPanel and UI.EnsureMoneyPanel(f.listBg)
	f.sessionsPanel = UI.EnsureSessionsPanel and UI.EnsureSessionsPanel(f.listBg)
	f.ignoredPanel = UI.EnsureIgnoredPanel and UI.EnsureIgnoredPanel(f.listBg)

	-- Footer actions only (right-aligned)
	f.clearBtn = MakeButton(f, "Clear", 58)
	f.clearBtn:SetPoint("BOTTOMRIGHT", -14, 12)
	f.clearBtn:SetScript("OnClick", function()
		StaticPopupDialogs["FLT_CLEAR_SESSION"] = StaticPopupDialogs["FLT_CLEAR_SESSION"] or {
			text = "Clear all tracked loot and money for this session?",
			button1 = YES,
			button2 = NO,
			OnAccept = function()
				FLT.ClearSession()
			end,
			timeout = 0,
			whileDead = true,
			hideOnEscape = true,
			preferredIndex = 3,
		}
		StaticPopup_Show("FLT_CLEAR_SESSION")
	end)

	f.exportBtn = MakeButton(f, "Export", 64)
	f.exportBtn:SetPoint("RIGHT", f.clearBtn, "LEFT", -6, 0)
	f.exportBtn:SetScript("OnClick", function()
		UI.ShowExport()
	end)

	f.recBtn = MakeButton(f, "Pause", 64)
	f.recBtn:SetPoint("RIGHT", f.exportBtn, "LEFT", -6, 0)
	f.recBtn:SetScript("OnClick", function()
		FLT.ToggleRecording()
	end)

	f.addBtn = MakeButton(f, "Add", 54)
	f.addBtn:SetPoint("RIGHT", f.recBtn, "LEFT", -6, 0)
	f.addBtn:SetScript("OnClick", function()
		if UI.ShowAddItem then
			UI.ShowAddItem()
		end
	end)

	-- Panel tips live in the footer (Items / Money only). Friz has no bold face;
	-- ClickHint uses gold markup as the Forever stand-in for bold action words.
	local C = FLT.ClickHint
	UI.ITEMS_PANEL_TIP = table.concat({
		C("Left Click"), " edit. ",
		C("Right Click"), " menu (Edit/Watch/Ignore/Delete). ",
		C("Shift+Left Click"), " link. ",
		C("Shift+Right Click"), " watch.",
	})
	UI.MONEY_PANEL_TIP = table.concat({
		C("Left Click"), " edit. ",
		C("Right Click"), " menu (Edit/Delete).",
	})

	f.panelTip = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	-- Same vertical band as Add/Pause/Export/Clear (middle-aligned in that row).
	f.panelTip:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 70, 12)
	f.panelTip:SetPoint("TOPRIGHT", f.addBtn, "TOPLEFT", -10, 0)
	f.panelTip:SetJustifyH("LEFT")
	f.panelTip:SetJustifyV("MIDDLE")
	f.panelTip:SetWordWrap(false)
	f.panelTip:SetText(UI.ITEMS_PANEL_TIP)
	f.panelTip:Show()

	UI.frame = f
	UI.RefreshRecordingButton()
	return f
end

local function CountWatched()
	local n = 0
	for _ in pairs(FLT.GetWatchedList()) do
		n = n + 1
	end
	return n
end

function UI.Refresh()
	local f = EnsureFrame()
	if not FLT.db then
		return
	end
	RefreshStats()
	RefreshItemList()
	local session = FLT.GetSession()
	f.countLabel:SetText(("%d items  |  %d money  |  %d cur  |  %d watched"):format(
		#session.items,
		#session.money,
		#(session.currencies or {}),
		CountWatched()
	))
	UI.RefreshQueueIndicator()
	if f.watchPanel and f.watchPanel:IsShown() then
		UI.RefreshWatchList()
	end
	if f.moneyPanel and f.moneyPanel:IsShown() and UI.RefreshMoneyPanel then
		UI.RefreshMoneyPanel()
	end
	if f.sessionsPanel and f.sessionsPanel:IsShown() and UI.RefreshSessionsPanel then
		UI.RefreshSessionsPanel()
	end
	if f.ignoredPanel and f.ignoredPanel:IsShown() and UI.RefreshIgnoredPanel then
		UI.RefreshIgnoredPanel()
	end
	UI.RefreshRecordingButton()
end

function UI.RefreshIfShown()
	if UI.frame and UI.frame:IsShown() then
		UI.Refresh()
	end
end

function UI.RefreshQueueIndicator()
	local f = UI.frame
	if not f or not f.queueLabel then
		return
	end
	local n = FLT.QueueSize and FLT.QueueSize() or 0
	if n > 0 then
		f.queueLabel:SetText("|cffffcc00Processing " .. n .. "…|r")
	else
		f.queueLabel:SetText("")
	end
end

function UI.Toggle()
	local f = EnsureFrame()
	if f:IsShown() then
		f:Hide()
	else
		if FLT.db and FLT.db.ui then
			f:ClearAllPoints()
			f:SetPoint(FLT.db.ui.point or "CENTER", UIParent, FLT.db.ui.point or "CENTER", FLT.db.ui.x or 0, FLT.db.ui.y or 0)
		end
		ShowMainPanel("items")
		UI.Refresh()
		f:Show()
	end
end
