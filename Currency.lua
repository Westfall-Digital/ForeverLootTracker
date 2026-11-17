-- ForeverLootTracker — non-gold currency tracking.
-- Primary: CURRENCY_DISPLAY_UPDATE → wallet list diff (works in instances).
-- Secondary: CHAT_MSG_CURRENCY only stamps recent gains so Diff can skip duplicates
-- when chat is readable (outside instances).
local FLT = ForeverLootTracker

local lastCounts = {} -- [currencyID] = amount
local recentChatAt = {} -- [currencyID] = GetTime() — suppress duplicate diff gains
local pendingNames = {} -- [currencyID] = name from readable chat

local function Readable(v)
	if v == nil or v == "" then
		return nil
	end
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

local function DefaultCurrencyStats()
	return {
		total = 0,
		earned = 0,
		spent = 0,
		count = 0,
		largest = 0,
		largestLoss = 0,
	}
end

function FLT.EnsureCurrencyStats(currencyID)
	local session = FLT.GetSession()
	session.stats.currencies = session.stats.currencies or {}
	local key = tonumber(currencyID) or currencyID
	if not session.stats.currencies[key] then
		session.stats.currencies[key] = DefaultCurrencyStats()
	end
	return session.stats.currencies[key]
end

function FLT.UpdateCurrencyStats(currencyID, amount)
	local m = FLT.EnsureCurrencyStats(currencyID)
	amount = tonumber(amount) or 0
	m.total = m.total + amount
	m.count = m.count + 1
	if amount > 0 then
		m.earned = m.earned + amount
		if amount > m.largest then
			m.largest = amount
		end
	elseif amount < 0 then
		local loss = -amount
		m.spent = m.spent + loss
		if loss > m.largestLoss then
			m.largestLoss = loss
		end
	end
end

local function CurrencyInfo(id)
	id = tonumber(id)
	if not id then
		return nil
	end
	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
		if ok and info then
			return {
				id = id,
				name = info.name,
				icon = info.iconFileID or info.icon,
				quantity = info.quantity,
			}
		end
	end
	if GetCurrencyInfo then
		local ok, name, count, icon = pcall(GetCurrencyInfo, id)
		if ok and name then
			return { id = id, name = name, icon = icon, quantity = count }
		end
	end
	return { id = id, name = "Currency " .. id }
end

function FLT.GetCurrencyInfoCached(id)
	return CurrencyInfo(id)
end

function FLT.CommitCurrencyRecord(entry)
	if not entry then
		return
	end
	local session = FLT.GetSession()
	session.currencies = session.currencies or {}
	table.insert(session.currencies, entry)
	session.firstLoot = session.firstLoot or entry.time
	session.lastLoot = entry.time
	FLT.UpdateCurrencyStats(entry.currencyID, entry.amount or 0)
	FLT.Debug(("Currency %+d %s ← %s"):format(
		entry.amount or 0,
		entry.name or tostring(entry.currencyID),
		entry.source or "?"
	))
end

function FLT.AddCurrencyRecord(currencyID, amount, name, icon, source)
	if FLT.IsRecording and not FLT.IsRecording() then
		return
	end
	if FLT.db and FLT.db.options and FLT.db.options.trackCurrency == false then
		return
	end
	currencyID = tonumber(currencyID)
	amount = tonumber(amount) or 0
	if not currencyID or amount == 0 then
		return
	end
	local info = CurrencyInfo(currencyID)
	local entry = {
		currencyID = currencyID,
		amount = amount,
		name = name or (info and info.name) or ("Currency " .. currencyID),
		icon = icon or (info and info.icon),
		source = Readable(source) or Readable(FLT.lastSource) or "Other",
		time = time(),
		zone = FLT.GetZoneName and FLT.GetZoneName() or "Unknown",
	}
	if FLT.Enqueue then
		FLT.Enqueue("currency", entry)
	else
		FLT.CommitCurrencyRecord(entry)
		if FLT.UI and FLT.UI.RefreshIfShown then
			FLT.UI.RefreshIfShown()
		end
	end
end

local function ParseCurrencyChat(text)
	text = Readable(text)
	if not text then
		return nil
	end
	local id = text:match("currency:(%d+)")
	id = tonumber(id)
	if not id then
		return nil
	end
	local name = text:match("%[([^%]]+)%]")
	local count = text:match("[xX]%s*(%d+)") or text:match("×%s*(%d+)")
	count = tonumber(count) or 1
	-- Chat is almost always a gain; treat as positive unless wording says otherwise.
	local lower = text:lower()
	if lower:find("removed") or lower:find("spent") or lower:find("lost") or lower:find("paid") then
		count = -math.abs(count)
	end
	return id, count, name
end

-- Readable chat is a hint only. Ledger ownership stays with DiffCurrencies so
-- instance runs (where chat is Secret) still record via CURRENCY_DISPLAY_UPDATE.
function FLT.OnChatCurrency(text)
	local id, amount, name = ParseCurrencyChat(text)
	if not id then
		FLT.Debug("CHAT_MSG_CURRENCY unparsed or secret.")
		return
	end
	recentChatAt[id] = GetTime()
	if name and name ~= "" then
		pendingNames[id] = name
	end
	-- Optimistic record when chat is readable; Diff suppresses the duplicate.
	FLT.AddCurrencyRecord(id, amount, name, nil, FLT.lastSource or "Loot")
	if lastCounts[id] ~= nil then
		lastCounts[id] = (lastCounts[id] or 0) + amount
	end
end

-- Force a wallet pass (e.g. secret CHAT_MSG_CURRENCY inside an instance).
function FLT.ForceCurrencyDiff(source)
	FLT.DiffCurrencies(source or FLT.lastSource or "Loot")
end

-- Stamp wallet dedupe so loot-slot currency capture is not double-counted by DiffCurrencies.
function FLT.NoteCurrencyCaptured(currencyID, amount)
	currencyID = tonumber(currencyID)
	amount = tonumber(amount) or 0
	if not currencyID then
		return
	end
	recentChatAt[currencyID] = GetTime()
	if lastCounts[currencyID] ~= nil then
		lastCounts[currencyID] = (lastCounts[currencyID] or 0) + amount
	end
end

-- Snapshot wallet currencies so spends (vendors that take badges, etc.) are caught.
function FLT.SnapshotCurrencies()
	wipe(lastCounts)
	local size
	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
		size = C_CurrencyInfo.GetCurrencyListSize()
	elseif GetCurrencyListSize then
		size = GetCurrencyListSize()
	end
	if not size then
		return
	end
	for i = 1, size do
		local name, isHeader, _, _, _, count, icon, _, _, _, _, itemID
		if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo then
			local ok, info = pcall(C_CurrencyInfo.GetCurrencyListInfo, i)
			if ok and info then
				if not info.isHeader then
					local id = info.currencyID or info.ID or itemID
					if id then
						lastCounts[id] = info.quantity or info.count or 0
					end
				end
			end
		elseif GetCurrencyListInfo then
			name, isHeader, _, _, _, count, icon, _, _, _, _, itemID = GetCurrencyListInfo(i)
			if not isHeader and itemID then
				lastCounts[itemID] = count or 0
			end
		end
	end
end

function FLT.DiffCurrencies(source)
	if not next(lastCounts) then
		FLT.SnapshotCurrencies()
		return
	end
	local seen = {}
	local size
	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
		size = C_CurrencyInfo.GetCurrencyListSize()
	elseif GetCurrencyListSize then
		size = GetCurrencyListSize()
	end
	if not size then
		return
	end
	for i = 1, size do
		local id, count, name, icon
		if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListInfo then
			local ok, info = pcall(C_CurrencyInfo.GetCurrencyListInfo, i)
			if ok and info and not info.isHeader then
				id = info.currencyID or info.ID
				count = info.quantity or info.count or 0
				name = info.name
				icon = info.iconFileID or info.icon
			end
		elseif GetCurrencyListInfo then
			local n, isHeader, _, _, _, c, ic, _, _, _, _, itemID = GetCurrencyListInfo(i)
			if not isHeader and itemID then
				id, count, name, icon = itemID, c or 0, n, ic
			end
		end
		if id then
			seen[id] = true
			local prev = lastCounts[id]
			if prev ~= nil and count ~= prev then
				local delta = count - prev
				local chatAt = recentChatAt[id]
				local chatRecent = chatAt and (GetTime() - chatAt) < 2.5
				-- Chat already logged gains; wallet diffs catch spends + secret-chat gains.
				if delta < 0 or not chatRecent then
					local label = name or pendingNames[id]
					FLT.AddCurrencyRecord(id, delta, label, icon, source or FLT.lastSource or "Other")
				end
				pendingNames[id] = nil
			end
			lastCounts[id] = count
		end
	end
end

function FLT.OnCurrencyDisplayUpdate()
	-- Diff after a short delay so the client finishes applying the change.
	if C_Timer and C_Timer.After then
		C_Timer.After(0.15, function()
			FLT.DiffCurrencies(FLT.lastSource or "Other")
		end)
	else
		FLT.DiffCurrencies(FLT.lastSource or "Other")
	end
end

function FLT.InitCurrencyTracker()
	FLT.SnapshotCurrencies()
end
