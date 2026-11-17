-- ForeverLootTracker — loot / money capture pipeline (Forever-safe; no combat log).
local FLT = ForeverLootTracker

local function PlayerName()
	-- Forever needs first + surname; UnitName alone is first-name only.
	return (FLT.UnitDisplayName and FLT.UnitDisplayName("player")) or UnitName("player")
end

-- Forever/Midnight: many combat & instance values are secret. Never compare/parse secrets.
local function IsSecret(v)
	return issecretvalue and issecretvalue(v)
end

local function Readable(v)
	if v == nil then
		return nil
	end
	if IsSecret(v) then
		return nil
	end
	return v
end

local function SafeConcat(...)
	local parts = { ... }
	for i = 1, #parts do
		if IsSecret(parts[i]) then
			parts[i] = "?"
		else
			parts[i] = tostring(parts[i] or "")
		end
	end
	return table.concat(parts)
end

-- Convert Blizzard LOOT_* format strings (%s / %d) into Lua patterns.
local patternCache = {}
local function FormatToPattern(fmt)
	fmt = Readable(fmt)
	if not fmt then
		return nil
	end
	if patternCache[fmt] then
		return patternCache[fmt]
	end
	local pat = ""
	local i = 1
	while i <= #fmt do
		local c = fmt:sub(i, i)
		if c == "%" and i < #fmt then
			local n = fmt:sub(i + 1, i + 1)
			if n == "s" then
				pat = pat .. "(.+)"
				i = i + 2
			elseif n == "d" then
				pat = pat .. "(%d+)"
				i = i + 2
			elseif n == "%" then
				pat = pat .. "%%"
				i = i + 2
			else
				pat = pat .. "%" .. n
				i = i + 2
			end
		else
			if c:match("[%^%$%(%)%%%.%[%]%*%+%-%?]") then
				pat = pat .. "%" .. c
			else
				pat = pat .. c
			end
			i = i + 1
		end
	end
	patternCache[fmt] = pat
	return pat
end

local function TryMatch(fmtKey, text)
	text = Readable(text)
	if not text then
		return nil
	end
	local fmt = Readable(_G[fmtKey])
	if not fmt then
		return nil
	end
	local pat = FormatToPattern(fmt)
	if not pat then
		return nil
	end
	local ok, a, b, c = pcall(string.match, text, "^" .. pat)
	if not ok then
		return nil
	end
	return a, b, c
end

local function ExtractLink(text)
	text = Readable(text)
	if not text then
		return nil
	end
	-- Forever/retail uses named quality colors: |cnIQ4|Hitem:...|h[Name]|h|r
	-- Older clients used hex colors: |cffffffff|Hitem:...|h[Name]|h|r
	local patterns = {
		"(|cnIQ%d+:?|Hitem:.-|h.-|h|r)",
		"(|c%x+|Hitem:.-|h.-|h|r)",
		"(|Hitem:.-|h.-|h|r)",
	}
	for _, pat in ipairs(patterns) do
		local ok, link = pcall(string.match, text, pat)
		if ok and link then
			return Readable(link)
		end
	end
	return nil
end

local function ExtractItemID(link)
	link = Readable(link)
	if not link then
		return nil
	end
	local ok, id = pcall(string.match, link, "item:(%d+)")
	if not ok then
		return nil
	end
	return tonumber(id)
end

-- Right-click Lesser <-> Greater Enchanting essence convert (bag use) is not loot.
-- Forever reports it as receive/pushed (Dropped) more often than "You create".
-- Real DE / corpse / container loot still has a loot window open.
local ESSENCE_CONVERT_IDS = {
	-- Magic
	[10938] = true, [10939] = true,
	-- Astral
	[10998] = true, [11082] = true,
	-- Mystic
	[11134] = true, [11135] = true,
	-- Nether
	[11174] = true, [11175] = true,
	-- Eternal
	[16202] = true, [16203] = true,
}

local function IsConvertibleEssence(link, itemID)
	itemID = itemID or ExtractItemID(link)
	if itemID and ESSENCE_CONVERT_IDS[itemID] then
		return true
	end
	-- Name fallback for any Lesser/Greater * Essence the ID table misses.
	link = Readable(link)
	if not link then
		return false
	end
	local ok, name = pcall(string.match, link, "%[(.-)%]")
	if not ok or not name then
		return false
	end
	name = name:lower()
	return name:find("^lesser .+ essence$") ~= nil
		or name:find("^greater .+ essence$") ~= nil
end

local function IsLootWindowActive()
	if LootFrame and LootFrame.IsShown and LootFrame:IsShown() then
		return true
	end
	if GetNumLootItems then
		local ok, n = pcall(GetNumLootItems)
		if ok and n and n > 0 then
			return true
		end
	end
	return false
end

-- Bag essence split/merge: self chat, no loot frame. Keep DE/mob/chest/mail/quest/craft.
local function ShouldSkipEssenceConvert(link, isSelfGain)
	if not isSelfGain or not IsConvertibleEssence(link) then
		return false
	end
	-- Real Disenchant also has no loot frame — keep those when DE sticky is active.
	if FLT.IsDisenchantContext and FLT.IsDisenchantContext() then
		return false
	end
	if IsLootWindowActive() then
		return false
	end
	if IsMailItem() then
		return false
	end
	if FLT.IsQuestItemContext and FLT.IsQuestItemContext() then
		return false
	end
	if FLT.craftingActiveUntil and GetTime() < FLT.craftingActiveUntil then
		return false
	end
	return true
end

local function ApplyDisenchantAttribution()
	FLT.lastSource = "Disenchanting"
	FLT.lastSourceKind = "Disenchant"
	FLT.mailItemStickyUntil = nil
	FLT.mailStickyUntil = nil
	if not FLT.disenchantStickyUntil or GetTime() >= FLT.disenchantStickyUntil then
		FLT.disenchantStickyUntil = GetTime() + 8
	end
end

local function IsMailItem()
	return FLT.IsMailItemContext and FLT.IsMailItemContext()
end

local function ExtractCount(text, link)
	text = Readable(text)
	link = Readable(link)
	if not text then
		return 1
	end
	if link then
		local ok, after = pcall(function()
			return text:match(link:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "%s*[xX](%d+)")
		end)
		if ok and after then
			return tonumber(after) or 1
		end
	end
	local ok, n = pcall(string.match, text, "[xX](%d+)")
	if ok and n then
		return tonumber(n) or 1
	end
	return 1
end

-- Immediate commit used by the queue pump (and manual add).
function FLT.CommitItemRecord(entry)
	if not entry or not entry.itemID then
		return
	end
	local session = FLT.GetSession()
	local now = entry.time or time()
	session.firstLoot = session.firstLoot or now
	session.lastLoot = now
	-- Ensure cache is warm (may have been deferred).
	local cached = FLT.CacheItem(entry.itemID, entry.link)
	table.insert(session.items, entry)

	local quality = (cached and cached.quality) or entry.quality or 1
	if quality == 0 and cached then
		session.stats.junkValue = (session.stats.junkValue or 0) + ((cached.value or 0) * (entry.count or 1))
	end

	if FLT.IsWatched and FLT.IsWatched(entry.itemID) then
		if FLT.AlertWatched then
			FLT.AlertWatched(entry.link, entry.count, entry.looter)
		end
	end

	FLT.Debug(SafeConcat(
		"Tracked ", entry.link or "?", " x", entry.count or 1,
		" from ", entry.looter or "?", " (", FLT.SOURCE_NAMES[entry.sourceType] or "?", ")"
	))
end

-- Filled after LooterKey is defined (chat / loot-slot / bag-diff share one dedupe window).
local WasCapturedRecently, NoteCapture, LooterKey
-- Declared early so AddItemRecord can reference them at runtime.
local CAPTURE_DEDUPE_WINDOW = 2.75
local CAPTURE_DEDUPE_ROLL_WINDOW = 12

-- sourceOverride replaces FLT.lastSource for this entry (e.g. profession name when crafting).
function FLT.AddItemRecord(itemLink, count, looter, sourceType, rollType, sourceOverride)
	if FLT.IsRecording and not FLT.IsRecording() then
		FLT.Debug("Skipped item — recording paused.")
		return
	end
	itemLink = Readable(itemLink)
	looter = Readable(looter) or PlayerName()
	local itemID = ExtractItemID(itemLink)
	if not itemID then
		return
	end
	count = tonumber(count) or 1
	if WasCapturedRecently and WasCapturedRecently(itemID, count, looter) then
		FLT.Debug("Skipped duplicate capture for item " .. tostring(itemID))
		return
	end

	-- Lightweight quality probe for filters before enqueue (full cache in commit).
	local cached = FLT.CacheItem(itemID, itemLink)
	local quality = cached and cached.quality or 1
	sourceType = sourceType or FLT.SOURCE.Dropped

	-- Stale Mail/Quest attribution must not stick once their context ends.
	if FLT.lastSourceKind == "Mail" and not IsMailItem() then
		FLT.lastSource = "Unknown"
		FLT.lastSourceKind = nil
	end
	if FLT.lastSourceKind == "Quest"
		and not (FLT.IsQuestItemContext and FLT.IsQuestItemContext()) then
		FLT.lastSource = "Unknown"
		FLT.lastSourceKind = nil
	end

	local sourceName = Readable(sourceOverride)
		or (sourceType == FLT.SOURCE.Crafted and FLT.GetActiveProfessionName and FLT.GetActiveProfessionName())
		or (sourceType == FLT.SOURCE.Purchased and FLT.GetActiveVendorName and FLT.GetActiveVendorName())
		or Readable(FLT.lastSource)
		or "Unknown"
	local sourceKind = FLT.lastSourceKind
	-- Context overrides (DE/Quest/Mail) only apply to the local player's gains — never
	-- relabel party loot from our own UI sticky state.
	local isSelfLoot = LooterKey(looter) == "player"
	local lootWindowOpen = IsLootWindowActive()
	if sourceType == FLT.SOURCE.Crafted and FLT.lastSourceKind ~= "Disenchant" then
		sourceKind = "Crafted"
	elseif sourceType == FLT.SOURCE.Purchased then
		sourceKind = "Vendor"
	elseif isSelfLoot and not lootWindowOpen and FLT.IsDisenchantContext and FLT.IsDisenchantContext() then
		sourceKind = "Disenchant"
		if not Readable(sourceOverride) then
			sourceName = "Disenchanting"
		end
	elseif isSelfLoot and not lootWindowOpen and FLT.IsQuestItemContext and FLT.IsQuestItemContext() then
		sourceKind = "Quest"
		if not Readable(sourceOverride) then
			sourceName = "Quest"
		end
	elseif isSelfLoot and not lootWindowOpen and IsMailItem() then
		sourceKind = "Mail"
		if not Readable(sourceOverride) then
			sourceName = "Mailbox"
		end
	end

	-- Quality/sourceType filters + flexible ignore rules (item / name / source / type).
	if not FLT.ShouldTrackItem(quality, sourceType, itemID, {
		name = cached and cached.name,
		source = sourceName,
		sourceKind = sourceKind,
	}) then
		FLT.Debug("Filtered item " .. tostring(itemID))
		return
	end

	local entry = {
		itemID = itemID,
		link = itemLink,
		count = count or 1,
		cost = FLT.db.options.defaultCost or 0,
		looter = looter,
		source = sourceName,
		sourceKind = sourceKind,
		sourceType = sourceType,
		rollType = rollType,
		quality = quality,
		time = time(),
		zone = FLT.GetZoneName(),
	}

	if NoteCapture then
		local dedupeWindow = (sourceType == FLT.SOURCE.Rolled) and CAPTURE_DEDUPE_ROLL_WINDOW or nil
		NoteCapture(itemID, count, looter, dedupeWindow)
	end
	if FLT.Enqueue then
		FLT.Enqueue("item", entry)
	else
		FLT.CommitItemRecord(entry)
		if FLT.UI and FLT.UI.RefreshIfShown then
			FLT.UI.RefreshIfShown()
		end
		if FLT.RefreshObjectiveTracker then
			FLT.RefreshObjectiveTracker()
		end
	end
end

-- amount may be negative (spend). kind is a stable category key (Vendor/Repair/Flight/…).
function FLT.AddMoneyRecord(copper, source, kind)
	if FLT.IsRecording and not FLT.IsRecording() then
		FLT.Debug("Skipped money — recording paused.")
		return
	end
	if not FLT.db.options.trackMoney then
		return
	end
	copper = tonumber(copper) or 0
	if copper == 0 then
		return
	end

	local session = FLT.GetSession()
	local entry = {
		amount = copper,
		source = Readable(source) or Readable(FLT.lastSource) or "Other",
		kind = kind or "Other",
		time = time(),
		zone = FLT.GetZoneName(),
	}
	table.insert(session.money, entry)
	FLT.UpdateMoneyStats(copper)
	if copper > 0 then
		FLT.Debug("Money +" .. FLT.FormatMoney(copper) .. " ← " .. entry.source)
	else
		FLT.Debug("Money -" .. FLT.FormatMoney(-copper) .. " ← " .. entry.source)
	end

	if FLT.UI and FLT.UI.RefreshIfShown then
		FLT.UI.RefreshIfShown()
	end
	if FLT.UpdateTitanPlugin then
		FLT.UpdateTitanPlugin()
	end
end

-- Manual entry used by Add Item dialog (bypasses chat parsing).
function FLT.AddManualItem(itemID, count, looter, cost, source)
	itemID = tonumber(itemID)
	if not itemID then
		FLT.Print("Invalid item ID.")
		return false
	end
	local cached = FLT.CacheItem(itemID)
	local name, link = GetItemInfo(itemID)
	if C_Item and C_Item.RequestLoadItemDataByID then
		C_Item.RequestLoadItemDataByID(itemID)
	end
	link = link or (cached and cached.link) or ("item:" .. itemID)
	if not link:find("|Hitem:") then
		-- Build a basic hyperlink if client hasn't cached full colored link yet.
		link = format("|Hitem:%d::::::::%d:::::|h[%s]|h", itemID, UnitLevel("player") or 1, name or ("Item " .. itemID))
	end
	local session = FLT.GetSession()
	local entry = {
		itemID = itemID,
		link = link,
		count = tonumber(count) or 1,
		cost = tonumber(cost) or (FLT.db.options.defaultCost or 0),
		looter = looter and looter ~= "" and looter or PlayerName(),
		source = source and source ~= "" and source or "Entered",
		sourceType = FLT.SOURCE.Entered,
		rollType = nil,
		time = time(),
		zone = FLT.GetZoneName(),
	}
	-- Force cache refresh after possible async item load.
	FLT.CacheItem(itemID, link)
	table.insert(session.items, entry)
	session.firstLoot = session.firstLoot or entry.time
	session.lastLoot = entry.time
	if FLT.UI and FLT.UI.Refresh then
		FLT.UI.Refresh()
	end
	if FLT.RefreshObjectiveTracker then
		FLT.RefreshObjectiveTracker()
	end
	FLT.Print(("Manually added %s x%d."):format(name or ("Item " .. itemID), entry.count))
	return true
end

local function ParseCopperFromMoneyText(text)
	text = Readable(text)
	if not text then
		return 0
	end
	local copper = 0
	local ok, g = pcall(string.match, text, "(%d+)%s*Gold")
	if not ok or not g then
		ok, g = pcall(string.match, text, "(%d+)[gG]")
	end
	local s, c
	ok, s = pcall(string.match, text, "(%d+)%s*Silver")
	if not ok or not s then
		ok, s = pcall(string.match, text, "(%d+)[sS]")
	end
	ok, c = pcall(string.match, text, "(%d+)%s*Copper")
	if not ok or not c then
		ok, c = pcall(string.match, text, "(%d+)[cC]")
	end

	if not g and not s and not c then
		local nums = {}
		for n in text:gmatch("(%d+)") do
			table.insert(nums, tonumber(n))
		end
		if #nums == 1 then
			if nums[1] < 100 then
				c = nums[1]
			else
				g = nums[1]
			end
		elseif #nums == 2 then
			s, c = nums[1], nums[2]
		elseif #nums >= 3 then
			g, s, c = nums[1], nums[2], nums[3]
		end
	end
	copper = copper + (tonumber(g) or 0) * 10000
	copper = copper + (tonumber(s) or 0) * 100
	copper = copper + (tonumber(c) or 0)
	return copper
end

-- Kept for older callers; money copper now comes from PLAYER_MONEY (Money.lua).
function FLT.OnChatMoney(text)
	if FLT.SetMoneyMode then
		FLT.SetMoneyMode("Loot", nil, 3)
		return
	end
	local copper = ParseCopperFromMoneyText(text)
	if copper > 0 then
		FLT.AddMoneyRecord(copper, "Loot", "Loot")
	end
end

--------------------------------------------------------------------------------
-- Group-loot roll dedupe
-- Classic fires both "You/Name won: [item]" and "You/Name receive(s) loot: [item]".
-- Keep a single Rolled entry; suppress the matching receive (or upgrade a prior Dropped).
--------------------------------------------------------------------------------
local ROLL_DEDUPE_WINDOW = 12 -- seconds
local recentRollWins = {} -- { itemID, looterKey, count, t, rollType }
local recentDroppedReceives = {} -- { itemID, looterKey, count, t }

LooterKey = function(name)
	name = Readable(name) or ""
	if FLT.IsPlayerName and FLT.IsPlayerName(name) then
		return "player"
	end
	local me = PlayerName()
	if me and name == me then
		return "player"
	end
	return string.lower(name)
end

-- Cross-path dedupe: chat + loot-slot + bag-diff must not triple-count the same gain.
-- Rolled wins use a longer window so LOOT_SLOT_CLEARED after "You won" does not double-count.
local recentCaptures = {} -- { itemID, count, looterKey, t, window }

local function PruneRecentCaptures(now)
	now = now or GetTime()
	for i = #recentCaptures, 1, -1 do
		local e = recentCaptures[i]
		local win = e.window or CAPTURE_DEDUPE_WINDOW
		if now - (e.t or 0) > win then
			table.remove(recentCaptures, i)
		end
	end
end

WasCapturedRecently = function(itemID, count, looter)
	if not itemID then
		return false
	end
	PruneRecentCaptures()
	local now = GetTime()
	local key = LooterKey(looter)
	local want = tonumber(count) or 1
	for i = #recentCaptures, 1, -1 do
		local e = recentCaptures[i]
		local win = e.window or CAPTURE_DEDUPE_WINDOW
		if now - (e.t or 0) <= win
			and e.itemID == itemID
			and (tonumber(e.count) or 1) == want
			and e.looterKey == key then
			return true
		end
	end
	return false
end

NoteCapture = function(itemID, count, looter, window)
	if not itemID then
		return
	end
	PruneRecentCaptures()
	table.insert(recentCaptures, {
		itemID = itemID,
		count = tonumber(count) or 1,
		looterKey = LooterKey(looter),
		t = GetTime(),
		window = tonumber(window) or CAPTURE_DEDUPE_WINDOW,
	})
	while #recentCaptures > 48 do
		table.remove(recentCaptures, 1)
	end
end

local function PruneRollDedupe(now)
	now = now or GetTime()
	for i = #recentRollWins, 1, -1 do
		if now - (recentRollWins[i].t or 0) > ROLL_DEDUPE_WINDOW then
			table.remove(recentRollWins, i)
		end
	end
	for i = #recentDroppedReceives, 1, -1 do
		if now - (recentDroppedReceives[i].t or 0) > ROLL_DEDUPE_WINDOW then
			table.remove(recentDroppedReceives, i)
		end
	end
end

local function SameLootIdentity(aItemID, aLooter, aCount, bItemID, bLooter, bCount)
	if aItemID ~= bItemID then
		return false
	end
	if LooterKey(aLooter) ~= LooterKey(bLooter) then
		return false
	end
	aCount = tonumber(aCount) or 1
	bCount = tonumber(bCount) or 1
	return aCount == bCount
end

local function NoteRollWin(itemID, looter, count, rollType)
	if not itemID then
		return
	end
	PruneRollDedupe()
	table.insert(recentRollWins, {
		itemID = itemID,
		looterKey = LooterKey(looter),
		looter = looter,
		count = tonumber(count) or 1,
		rollType = rollType,
		t = GetTime(),
	})
end

local function ConsumeMatchingRollWin(itemID, looter, count)
	if not itemID then
		return nil
	end
	PruneRollDedupe()
	local now = GetTime()
	for i = #recentRollWins, 1, -1 do
		local r = recentRollWins[i]
		if now - (r.t or 0) <= ROLL_DEDUPE_WINDOW
			and SameLootIdentity(itemID, looter, count, r.itemID, r.looter, r.count) then
			table.remove(recentRollWins, i)
			return r
		end
	end
	return nil
end

local function NoteDroppedReceive(itemID, looter, count)
	if not itemID then
		return
	end
	PruneRollDedupe()
	table.insert(recentDroppedReceives, {
		itemID = itemID,
		looterKey = LooterKey(looter),
		looter = looter,
		count = tonumber(count) or 1,
		t = GetTime(),
	})
end

local function ConsumeMatchingDroppedReceive(itemID, looter, count)
	if not itemID then
		return false
	end
	PruneRollDedupe()
	local now = GetTime()
	for i = #recentDroppedReceives, 1, -1 do
		local r = recentDroppedReceives[i]
		if now - (r.t or 0) <= ROLL_DEDUPE_WINDOW
			and SameLootIdentity(itemID, looter, count, r.itemID, r.looter, r.count) then
			table.remove(recentDroppedReceives, i)
			return true
		end
	end
	return false
end

-- If receive landed first as Dropped, upgrade the newest matching session/queue row to Rolled.
local function UpgradeRecentDropToRolled(itemID, looter, count, rollType)
	if not itemID then
		return false
	end
	local wantKey = LooterKey(looter)
	local wantCount = tonumber(count) or 1

	-- Pending queue jobs first (not yet in session.items).
	if FLT.PeekQueueJobs then
		for _, job in ipairs(FLT.PeekQueueJobs()) do
			if job.kind == "item" and job.payload then
				local p = job.payload
				if p.itemID == itemID and (tonumber(p.count) or 1) == wantCount
					and LooterKey(p.looter) == wantKey
					and p.sourceType == FLT.SOURCE.Dropped then
					p.sourceType = FLT.SOURCE.Rolled
					p.rollType = rollType or p.rollType
					return true
				end
			end
		end
	end

	local session = FLT.GetSession and FLT.GetSession()
	if not session or not session.items then
		return false
	end
	local now = time()
	for i = #session.items, 1, -1 do
		local it = session.items[i]
		if it.itemID == itemID and (tonumber(it.count) or 1) == wantCount
			and LooterKey(it.looter) == wantKey
			and it.sourceType == FLT.SOURCE.Dropped
			and (now - (it.time or now)) <= ROLL_DEDUPE_WINDOW then
			it.sourceType = FLT.SOURCE.Rolled
			it.rollType = rollType or it.rollType
			return true
		end
	end
	return false
end

local function IsRollAnnounceLine(text, lower)
	lower = lower or (text and text:lower()) or ""
	-- Need/Greed/Pass selections and roll-number spam contain item links but are not loot.
	if TryMatch("LOOT_ROLL_NEED", text) or TryMatch("LOOT_ROLL_GREED", text)
		or TryMatch("LOOT_ROLL_PASSED", text) or TryMatch("LOOT_ROLL_ROLLED_NEED", text)
		or TryMatch("LOOT_ROLL_ROLLED_GREED", text) or TryMatch("LOOT_ROLL_ALL_PASSED", text) then
		return true
	end
	if lower:find("have selected need", 1, true) or lower:find("have selected greed", 1, true)
		or lower:find("has selected need", 1, true) or lower:find("has selected greed", 1, true)
		or lower:find("passed on:", 1, true) or lower:find(" passes on ", 1, true)
		or lower:find("everyone passes on:", 1, true)
		or lower:find("need roll", 1, true) or lower:find("greed roll", 1, true)
		or lower:find("roll -", 1, true) or lower:find("roll –", 1, true) then
		return true
	end
	return false
end

function FLT.OnChatLoot(text, playerName, ...)
	-- In instances Forever may deliver chat as secret values; arm silent capture instead.
	text = Readable(text)
	playerName = Readable(playerName)
	if not text then
		FLT.Debug("CHAT_MSG_LOOT skipped (secret/unreadable chat text) — arming silent capture.")
		-- Extend an existing loot-window watch only — never re-snapshot (item may already be in bags).
		if FLT.RequestSilentLootWatch then
			FLT.RequestSilentLootWatch(5, "extend")
		end
		return
	end

	local link = ExtractLink(text)
	if not link then
		FLT.Debug("CHAT_MSG_LOOT had no parseable item link: " .. text:sub(1, 80))
		return
	end

	local count = ExtractCount(text, link)
	local me = PlayerName()
	local looter = me
	local sourceType = FLT.SOURCE.Dropped
	local rollType = nil
	local sourceOverride = nil
	local lower = text:lower()

	if IsRollAnnounceLine(text, lower) then
		FLT.Debug("Skipped roll announcement line.")
		return
	end

	-- Crafted items use LOOT_ITEM_CREATED_SELF / "You create" — must not be treated as Dropped.
	local selfCrafted = TryMatch("LOOT_ITEM_CREATED_SELF", text)
		or TryMatch("LOOT_ITEM_CREATED_SELF_MULTIPLE", text)
		or TryMatch("TRADESKILL_LOG_FIRSTPERSON", text)
		or lower:find("you create:")
		or lower:find("you create ")

	local selfLoot = TryMatch("LOOT_ITEM_SELF", text)
		or TryMatch("LOOT_ITEM_SELF_MULTIPLE", text)
		or TryMatch("LOOT_ITEM_PUSHED_SELF", text)
		or TryMatch("LOOT_ITEM_PUSHED_SELF_MULTIPLE", text)
		or lower:find("you receive loot")
		or lower:find("you receive item")

	local selfWon = TryMatch("LOOT_ROLL_YOU_WON", text)
		or TryMatch("LOOT_ROLL_YOU_WON_NO_GREED", text)
		or lower:find("you won:")
		or lower:find("you won :")

	local selfGain = false
	if selfCrafted then
		looter = me
		sourceType = FLT.SOURCE.Crafted
		-- Prefer the open skill line (e.g. First Aid) over a prior sticky (e.g. Tailoring).
		sourceOverride = (FLT.GetActiveProfessionName and FLT.GetActiveProfessionName()) or "Crafting"
		if sourceOverride ~= "Crafting" then
			FLT.craftingProfession = sourceOverride
		end
		FLT.lastSource = sourceOverride
		FLT.lastSourceKind = "Crafted"
		selfGain = true
	elseif selfLoot then
		looter = me
		-- Merchant buys arrive as "You receive item:" while the vendor UI is open.
		if FLT.IsVendorPurchaseContext and FLT.IsVendorPurchaseContext() then
			local vendor = (FLT.GetActiveVendorName and FLT.GetActiveVendorName()) or "Vendor"
			sourceType = FLT.SOURCE.Purchased
			sourceOverride = vendor
			FLT.lastSource = vendor
			FLT.lastSourceKind = "Vendor"
		elseif not IsLootWindowActive() and FLT.IsDisenchantContext and FLT.IsDisenchantContext()
			and FLT.IsDisenchantMaterial and FLT.IsDisenchantMaterial(link) then
			-- DE mats via pushed chat — only while DE sticky is active (not bare "shard/dust" names).
			-- Prefer DE over bank: you can disenchant while the bank UI is open.
			sourceType = FLT.SOURCE.Crafted
			sourceOverride = "Disenchanting"
			ApplyDisenchantAttribution()
		elseif not IsLootWindowActive() and FLT.IsQuestItemContext and FLT.IsQuestItemContext() then
			-- Quest accept/turn-in grants use the same pushed-item chat as mail.
			sourceType = FLT.SOURCE.Dropped
			sourceOverride = "Quest"
			FLT.lastSource = "Quest"
			FLT.lastSourceKind = "Quest"
		elseif not IsLootWindowActive() and IsMailItem() then
			-- Mailbox attachments use LOOT_ITEM_PUSHED_SELF / "You receive item:".
			sourceType = FLT.SOURCE.Dropped
			sourceOverride = "Mailbox"
			FLT.lastSource = "Mailbox"
			FLT.lastSourceKind = "Mail"
		elseif not IsLootWindowActive() and FLT.IsBankTransferContext and FLT.IsBankTransferContext() then
			-- Bank/guild-bank withdrawals use the same pushed chat — skip after real sources above.
			FLT.Debug("Skipped bank/guild bank transfer.")
			return
		else
			sourceType = FLT.SOURCE.Dropped
			-- Don't keep a stale Mailbox/Quest label on unrelated bag pushes.
			if FLT.lastSourceKind == "Mail" or FLT.lastSourceKind == "Quest" then
				FLT.lastSource = "Unknown"
				FLT.lastSourceKind = nil
			end
		end
		selfGain = true
	elseif selfWon then
		looter = me
		sourceType = FLT.SOURCE.Rolled
	elseif TryMatch("LOOT_ITEM", text) or TryMatch("LOOT_ITEM_MULTIPLE", text)
		or lower:find(" receives loot:") or lower:find(" receive loot:") then
		local who = text:match("^(.-) receives loot:") or text:match("^(.-) receive loot:")
		looter = Readable(who) or playerName or "Unknown"
		sourceType = FLT.SOURCE.Dropped
		do
			local isMe = FLT.IsPlayerName and FLT.IsPlayerName(looter) or (looter == me)
			if not FLT.db.options.trackPartyLoot and not isMe then
				return
			end
			selfGain = isMe
			if isMe then
				looter = me
			end
		end
	else
		local other = text:match("^(.-) won:") or text:match("^(.-) won :")
		other = Readable(other)
		if other then
			looter = other
			sourceType = FLT.SOURCE.Rolled
			local isMe = FLT.IsPlayerName and FLT.IsPlayerName(looter) or (looter == me)
			if not FLT.db.options.trackPartyLoot and not isMe then
				return
			end
			if isMe then
				looter = me
			end
		else
			local givenTo = text:match("has been given to (.+)%.")
			givenTo = Readable(givenTo)
			if givenTo then
				looter = givenTo
				sourceType = FLT.SOURCE.Master
				local isMe = FLT.IsPlayerName and FLT.IsPlayerName(looter) or (looter == me)
				if not FLT.db.options.trackPartyLoot and not isMe then
					return
				end
				if isMe then
					looter = me
				end
			elseif playerName and playerName ~= ""
				and not ((FLT.IsPlayerName and FLT.IsPlayerName(playerName)) or playerName == me) then
				looter = playerName
				if not FLT.db.options.trackPartyLoot then
					return
				end
			else
				-- Link present in loot chat with no better classification → assume self gain.
				looter = me
				if FLT.IsVendorPurchaseContext and FLT.IsVendorPurchaseContext() then
					local vendor = (FLT.GetActiveVendorName and FLT.GetActiveVendorName()) or "Vendor"
					sourceType = FLT.SOURCE.Purchased
					sourceOverride = vendor
					FLT.lastSource = vendor
					FLT.lastSourceKind = "Vendor"
				elseif not IsLootWindowActive() and FLT.IsDisenchantContext and FLT.IsDisenchantContext()
					and FLT.IsDisenchantMaterial and FLT.IsDisenchantMaterial(link) then
					sourceType = FLT.SOURCE.Crafted
					sourceOverride = "Disenchanting"
					ApplyDisenchantAttribution()
				elseif not IsLootWindowActive() and FLT.IsQuestItemContext and FLT.IsQuestItemContext() then
					sourceType = FLT.SOURCE.Dropped
					sourceOverride = "Quest"
					FLT.lastSource = "Quest"
					FLT.lastSourceKind = "Quest"
				elseif not IsLootWindowActive() and IsMailItem() then
					sourceType = FLT.SOURCE.Dropped
					sourceOverride = "Mailbox"
					FLT.lastSource = "Mailbox"
					FLT.lastSourceKind = "Mail"
				elseif not IsLootWindowActive() and FLT.IsBankTransferContext and FLT.IsBankTransferContext() then
					FLT.Debug("Skipped bank/guild bank transfer.")
					return
				else
					sourceType = FLT.SOURCE.Dropped
					if FLT.lastSourceKind == "Mail" or FLT.lastSourceKind == "Quest" then
						FLT.lastSource = "Unknown"
						FLT.lastSourceKind = nil
					end
				end
				selfGain = true
			end
		end
	end

	-- Bag essence split/merge lands as receive/pushed Dropped (sticky NPC source), not Crafted.
	if ShouldSkipEssenceConvert(link, selfGain) then
		FLT.Debug("Skipped essence convert: " .. (link:match("%[(.-)%]") or "?"))
		return
	end

	if sourceType == FLT.SOURCE.Rolled then
		if text:find("%(Need%)") or lower:find(" for need") then
			rollType = "Need"
		elseif text:find("%(Greed%)") or lower:find(" for greed") then
			rollType = "Greed"
		end
	end

	local itemID = ExtractItemID(link)

	-- "Name won" after a Dropped receive already logged → upgrade, don't double-count.
	if sourceType == FLT.SOURCE.Rolled then
		ConsumeMatchingDroppedReceive(itemID, looter, count)
		if UpgradeRecentDropToRolled(itemID, looter, count, rollType) then
			FLT.Debug("Roll win upgraded prior receive (no duplicate): " .. (link:match("%[(.-)%]") or "?"))
			if FLT.UI and FLT.UI.RefreshIfShown then
				FLT.UI.RefreshIfShown()
			end
			return
		end
		NoteRollWin(itemID, looter, count, rollType)
	elseif sourceType == FLT.SOURCE.Dropped then
		-- Matching "won" already recorded as Rolled → skip the receive line.
		if ConsumeMatchingRollWin(itemID, looter, count) then
			FLT.Debug("Suppressed duplicate receive after roll win: " .. (link:match("%[(.-)%]") or "?"))
			return
		end
		NoteDroppedReceive(itemID, looter, count)
	end

	FLT.AddItemRecord(link, count, looter, sourceType, rollType, sourceOverride)
end

--------------------------------------------------------------------------------
-- Crafting / profession context
--------------------------------------------------------------------------------
FLT.craftingProfession = nil
FLT.craftingActiveUntil = 0

local function ReadableProfession(name)
	name = Readable(name)
	if not name or name == "" or name == "UNKNOWN" or name == "UNKNOWN_SPELL" then
		return nil
	end
	return name
end

-- Read the profession currently shown in the skill UI (not the sticky cache).
local function GetLiveProfessionName()
	if GetTradeSkillLine then
		local ok, name = pcall(GetTradeSkillLine)
		if ok then
			name = ReadableProfession(name)
			if name then
				return name
			end
		end
	end
	if GetCraftDisplaySkillLine then
		local ok, name = pcall(GetCraftDisplaySkillLine)
		if ok then
			name = ReadableProfession(name)
			if name then
				return name
			end
		end
	end
	if GetCraftName then
		local ok, name = pcall(GetCraftName)
		if ok then
			name = ReadableProfession(name)
			-- Ignore pet training / disguise pseudo-crafts.
			if name and name ~= "Beast Training" and name ~= "Disguise" then
				return name
			end
		end
	end
	if C_TradeSkillUI then
		if C_TradeSkillUI.GetBaseProfessionInfo then
			local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
			if ok and info then
				local name = ReadableProfession(info.professionName or info.parentProfessionName)
				if name then
					return name
				end
			end
		end
		if C_TradeSkillUI.GetTradeSkillDisplayName then
			local ok, name = pcall(C_TradeSkillUI.GetTradeSkillDisplayName)
			if ok then
				name = ReadableProfession(name)
				if name then
					return name
				end
			end
		end
	end
	return nil
end

function FLT.GetActiveProfessionName()
	-- Live skill window always wins (Tailoring → First Aid must not keep sticky Tailoring).
	local live = GetLiveProfessionName()
	if live then
		return live
	end
	if FLT.craftingProfession and FLT.craftingProfession ~= "" and FLT.craftingProfession ~= "Crafting" then
		return FLT.craftingProfession
	end
	return "Crafting"
end

local function CraftingWindowOpen()
	if TradeSkillFrame and TradeSkillFrame.IsShown and TradeSkillFrame:IsShown() then
		return true
	end
	if CraftFrame and CraftFrame.IsShown and CraftFrame:IsShown() then
		return true
	end
	if ProfessionsFrame and ProfessionsFrame.IsShown and ProfessionsFrame:IsShown() then
		return true
	end
	return false
end

-- active=true: skill window opened. refreshOnly: list/data update — update name if open, never +600s.
function FLT.SetCraftingContext(active, refreshOnly)
	if refreshOnly then
		if not CraftingWindowOpen() then
			return
		end
		local name = GetLiveProfessionName()
		if name then
			FLT.craftingProfession = name
			FLT.lastSource = name
			FLT.lastSourceKind = "Crafted"
		end
		return
	end
	if active then
		local name = GetLiveProfessionName() or "Crafting"
		if name == "Crafting" then
			-- Retry once the UI finishes loading the skill line.
			if C_Timer and C_Timer.After then
				C_Timer.After(0.1, function()
					if not CraftingWindowOpen() then
						return
					end
					local n = GetLiveProfessionName()
					if not n then
						return
					end
					FLT.craftingProfession = n
					FLT.lastSource = n
					FLT.lastSourceKind = "Crafted"
					FLT.craftingActiveUntil = GetTime() + 120
					FLT.Debug("Crafting context (deferred): " .. tostring(n))
				end)
			end
		end
		FLT.craftingProfession = name
		FLT.lastSource = name
		FLT.lastSourceKind = "Crafted"
		-- While the window is open keep sticky modest; close shortens to 8s.
		FLT.craftingActiveUntil = GetTime() + 120
		FLT.Debug("Crafting context: " .. tostring(name))
	else
		-- Keep profession sticky briefly so "You create" after close still attributes.
		FLT.craftingActiveUntil = GetTime() + 8
	end
end

function FLT.OnTradeSkillChat(text)
	text = Readable(text)
	if not text then
		return
	end
	-- CHAT_MSG_TRADESKILL often duplicates create messages; loot path handles items.
	-- Refresh from the live skill line whenever a window is open.
	local name = GetLiveProfessionName()
	if name then
		FLT.craftingProfession = name
		FLT.lastSource = name
		FLT.lastSourceKind = "Crafted"
		if FLT.craftingActiveUntil < GetTime() then
			FLT.craftingActiveUntil = GetTime() + 8
		end
	end
end

--------------------------------------------------------------------------------
-- Kill/source attribution WITHOUT combat log (forbidden / secret on Forever).
-- Uses encounter events + last readable target/mouseover name.
--------------------------------------------------------------------------------
function FLT.RememberUnitSource(unit)
	-- While crafting, keep profession as the source (don't overwrite with NPC/target).
	if FLT.craftingActiveUntil and GetTime() < FLT.craftingActiveUntil and FLT.lastSourceKind == "Crafted" then
		return
	end
	-- While shopping, keep the merchant name (don't overwrite with sticky kill targets).
	if FLT.lastSourceKind == "Vendor" or (FLT.IsVendorPurchaseContext and FLT.IsVendorPurchaseContext()) then
		return
	end
	-- While reading mail, keep Mailbox (don't overwrite with sticky kill targets).
	if IsMailItem() then
		return
	end
	-- While accepting/turning in a quest, keep Quest attribution.
	if FLT.IsQuestItemContext and FLT.IsQuestItemContext() then
		return
	end
	-- While disenchanting, keep Disenchanting attribution for shard/dust chat.
	if FLT.IsDisenchantContext and FLT.IsDisenchantContext() then
		return
	end
	-- During an encounter, do not let mouseover/target churn replace the boss name.
	if FLT.encounterStickyUntil and GetTime() < FLT.encounterStickyUntil then
		return
	end
	local name = Readable(UnitName(unit))
	if not name or name == "" then
		return
	end
	-- Prefer attackable NPCs / bosses; skip the player.
	if UnitIsUnit(unit, "player") then
		return
	end
	if UnitIsPlayer and UnitIsPlayer(unit) then
		return
	end
	FLT.lastSource = name
	FLT.lastSourceKind = "Creature"
	FLT.killResetAt = GetTime() + 90
	FLT.Debug("Source hint: " .. name)
end

function FLT.OnEncounterStart(encounterID, encounterName)
	encounterName = Readable(encounterName)
	if encounterName and encounterName ~= "" then
		FLT.lastSource = encounterName
		FLT.lastSourceKind = "Creature"
		FLT.killResetAt = GetTime() + 600
		FLT.encounterStickyUntil = GetTime() + 600
		FLT.Debug("Encounter source: " .. encounterName)
	end
end

function FLT.OnEncounterEnd()
	-- Keep the encounter name briefly for late loot windows, then clear via ticker.
	FLT.killResetAt = GetTime() + 120
	FLT.encounterStickyUntil = GetTime() + 120
end

-- Soft clear of stale sources.
C_Timer.NewTicker(5, function()
	if FLT.craftingActiveUntil and GetTime() < FLT.craftingActiveUntil then
		return
	end
	if FLT.craftingActiveUntil and FLT.craftingActiveUntil > 0 and GetTime() >= FLT.craftingActiveUntil then
		if FLT.lastSourceKind == "Crafted" then
			FLT.lastSource = "Unknown"
			FLT.lastSourceKind = nil
		end
		FLT.craftingProfession = nil
		FLT.craftingActiveUntil = 0
	end
	if FLT.disenchantStickyUntil and FLT.disenchantStickyUntil > 0 and GetTime() >= FLT.disenchantStickyUntil then
		if FLT.lastSourceKind == "Disenchant" then
			FLT.lastSource = "Unknown"
			FLT.lastSourceKind = nil
		end
		FLT.disenchantStickyUntil = 0
	end
	if FLT.encounterStickyUntil and FLT.encounterStickyUntil > 0 and GetTime() >= FLT.encounterStickyUntil then
		FLT.encounterStickyUntil = 0
	end
	if FLT.killResetAt and FLT.killResetAt > 0 and GetTime() >= FLT.killResetAt then
		if FLT.IsDisenchantContext and FLT.IsDisenchantContext() then
			return
		end
		if FLT.encounterStickyUntil and GetTime() < FLT.encounterStickyUntil then
			return
		end
		local src = Readable(FLT.lastSource)
		if src ~= "Quest" and FLT.lastSourceKind ~= "Crafted" and FLT.lastSourceKind ~= "Vendor"
			and FLT.lastSourceKind ~= "Mail" and FLT.lastSourceKind ~= "Disenchant"
			and FLT.lastSourceKind ~= "Quest" then
			FLT.lastSource = "Unknown"
			FLT.lastSourceKind = nil
		end
		FLT.killResetAt = 0
	end
end)

--------------------------------------------------------------------------------
-- Instance-safe loot capture (chat may be Secret).
-- Paths: LOOT_OPENED slot snapshot → LOOT_SLOT_CLEARED, plus short bag-diff watch.
--------------------------------------------------------------------------------
local lootSlots = {} -- [slot] = { link=, count=, itemID=, currencyID= }
local bagCounts = {} -- [itemID] = total count
local bagWatchUntil = 0
local bagDiffPending = false

local function LinkFromItemID(itemID)
	itemID = tonumber(itemID)
	if not itemID then
		return nil
	end
	local link
	if C_Item and C_Item.GetItemLink then
		local ok, v = pcall(C_Item.GetItemLink, itemID)
		if ok then
			link = Readable(v)
		end
	end
	if not link then
		local ok, _, itemLink = pcall(GetItemInfo, itemID)
		if ok then
			link = Readable(itemLink)
		end
	end
	return link or ("item:" .. tostring(itemID))
end

local function BagSlotCount(bag, slot)
	if C_Container and C_Container.GetContainerItemInfo then
		local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
		if ok and info then
			local id = info.itemID
			if not id and info.hyperlink then
				id = ExtractItemID(Readable(info.hyperlink))
			end
			local stack = info.stackCount or info.quantity or 1
			return id, stack, Readable(info.hyperlink)
		end
	end
	if GetContainerItemInfo then
		local ok, texture, count, _, _, _, link = pcall(GetContainerItemInfo, bag, slot)
		if ok and (texture or link) then
			link = Readable(link)
			return ExtractItemID(link), count or 1, link
		end
	end
	return nil, 0, nil
end

local function MaxBagIndex()
	if NUM_TOTAL_EQUIPPED_BAG_SLOTS then
		return NUM_TOTAL_EQUIPPED_BAG_SLOTS
	end
	if NUM_BAG_SLOTS then
		return NUM_BAG_SLOTS
	end
	return 4
end

local function SnapshotBagCounts()
	wipe(bagCounts)
	for bag = 0, MaxBagIndex() do
		local slots = 0
		if C_Container and C_Container.GetContainerNumSlots then
			local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
			if ok then
				slots = n or 0
			end
		elseif GetContainerNumSlots then
			slots = GetContainerNumSlots(bag) or 0
		end
		for slot = 1, slots do
			local id, stack = BagSlotCount(bag, slot)
			if id then
				bagCounts[id] = (bagCounts[id] or 0) + (stack or 1)
			end
		end
	end
end

local lootWindowWatch = false -- bag-diff only after a real loot window (not random bag churn)

local function NoisyServiceOpen()
	if FLT.IsVendorPurchaseContext and FLT.IsVendorPurchaseContext() then
		return true
	end
	if FLT.IsMailItemContext and FLT.IsMailItemContext() then
		return true
	end
	if FLT.IsBankTransferContext and FLT.IsBankTransferContext() then
		return true
	end
	if TradeFrame and TradeFrame.IsShown and TradeFrame:IsShown() then
		return true
	end
	return false
end

-- mode: "reset" = new baseline (loot window open); "extend" = keep baseline (secret chat / slot miss).
function FLT.RequestSilentLootWatch(seconds, mode)
	seconds = tonumber(seconds) or 4
	local armed = bagWatchUntil > GetTime()
	local untilT = GetTime() + seconds
	if untilT > bagWatchUntil then
		bagWatchUntil = untilT
	end
	if mode == "reset" or (mode ~= "extend" and not armed) then
		SnapshotBagCounts()
		FLT.Debug("Silent loot watch armed (reset baseline) for " .. tostring(seconds) .. "s")
	else
		FLT.Debug("Silent loot watch extended (kept baseline) for " .. tostring(seconds) .. "s")
	end
end

local function CaptureLootSlotEntry(slot)
	local entry = lootSlots[slot]
	if not entry then
		return
	end
	lootSlots[slot] = nil
	if entry.currencyID and FLT.AddCurrencyRecord then
		if FLT.NoteCurrencyCaptured then
			FLT.NoteCurrencyCaptured(entry.currencyID, entry.count or 1)
		end
		FLT.AddCurrencyRecord(entry.currencyID, entry.count or 1, entry.name, nil, FLT.lastSource or "Loot")
		return
	end
	if entry.link then
		FLT.AddItemRecord(entry.link, entry.count or 1, PlayerName(), FLT.SOURCE.Dropped)
	elseif entry.itemID then
		FLT.AddItemRecord(LinkFromItemID(entry.itemID), entry.count or 1, PlayerName(), FLT.SOURCE.Dropped)
	end
end

function FLT.SnapshotLootWindow()
	wipe(lootSlots)
	if not GetNumLootItems then
		return
	end
	local okN, n = pcall(GetNumLootItems)
	if not okN or not n or n <= 0 then
		return
	end
	local moneyType = LOOT_SLOT_MONEY or 2
	local currencyType = LOOT_SLOT_CURRENCY or 3
	for i = 1, n do
		local slotType = moneyType
		if GetLootSlotType then
			local okT, t = pcall(GetLootSlotType, i)
			if okT and t ~= nil then
				slotType = t
			end
		end
		if slotType == moneyType then
			-- Gold from corpse loot is handled by PLAYER_MONEY.
		elseif slotType == currencyType then
			local quantity, currencyID, name
			if GetLootSlotInfo then
				-- Classic/retail arg order varies; prefer currencyID when present.
				local ok, a, b, c, d, e = pcall(GetLootSlotInfo, i)
				if ok then
					-- Common: texture, itemName, quantity, currencyID, quality
					quantity = tonumber(c) or 1
					currencyID = tonumber(d)
					name = Readable(b)
					if not currencyID and type(e) == "number" and e > 100 then
						currencyID = e
					end
				end
			end
			if currencyID then
				lootSlots[i] = { currencyID = currencyID, count = quantity or 1, name = name }
			end
		else
			local link = nil
			if GetLootSlotLink then
				local okL, v = pcall(GetLootSlotLink, i)
				if okL then
					link = Readable(v)
				end
			end
			local quantity = 1
			if GetLootSlotInfo then
				local ok, _, _, qty = pcall(GetLootSlotInfo, i)
				if ok and qty then
					quantity = tonumber(qty) or 1
				end
			end
			local itemID = ExtractItemID(link)
			if link or itemID then
				lootSlots[i] = { link = link, itemID = itemID, count = quantity }
			end
		end
	end
	FLT.Debug("Loot window snapshot: " .. tostring(n) .. " slot(s)")
end

function FLT.OnLootWindowOpened()
	lootWindowWatch = true
	-- Reset baseline at window open (before loot is taken).
	FLT.RequestSilentLootWatch(6, "reset")
	FLT.SnapshotLootWindow()
	-- Clear DE sticky so corpse/chest loot after DE is not labelled Disenchanting.
	if FLT.ClearDisenchantSticky then
		FLT.ClearDisenchantSticky()
	end
end

function FLT.OnLootSlotCleared(slotIndex)
	slotIndex = tonumber(slotIndex)
	if not slotIndex then
		return
	end
	if lootSlots[slotIndex] then
		CaptureLootSlotEntry(slotIndex)
		return
	end
	-- Slot was never snapshotted (fast autoloot); extend watch without wiping baseline.
	FLT.RequestSilentLootWatch(3, "extend")
end

function FLT.OnLootWindowClosed()
	-- Any remaining snapshotted slots were likely auto-looted without CLEARED.
	for slot in pairs(lootSlots) do
		CaptureLootSlotEntry(slot)
	end
	wipe(lootSlots)
	if bagWatchUntil > GetTime() and lootWindowWatch then
		if C_Timer and C_Timer.After then
			C_Timer.After(0.35, function()
				if FLT.DiffBagsForSilentLoot then
					FLT.DiffBagsForSilentLoot()
				end
			end)
		else
			FLT.DiffBagsForSilentLoot()
		end
	end
end

function FLT.DiffBagsForSilentLoot()
	if GetTime() > bagWatchUntil then
		lootWindowWatch = false
		return
	end
	-- Only attribute bag gains that follow a loot window (not gear swaps / random churn).
	if not lootWindowWatch then
		return
	end
	if NoisyServiceOpen() then
		SnapshotBagCounts()
		return
	end
	-- Skip while crafting UI owns the bag churn.
	if FLT.craftingActiveUntil and GetTime() < FLT.craftingActiveUntil then
		SnapshotBagCounts()
		return
	end
	local nowCounts = {}
	local links = {}
	for bag = 0, MaxBagIndex() do
		local slots = 0
		if C_Container and C_Container.GetContainerNumSlots then
			local ok, n = pcall(C_Container.GetContainerNumSlots, bag)
			if ok then
				slots = n or 0
			end
		elseif GetContainerNumSlots then
			slots = GetContainerNumSlots(bag) or 0
		end
		for slot = 1, slots do
			local id, stack, link = BagSlotCount(bag, slot)
			if id then
				nowCounts[id] = (nowCounts[id] or 0) + (stack or 1)
				if link and not links[id] then
					links[id] = link
				end
			end
		end
	end
	for id, count in pairs(nowCounts) do
		local prev = bagCounts[id] or 0
		if count > prev then
			local delta = count - prev
			local link = links[id] or LinkFromItemID(id)
			FLT.Debug("Bag-diff loot +" .. tostring(delta) .. " item " .. tostring(id))
			FLT.AddItemRecord(link, delta, PlayerName(), FLT.SOURCE.Dropped)
		end
	end
	wipe(bagCounts)
	for id, count in pairs(nowCounts) do
		bagCounts[id] = count
	end
end

function FLT.OnBagUpdateForLoot()
	if GetTime() > bagWatchUntil then
		return
	end
	if bagDiffPending then
		return
	end
	bagDiffPending = true
	local function run()
		bagDiffPending = false
		FLT.DiffBagsForSilentLoot()
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0.2, run)
	else
		run()
	end
end
