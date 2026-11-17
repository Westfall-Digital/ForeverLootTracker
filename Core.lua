-- ForeverLootTracker — bootstrap, session helpers, slash commands.
local ADDON_NAME = ...
local FLT = ForeverLootTracker

ForeverLootTrackerDB = ForeverLootTrackerDB or {}

local eventFrame = CreateFrame("Frame")
FLT.lastSource = "Unknown"
FLT.killResetAt = 0

function FLT.Print(msg)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cff33ccffForeverLootTracker|r: " .. tostring(msg))
	end
end

function FLT.Debug(msg)
	if FLT.db and FLT.db.user and FLT.db.user.debug then
		FLT.Print("|cffaaaaaa[debug]|r " .. tostring(msg))
	end
end

local function MergeDefaults(dst, src)
	for k, v in pairs(src) do
		if type(v) == "table" then
			if type(dst[k]) ~= "table" then
				dst[k] = FLT.DeepCopy(v)
			else
				MergeDefaults(dst[k], v)
			end
		elseif dst[k] == nil then
			dst[k] = v
		end
	end
end

function FLT.GetSession()
	local char = FLT.GetCharDB()
	if type(char.session) ~= "table" then
		char.session = FLT.NewSession("Default")
	end
	local session = char.session
	session.currencies = session.currencies or {}
	session.stats = session.stats or {}
	session.stats.currencies = session.stats.currencies or {}
	session.stats.copper = session.stats.copper or FLT.DefaultMoneyStats()
	session.items = session.items or {}
	session.money = session.money or {}
	session.itemCache = session.itemCache or {}
	return session
end

function FLT.SetSession(session)
	local char = FLT.GetCharDB()
	char.session = session or FLT.NewSession("Default")
	return char.session
end

function FLT.GetActiveSessionId()
	return FLT.GetCharDB().activeSessionId
end

function FLT.SetActiveSessionId(id)
	FLT.GetCharDB().activeSessionId = id
end

function FLT.FormatTime(epoch)
	epoch = epoch or time()
	if FLT.db.options.timeFormat == "12h" then
		return date("%Y-%m-%d %I:%M:%S %p", epoch)
	end
	return date("%Y-%m-%d %H:%M:%S", epoch)
end

function FLT.FormatMoney(copper)
	copper = math.floor(tonumber(copper) or 0)
	local g = math.floor(copper / 10000)
	local s = math.floor((copper % 10000) / 100)
	local c = copper % 100
	return ("%dg %ds %dc"):format(g, s, c)
end

local function ReadableString(v)
	if v == nil or v == "" then
		return nil
	end
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

function FLT.GetZoneName()
	local inInstance = IsInInstance()
	if inInstance then
		local name = ReadableString(GetInstanceInfo())
		if name then
			return name
		end
	end
	return ReadableString(GetRealZoneText()) or ReadableString(GetZoneText()) or "Unknown"
end

-- Forever: UnitName returns first, surname (2nd value is NOT realm). Prefer GetUnitName.
function FLT.UnitDisplayName(unit)
	unit = unit or "player"
	if GetUnitName then
		local ok, name = pcall(GetUnitName, unit)
		name = ok and ReadableString(name) or nil
		if name and name ~= "" then
			return name
		end
	end
	local ok, first, surname = pcall(UnitName, unit)
	if not ok then
		return nil
	end
	first = ReadableString(first)
	surname = ReadableString(surname)
	if not first or first == "" then
		return nil
	end
	if surname and surname ~= "" then
		local realm = ReadableString(GetRealmName and GetRealmName())
		local norm = ReadableString(GetNormalizedRealmName and GetNormalizedRealmName())
		if surname ~= realm and surname ~= norm then
			return first .. " " .. surname
		end
	end
	return first
end

function FLT.IsPlayerName(name)
	name = ReadableString(name)
	if not name or name == "" then
		return false
	end
	local me = FLT.UnitDisplayName("player")
	if not me then
		return false
	end
	if name == me then
		return true
	end
	-- Chat sometimes emits first name only.
	local first = me:match("^(%S+)") or me
	return name == first
end

function FLT.GetCharacterKey()
	return FLT.UnitDisplayName("player") or "Unknown"
end

function FLT.GetCharDB()
	FLT.db.chars = FLT.db.chars or {}
	local key = FLT.GetCharacterKey()
	local char = FLT.db.chars[key]
	if type(char) ~= "table" then
		char = {
			watched = {},
			session = FLT.NewSession("Default"),
			sessions = {},
			activeSessionId = nil,
		}
		FLT.db.chars[key] = char
	end
	char.watched = char.watched or {}
	char.sessions = char.sessions or {}
	if type(char.session) ~= "table" then
		char.session = FLT.NewSession("Default")
	end
	return char, key
end

function FLT.GetWatchedList()
	return FLT.GetCharDB().watched
end

-- One-time: move legacy account-wide watches onto the character that first logs in.
function FLT.MigrateWatchedToChar()
	if not FLT.db or not FLT.db.user then
		return
	end
	if FLT.db.user.watchedMigrated then
		return
	end
	local legacy = FLT.db.user.watched
	local char = FLT.GetCharDB()
	if type(legacy) == "table" and next(legacy) then
		if not next(char.watched) then
			for id, name in pairs(legacy) do
				char.watched[id] = name
			end
		end
		wipe(legacy)
	end
	FLT.db.user.watchedMigrated = true
end

-- One-time: move legacy account-wide tracked loot / archived sessions to this character.
function FLT.MigrateSessionToChar()
	if not FLT.db or not FLT.db.user then
		return
	end
	if FLT.db.user.sessionMigrated then
		return
	end
	local char = FLT.GetCharDB()
	local legacySession = FLT.db.session
	local legacySessions = FLT.db.sessions
	local charEmpty = not char.session
		or ((#(char.session.items or {}) == 0) and (#(char.session.money or {}) == 0))
	local legacyHasData = type(legacySession) == "table"
		and ((#(legacySession.items or {}) > 0) or (#(legacySession.money or {}) > 0))
	if charEmpty and legacyHasData then
		char.session = FLT.DeepCopy(legacySession)
	end
	if (not char.sessions or not next(char.sessions)) and type(legacySessions) == "table" and next(legacySessions) then
		char.sessions = FLT.DeepCopy(legacySessions)
		char.activeSessionId = FLT.db.activeSessionId
	end
	-- Drop account-wide copies so other characters don't inherit them.
	FLT.db.session = nil
	FLT.db.sessions = nil
	FLT.db.activeSessionId = nil
	FLT.db.user.sessionMigrated = true
end

function FLT.CacheItem(itemID, itemLink)
	local session = FLT.GetSession()
	itemID = tonumber(itemID)
	if not itemID then
		return nil
	end
	if session.itemCache[itemID] then
		return session.itemCache[itemID]
	end

	local name, link, quality, itemLevel, _, itemType, itemSubType, _, _, icon, sellPrice, classID, subclassID =
		GetItemInfo(itemLink or itemID)

	-- C_Item fallbacks for Forever / modern clients.
	if (not name) and C_Item then
		if C_Item.GetItemNameByID then
			name = C_Item.GetItemNameByID(itemID)
		end
		if C_Item.GetItemQualityByID then
			quality = C_Item.GetItemQualityByID(itemID)
		end
		if C_Item.GetItemIconByID then
			icon = C_Item.GetItemIconByID(itemID)
		end
	end

	local entry = {
		id = itemID,
		name = name or ("Item " .. itemID),
		link = link or itemLink,
		quality = quality or 1,
		iLvl = itemLevel or 0,
		type = (itemType or "?") .. ((itemSubType and (" / " .. itemSubType)) or ""),
		icon = icon,
		value = sellPrice or 0,
		classID = classID,
		subclassID = subclassID,
	}
	session.itemCache[itemID] = entry
	return entry
end

function FLT.UpdateMoneyStats(amount)
	local session = FLT.GetSession()
	local m = session.stats.copper
	local now = time()
	session.firstLoot = session.firstLoot or now
	session.lastLoot = now

	amount = tonumber(amount) or 0
	m.total = (m.total or 0) + amount
	m.count = (m.count or 0) + 1
	m.earned = m.earned or 0
	m.spent = m.spent or 0
	m.largestLoss = m.largestLoss or 0
	if amount > 0 then
		m.earned = m.earned + amount
		if amount > (m.largest or 0) then
			m.largest = amount
		end
	elseif amount < 0 then
		local loss = -amount
		m.spent = m.spent + loss
		if loss > m.largestLoss then
			m.largestLoss = loss
		end
	end
	m.average = m.count > 0 and (m.total / m.count) or 0

	local elapsed = math.max(1, now - (session.firstLoot or now))
	m.perHour = (m.total * 3600) / elapsed
end

function FLT.RebuildStats()
	local session = FLT.GetSession()
	session.stats.junkValue = 0
	session.stats.copper = FLT.DefaultMoneyStats()
	session.firstLoot = nil
	session.lastLoot = nil

	local m = session.stats.copper
	for _, money in ipairs(session.money) do
		local amount = tonumber(money.amount) or 0
		session.firstLoot = session.firstLoot or money.time
		session.lastLoot = money.time
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
	if m.count > 0 then
		m.average = m.total / m.count
		local elapsed = math.max(1, (session.lastLoot or time()) - (session.firstLoot or time()))
		m.perHour = (m.total * 3600) / elapsed
	end

	for _, item in ipairs(session.items) do
		local cached = session.itemCache[item.itemID]
		if cached and (cached.quality or 1) == 0 then
			session.stats.junkValue = session.stats.junkValue + ((cached.value or 0) * (item.count or 1))
		end
	end

	session.stats.currencies = {}
	for _, cur in ipairs(session.currencies or {}) do
		if FLT.UpdateCurrencyStats then
			FLT.UpdateCurrencyStats(cur.currencyID, cur.amount or 0)
		end
	end
end

function FLT.ClearSession()
	FLT.SetSession(FLT.NewSession("Session " .. date("%H:%M:%S")))
	FLT.SetActiveSessionId(nil)
	if FLT.UI and FLT.UI.Refresh then
		FLT.UI.Refresh()
	end
	if FLT.RefreshObjectiveTracker then
		FLT.RefreshObjectiveTracker()
	end
	FLT.Print("Session cleared.")
end

-- SavedVariables may stringify numeric keys; always probe number + string forms.
function FLT.GetListValue(list, itemID)
	if not list or itemID == nil then
		return nil
	end
	local n = tonumber(itemID)
	local s = tostring(itemID)
	if n ~= nil and list[n] ~= nil then
		return list[n], n
	end
	if list[s] ~= nil then
		return list[s], s
	end
	if list[itemID] ~= nil then
		return list[itemID], itemID
	end
	return nil, n or itemID
end

function FLT.SetListValue(list, itemID, value)
	if not list or itemID == nil then
		return
	end
	local n = tonumber(itemID)
	local key = n or itemID
	-- Clear both forms so we don't leave stale string/number duplicates.
	list[tostring(itemID)] = nil
	if n ~= nil then
		list[n] = nil
	end
	if value ~= nil then
		list[key] = value
	end
end

function FLT.IsWatched(itemID)
	return FLT.GetListValue(FLT.GetWatchedList(), itemID) ~= nil
end

function FLT.IsIgnored(itemID)
	return FLT.GetListValue(FLT.db.user.ignored, itemID) ~= nil
end

local function NextIgnoreRuleId()
	local rules = FLT.db.user.ignoreRules or {}
	local maxId = 0
	for _, rule in ipairs(rules) do
		local n = tonumber(tostring(rule.id or ""):match("(%d+)"))
		if n and n > maxId then
			maxId = n
		end
	end
	return "r" .. tostring(maxId + 1)
end

function FLT.MigrateIgnoreRules()
	if not FLT.db or not FLT.db.user then
		return
	end
	FLT.db.user.ignoreRules = FLT.db.user.ignoreRules or {}
	if FLT.db.user.ignoreRulesMigrated then
		return
	end
	for id, name in pairs(FLT.db.user.ignored or {}) do
		local itemID = tonumber(id) or id
		local exists = false
		for _, rule in ipairs(FLT.db.user.ignoreRules) do
			if rule.kind == "item" and tostring(rule.value) == tostring(itemID) then
				exists = true
				break
			end
		end
		if not exists then
			table.insert(FLT.db.user.ignoreRules, {
				id = NextIgnoreRuleId(),
				kind = "item",
				value = tostring(itemID),
				label = name or ("Item " .. tostring(itemID)),
			})
		end
	end
	FLT.db.user.ignoreRulesMigrated = true
end

function FLT.GetIgnoreRules()
	if not FLT.db or not FLT.db.user then
		return {}
	end
	FLT.MigrateIgnoreRules()
	return FLT.db.user.ignoreRules or {}
end

local function NormalizeIgnoreNeedle(s)
	s = tostring(s or ""):lower()
	s = s:gsub("^%s+", ""):gsub("%s+$", "")
	return s
end

-- Type keys match edit-dropdown values: "st:0" / "sk:Mail" / display names.
function FLT.ItemTypeIgnoreKey(sourceType, sourceKind)
	if sourceKind == "Gathering" or sourceKind == "Fishing" or sourceKind == "Mail"
		or sourceKind == "Disenchant" or sourceKind == "ItemBox" or sourceKind == "Quest" then
		return "sk:" .. sourceKind
	end
	if sourceKind == "Vendor" then
		return "st:4"
	end
	if sourceKind == "Crafted" then
		return "st:3"
	end
	local st = tonumber(sourceType)
	if st == nil then
		st = FLT.SOURCE.Dropped
	end
	return "st:" .. tostring(st)
end

function FLT.IgnoreTypeLabel(key)
	key = tostring(key or "")
	local kind = key:match("^sk:(.+)$")
	if kind == "Gathering" then
		return "Gather"
	elseif kind == "Fishing" then
		return "Fish"
	elseif kind == "ItemBox" then
		return "Box"
	elseif kind then
		return kind
	end
	local st = tonumber(key:match("^st:(%-?%d+)$"))
	if st ~= nil then
		return FLT.SOURCE_NAMES[st] or key
	end
	return key
end

function FLT.MatchesIgnoreRule(itemID, itemName, source, sourceType, sourceKind)
	local rules = FLT.GetIgnoreRules()
	local name = NormalizeIgnoreNeedle(itemName)
	local src = NormalizeIgnoreNeedle(source)
	local typeKey = FLT.ItemTypeIgnoreKey(sourceType, sourceKind)
	local typeLabel = NormalizeIgnoreNeedle(FLT.IgnoreTypeLabel(typeKey))

	for _, rule in ipairs(rules) do
		local kind = rule.kind
		local value = tostring(rule.value or "")
		if kind == "item" then
			if tostring(itemID) == value or tonumber(itemID) == tonumber(value) then
				return true, rule
			end
		elseif kind == "name" then
			local needle = NormalizeIgnoreNeedle(value)
			if needle ~= "" and name:find(needle, 1, true) then
				return true, rule
			end
		elseif kind == "source" then
			local needle = NormalizeIgnoreNeedle(value)
			if needle ~= "" and src:find(needle, 1, true) then
				return true, rule
			end
		elseif kind == "type" then
			local needle = NormalizeIgnoreNeedle(value)
			if needle == NormalizeIgnoreNeedle(typeKey) or needle == typeLabel then
				return true, rule
			end
		end
	end

	-- Legacy map fallback if migration hasn't run yet.
	if FLT.IsIgnored(itemID) then
		return true, nil
	end
	return false, nil
end

function FLT.AddIgnoreRule(kind, value, label)
	kind = tostring(kind or "item")
	value = tostring(value or "")
	if value == "" then
		return nil
	end
	local rules = FLT.GetIgnoreRules()
	for _, rule in ipairs(rules) do
		if rule.kind == kind and NormalizeIgnoreNeedle(rule.value) == NormalizeIgnoreNeedle(value) then
			return rule
		end
	end
	local rule = {
		id = NextIgnoreRuleId(),
		kind = kind,
		value = value,
		label = label or value,
	}
	table.insert(rules, rule)
	if kind == "item" then
		local itemID = tonumber(value) or value
		FLT.SetListValue(FLT.db.user.ignored, itemID, label or value)
	end
	return rule
end

function FLT.RemoveIgnoreRule(ruleId)
	local rules = FLT.GetIgnoreRules()
	for i, rule in ipairs(rules) do
		if rule.id == ruleId then
			if rule.kind == "item" then
				local itemID = tonumber(rule.value) or rule.value
				FLT.SetListValue(FLT.db.user.ignored, itemID, nil)
			end
			table.remove(rules, i)
			return true
		end
	end
	return false
end

function FLT.ClearIgnoreRules()
	wipe(FLT.GetIgnoreRules())
	if FLT.db.user.ignored then
		wipe(FLT.db.user.ignored)
	end
end

-- Remove current-session loot rows that match an ignore rule (or all rules when nil).
function FLT.PurgeSessionItemsMatchingIgnore(rule)
	local session = FLT.GetSession and FLT.GetSession()
	if not session or not session.items then
		return 0
	end
	local removed = 0
	for i = #session.items, 1, -1 do
		local item = session.items[i]
		local cached = session.itemCache and session.itemCache[item.itemID]
		local name = cached and cached.name
		local matched = false
		if rule then
			local kind = rule.kind
			local value = tostring(rule.value or "")
			if kind == "item" then
				matched = tostring(item.itemID) == value or tonumber(item.itemID) == tonumber(value)
			elseif kind == "name" then
				local needle = NormalizeIgnoreNeedle(value)
				matched = needle ~= "" and NormalizeIgnoreNeedle(name):find(needle, 1, true) ~= nil
			elseif kind == "source" then
				local needle = NormalizeIgnoreNeedle(value)
				matched = needle ~= "" and NormalizeIgnoreNeedle(item.source):find(needle, 1, true) ~= nil
			elseif kind == "type" then
				local typeKey = FLT.ItemTypeIgnoreKey(item.sourceType, item.sourceKind)
				local typeLabel = NormalizeIgnoreNeedle(FLT.IgnoreTypeLabel(typeKey))
				local needle = NormalizeIgnoreNeedle(value)
				matched = needle == NormalizeIgnoreNeedle(typeKey) or needle == typeLabel
			end
		else
			matched = FLT.MatchesIgnoreRule(item.itemID, name, item.source, item.sourceType, item.sourceKind)
		end
		if matched then
			table.remove(session.items, i)
			removed = removed + 1
		end
	end
	if removed > 0 and FLT.RebuildStats then
		FLT.RebuildStats()
	end
	return removed
end

function FLT.ShouldTrackItem(quality, sourceType, itemID, ctx)
	ctx = ctx or {}
	if quality ~= nil and FLT.db.options.qualityFilters[quality] == false then
		return false
	end
	if sourceType ~= nil and FLT.db.options.sourceFilters[sourceType] == false then
		return false
	end
	if FLT.MatchesIgnoreRule(itemID, ctx.name, ctx.source, sourceType, ctx.sourceKind) then
		return false
	end
	return true
end

function FLT.AlertWatched(itemLink, count, looter)
	-- ASCII "->" — Friz Quadrata lacks Unicode arrows (→/↑/↓ show as boxes).
	local item = itemLink or "?"
	local who = looter or "?"
	local msg
	if count and count > 1 then
		msg = ("%s x%d -> %s"):format(item, count, who)
	else
		msg = ("%s -> %s"):format(item, who)
	end
	FLT.Print("|cffff8800WATCHED LOOT:|r " .. msg)
	if UIErrorsFrame and UIErrorsFrame.AddMessage then
		UIErrorsFrame:AddMessage(msg, 1.0, 0.55, 0.0)
	end
	if RaidNotice_AddMessage and RaidWarningFrame then
		RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"] or { r = 1, g = 0.5, b = 0 })
	end
end

local function OnEvent(_, event, ...)
	if event == "ADDON_LOADED" then
		local name = ...
		if name == ADDON_NAME then
			ForeverLootTrackerDB = ForeverLootTrackerDB or {}
			MergeDefaults(ForeverLootTrackerDB, FLT.DefaultSettings())
			FLT.db = ForeverLootTrackerDB
		elseif (name == "Blizzard_AuctionUI" or name == "Blizzard_AuctionHouseUI") and FLT.HookAuctionHouse then
			-- Auction APIs appear when the Blizzard AH UI loads.
			FLT.HookAuctionHouse()
		end
	elseif event == "PLAYER_LOGIN" then
		FLT.db = ForeverLootTrackerDB
		MergeDefaults(FLT.db, FLT.DefaultSettings())
		FLT.MigrateWatchedToChar()
		FLT.MigrateSessionToChar()
		if FLT.MigrateIgnoreRules then
			FLT.MigrateIgnoreRules()
		end
		if not FLT.db.options.persistSession then
			FLT.SetSession(FLT.NewSession("Default"))
			FLT.SetActiveSessionId(nil)
		end
		FLT.RebuildStats()
		if FLT.InitMoneyTracker then
			FLT.InitMoneyTracker()
		end
		if FLT.InitCurrencyTracker then
			FLT.InitCurrencyTracker()
		end
		if FLT.Minimap and FLT.Minimap.Init then
			FLT.Minimap.Init()
		end
		FLT.Print(("Loaded v%s. Type /flt to open the tracker."):format(FLT.VERSION))
	elseif event == "CHAT_MSG_LOOT" then
		FLT.OnChatLoot(...)
	elseif event == "CHAT_MSG_MONEY" then
		-- Context only (Loot); copper delta comes from PLAYER_MONEY.
		FLT.OnChatMoney(...)
	elseif event == "CHAT_MSG_CURRENCY" then
		local text = ...
		if text and issecretvalue and issecretvalue(text) then
			-- Instance chat is Secret — fall back to wallet list diff.
			if FLT.ForceCurrencyDiff then
				FLT.ForceCurrencyDiff(FLT.lastSource or "Loot")
			elseif FLT.OnCurrencyDisplayUpdate then
				FLT.OnCurrencyDisplayUpdate()
			end
		elseif FLT.OnChatCurrency then
			FLT.OnChatCurrency(...)
		end
	elseif event == "CHAT_MSG_TRADESKILL" or event == "CHAT_MSG_TRADESKILLS" then
		if FLT.OnTradeSkillChat then
			FLT.OnTradeSkillChat(...)
		end
	elseif event == "CURRENCY_DISPLAY_UPDATE" then
		if FLT.OnCurrencyDisplayUpdate then
			FLT.OnCurrencyDisplayUpdate()
		end
	elseif event == "LOOT_READY" then
		if FLT.OnLootWindowOpened then
			FLT.OnLootWindowOpened()
		elseif FLT.OnLootOpenedForSource then
			FLT.OnLootOpenedForSource()
		end
	elseif event == "LOOT_SLOT_CLEARED" then
		if FLT.OnLootSlotCleared then
			FLT.OnLootSlotCleared(...)
		end
	elseif event == "BAG_UPDATE" then
		if FLT.OnBagUpdateForLoot then
			FLT.OnBagUpdateForLoot()
		end
	elseif event == "TRADE_SKILL_SHOW" or event == "CRAFT_SHOW" then
		if FLT.SetCraftingContext then
			FLT.SetCraftingContext(true)
		end
	elseif event == "TRADE_SKILL_LIST_UPDATE" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
		-- Refresh profession name only while a skill window is open — do not arm long sticky.
		if FLT.SetCraftingContext then
			FLT.SetCraftingContext(true, true)
		end
	elseif event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
		if FLT.SetCraftingContext then
			FLT.SetCraftingContext(false)
		end
	elseif event == "PLAYER_TARGET_CHANGED" then
		-- Forever forbids combat-log reads; use readable target names as soft source hints.
		if FLT.RememberUnitSource then
			FLT.RememberUnitSource("target")
		end
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		if FLT.RememberUnitSource then
			FLT.RememberUnitSource("mouseover")
		end
	elseif event == "ENCOUNTER_START" then
		if FLT.OnEncounterStart then
			FLT.OnEncounterStart(...)
		end
	elseif event == "ENCOUNTER_END" then
		if FLT.OnEncounterEnd then
			FLT.OnEncounterEnd(...)
		end
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_START"
		or event == "UNIT_SPELLCAST_STOP" then
		FLT._lastSpellCastEvent = event
		if FLT.OnGatherSpellCast then
			FLT.OnGatherSpellCast(...)
		end
		FLT._lastSpellCastEvent = nil
	elseif FLT.OnMoneyContextEvent then
		FLT.OnMoneyContextEvent(event, ...)
	end
end

local function SafeRegister(event)
	pcall(eventFrame.RegisterEvent, eventFrame, event)
end

local function SafeRegisterUnit(event, unit)
	if eventFrame.RegisterUnitEvent then
		local ok = pcall(eventFrame.RegisterUnitEvent, eventFrame, event, unit)
		if ok then
			return
		end
	end
	SafeRegister(event)
end

SafeRegister("ADDON_LOADED")
SafeRegister("PLAYER_LOGIN")
SafeRegister("PLAYER_ENTERING_WORLD")
SafeRegister("CHAT_MSG_LOOT")
SafeRegister("CHAT_MSG_MONEY")
SafeRegister("CHAT_MSG_CURRENCY")
SafeRegister("CHAT_MSG_TRADESKILL")
SafeRegister("CHAT_MSG_TRADESKILLS")
SafeRegister("CURRENCY_DISPLAY_UPDATE")
SafeRegister("PLAYER_MONEY")
-- NOTE: Do NOT register COMBAT_LOG_EVENT_UNFILTERED on Forever.
SafeRegister("MERCHANT_SHOW")
SafeRegister("MERCHANT_CLOSED")
SafeRegister("TAXIMAP_OPENED")
SafeRegister("TAXIMAP_CLOSED")
SafeRegister("TRAINER_SHOW")
SafeRegister("TRAINER_CLOSED")
SafeRegister("TRADE_SHOW")
SafeRegister("TRADE_CLOSED")
SafeRegister("TRADE_SKILL_SHOW")
SafeRegister("TRADE_SKILL_CLOSE")
SafeRegister("TRADE_SKILL_LIST_UPDATE")
SafeRegister("TRADE_SKILL_DATA_SOURCE_CHANGED")
SafeRegister("CRAFT_SHOW")
SafeRegister("CRAFT_CLOSE")
SafeRegister("MAIL_SHOW")
SafeRegister("MAIL_CLOSED")
SafeRegister("AUCTION_HOUSE_SHOW")
SafeRegister("AUCTION_HOUSE_CLOSED")
SafeRegister("BANKFRAME_OPENED")
SafeRegister("BANKFRAME_CLOSED")
SafeRegister("GUILDBANKFRAME_OPENED")
SafeRegister("GUILDBANKFRAME_CLOSED")
SafeRegister("BARBER_SHOP_OPEN")
SafeRegister("BARBER_SHOP_CLOSE")
SafeRegister("LOOT_OPENED")
SafeRegister("LOOT_CLOSED")
SafeRegister("LOOT_READY")
SafeRegister("LOOT_SLOT_CLEARED")
SafeRegister("BAG_UPDATE")
SafeRegister("QUEST_DETAIL")
SafeRegister("QUEST_ACCEPTED")
SafeRegister("QUEST_PROGRESS")
SafeRegister("QUEST_COMPLETE")
SafeRegister("QUEST_FINISHED")
SafeRegister("QUEST_TURNED_IN")
SafeRegister("PLAYER_TARGET_CHANGED")
SafeRegister("UPDATE_MOUSEOVER_UNIT")
SafeRegister("ENCOUNTER_START")
SafeRegister("ENCOUNTER_END")
-- Player-only unit events (Disenchant / gathering sticky). Broader RegisterEvent
-- often misses player casts on Forever's unit-event model.
SafeRegisterUnit("UNIT_SPELLCAST_SUCCEEDED", "player")
SafeRegisterUnit("UNIT_SPELLCAST_START", "player")
SafeRegisterUnit("UNIT_SPELLCAST_STOP", "player")
eventFrame:SetScript("OnEvent", OnEvent)

function ForeverLootTracker_OnAddonCompartmentClick()
	if FLT.UI and FLT.UI.Toggle then
		FLT.UI.Toggle()
	end
end

-- Prefer /flt — avoid claiming /loot in case the client reserves it.
SLASH_FOREVERLOOTTRACKER1 = "/flt"
SLASH_FOREVERLOOTTRACKER2 = "/foreverloot"
SLASH_FOREVERLOOTTRACKER3 = "/floot"
SlashCmdList.FOREVERLOOTTRACKER = function(msg)
	msg = strtrim(msg or ""):lower()
	local cmd = msg:match("^(%S+)") or ""

	if cmd == "" or cmd == "show" or cmd == "toggle" then
		if FLT.UI and FLT.UI.Toggle then
			FLT.UI.Toggle()
		end
	elseif cmd == "clear" then
		FLT.ClearSession()
	elseif cmd == "export" then
		if FLT.UI and FLT.UI.ShowExport then
			FLT.UI.ShowExport()
		end
	elseif cmd == "pause" or cmd == "resume" or cmd == "record" then
		if cmd == "pause" then
			FLT.SetRecording(false)
		elseif cmd == "resume" then
			FLT.SetRecording(true)
		else
			FLT.ToggleRecording()
		end
	elseif cmd == "save" then
		local label = msg:match("^%S+%s+(.+)$")
		FLT.SaveCurrentSession(label)
	elseif cmd == "new" then
		local label = msg:match("^%S+%s+(.+)$")
		FLT.StartNewSession(label, true)
	elseif cmd == "add" then
		if FLT.UI and FLT.UI.ShowAddItem then
			FLT.UI.ShowAddItem()
		end
	elseif cmd == "debug" then
		FLT.db.user.debug = not FLT.db.user.debug
		FLT.Print("Debug " .. (FLT.db.user.debug and "on" or "off") .. ".")
	elseif cmd == "help" then
		FLT.Print("/flt — open tracker")
		FLT.Print("/flt clear — clear current session")
		FLT.Print("/flt save [label] — archive current session")
		FLT.Print("/flt new [label] — archive & start new session")
		FLT.Print("/flt pause|resume|record — recording control")
		FLT.Print("/flt add — manual add item")
		FLT.Print("/flt export — open export window")
		FLT.Print("/flt debug — toggle debug")
	else
		FLT.Print("Unknown command. Try /flt help")
	end
end
