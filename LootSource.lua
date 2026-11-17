-- ForeverLootTracker — detect chest / gathering / fishing / corpse loot sources.
local FLT = ForeverLootTracker

local function Readable(v)
	if v == nil or v == "" then
		return nil
	end
	if issecretvalue and issecretvalue(v) then
		return nil
	end
	return v
end

local function GuidKind(guid)
	guid = Readable(guid)
	if not guid then
		return nil
	end
	return guid:match("^(%w+)%-")
end

-- Classic Forever mining / herb gathering ranks (spellID).
local GATHER_SPELL_IDS = {
	-- Mining
	[2575] = "Mining",
	[2576] = "Mining",
	[3564] = "Mining",
	[10248] = "Mining",
	[29354] = "Mining",
	[50310] = "Mining",
	[74517] = "Mining",
	-- Herb Gathering
	[2366] = "Herbalism",
	[2368] = "Herbalism",
	[3570] = "Herbalism",
	[11993] = "Herbalism",
	[28695] = "Herbalism",
	[50300] = "Herbalism",
	[74519] = "Herbalism",
}

-- Classic herb node names (lowercase). Ore uses Vein/Deposit/Seam patterns.
local HERB_NODE_NAMES = {
	["peacebloom"] = true,
	["silverleaf"] = true,
	["earthroot"] = true,
	["mageroyal"] = true,
	["briarthorn"] = true,
	["stranglekelp"] = true,
	["bruiseweed"] = true,
	["wild steelbloom"] = true,
	["grave moss"] = true,
	["kingsblood"] = true,
	["liferoot"] = true,
	["fadeleaf"] = true,
	["goldthorn"] = true,
	["khadgar's whisker"] = true,
	["wintersbite"] = true,
	["firebloom"] = true,
	["purple lotus"] = true,
	["arthas' tears"] = true,
	["sungrass"] = true,
	["blindweed"] = true,
	["ghost mushroom"] = true,
	["gromsblood"] = true,
	["golden sansam"] = true,
	["dreamfoil"] = true,
	["mountain silversage"] = true,
	["plaguebloom"] = true,
	["icecap"] = true,
	["black lotus"] = true,
	["bloodthistle"] = true,
	["felweed"] = true,
	["dreaming glory"] = true,
	["ragveil"] = true,
	["flame cap"] = true,
	["terocone"] = true,
	["ancient lichen"] = true,
	["netherbloom"] = true,
	["nightmare vine"] = true,
	["mana thistle"] = true,
	["fel lotus"] = true,
}

local function SpellNameFromID(spellID)
	if not spellID then
		return nil
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local ok, info = pcall(C_Spell.GetSpellInfo, spellID)
		if ok and info then
			return Readable(info.name)
		end
	end
	if GetSpellInfo then
		local ok, name = pcall(GetSpellInfo, spellID)
		if ok then
			return Readable(name)
		end
	end
	return nil
end

local function ClassifyGatherSpell(spellID, spellName)
	spellID = tonumber(spellID)
	if spellID and GATHER_SPELL_IDS[spellID] then
		return GATHER_SPELL_IDS[spellID]
	end
	spellName = Readable(spellName) or SpellNameFromID(spellID)
	if not spellName then
		return nil
	end
	local lower = spellName:lower()
	if lower == "mining" or lower:find("mining", 1, true) then
		return "Mining"
	end
	if lower == "herb gathering" or lower == "herbalism" or lower:find("herb", 1, true) then
		return "Herbalism"
	end
	return nil
end

local function IsMiningNodeName(name)
	name = Readable(name)
	if not name then
		return false
	end
	local lower = name:lower()
	return lower:find("vein", 1, true) ~= nil
		or lower:find("deposit", 1, true) ~= nil
		or lower:find("seam", 1, true) ~= nil
end

local function IsHerbNodeName(name)
	name = Readable(name)
	if not name then
		return false
	end
	return HERB_NODE_NAMES[name:lower()] == true
end

local function IsGatheringNodeName(name)
	return IsMiningNodeName(name) or IsHerbNodeName(name)
end

function FLT.NoteGatherCast(spellID, spellName, eventName)
	local kind = ClassifyGatherSpell(spellID, spellName)
	if not kind then
		return
	end
	-- Arm on SUCCEEDED (and START as early hint). Ignore STOP — cancelled casts were
	-- turning nearby chests into "Gathering".
	if eventName == "UNIT_SPELLCAST_STOP" then
		return
	end
	FLT.gatherStickyUntil = GetTime() + 10
	FLT.gatherStickyKind = kind
	FLT.Debug("Gather cast sticky: " .. kind)
end

-- Classic Disenchant; shards/dust arrive as pushed item chat (same channel as mail).
local DISENCHANT_SPELL_IDS = {
	[13262] = true, -- Disenchant
}

function FLT.NoteDisenchantCast(spellID, spellName, eventName)
	spellID = tonumber(spellID)
	local name = Readable(spellName) or SpellNameFromID(spellID)
	local lower = name and name:lower() or ""
	local isDE = (spellID and DISENCHANT_SPELL_IDS[spellID])
		or lower == "disenchant"
		or lower:find("disenchant", 1, true) ~= nil
	if not isDE then
		return false
	end
	-- Arm on START/SUCCEEDED only — STOP fires for cancelled casts and was swallowing loot.
	if eventName == "UNIT_SPELLCAST_STOP" then
		return true
	end
	FLT.disenchantStickyUntil = GetTime() + 8
	FLT.lastSource = "Disenchanting"
	FLT.lastSourceKind = "Disenchant"
	-- DE after mail must not keep Mailbox attribution.
	FLT.mailStickyUntil = nil
	FLT.mailItemStickyUntil = nil
	FLT.Debug("Disenchant sticky (" .. tostring(spellID or name) .. ")")
	return true
end

function FLT.IsDisenchantContext()
	return FLT.disenchantStickyUntil and GetTime() < FLT.disenchantStickyUntil
end

function FLT.ClearDisenchantSticky()
	FLT.disenchantStickyUntil = 0
	if FLT.lastSourceKind == "Disenchant" then
		FLT.lastSource = "Unknown"
		FLT.lastSourceKind = nil
	end
end

-- Classic enchanting DE results (dust / shard / crystal). Essences handled separately.
local DISENCHANT_MAT_IDS = {
	-- Dust
	[10940] = true, [11083] = true, [11137] = true, [11176] = true, [16204] = true,
	-- Shards
	[10978] = true, [11084] = true, [11138] = true, [11139] = true,
	[11177] = true, [11178] = true, [14343] = true, [14344] = true,
	-- Crystals
	[20725] = true, -- Nexus Crystal
	[22445] = true, -- Arcane Dust (TBC+)
	[22446] = true, [22447] = true, [22448] = true, [22449] = true, [22450] = true,
}

function FLT.IsDisenchantMaterial(link, itemID)
	-- Strict ID table only — bare "shard/dust" name matching stole Soul Shards / quest mats.
	itemID = tonumber(itemID)
	if not itemID and link then
		local ok, id = pcall(string.match, Readable(link) or "", "item:(%d+)")
		if ok then
			itemID = tonumber(id)
		end
	end
	return itemID and DISENCHANT_MAT_IDS[itemID] == true
end

local function GatherStickyActive()
	return FLT.gatherStickyUntil and GetTime() < FLT.gatherStickyUntil and FLT.gatherStickyKind
end

local function MarkGathering(nodeName)
	local label = "Gathering"
	FLT.lastSource = label
	FLT.lastSourceKind = "Gathering"
	FLT.gatherStickyUntil = nil
	FLT.gatherStickyKind = nil
	if FLT.SetMoneyMode then
		FLT.SetMoneyMode("Loot", label, 5)
	end
	FLT.Debug("Loot source Gathering" .. (nodeName and (": " .. nodeName) or ""))
	return label, "Gathering"
end

local function MarkItemBox(objectName)
	local label = objectName or "Chest"
	FLT.lastSource = label
	FLT.lastSourceKind = "ItemBox"
	if FLT.SetMoneyMode then
		FLT.SetMoneyMode("Loot", label, 5)
	end
	FLT.Debug("Loot source ItemBox: " .. label)
	return label, "ItemBox"
end

-- Returns source label and kind ("ItemBox" | "Gathering" | "Creature" | "Fishing" | "Loot").
function FLT.DetectLootContainerSource()
	if IsFishingLoot and IsFishingLoot() then
		FLT.lastSource = "Fishing"
		FLT.lastSourceKind = "Fishing"
		if FLT.SetMoneyMode then
			FLT.SetMoneyMode("Loot", "Fishing", 5)
		end
		return "Fishing", "Fishing"
	end

	local objectName, creatureName, sawGameObject
	if GetLootSourceInfo and GetNumLootItems then
		local n = GetNumLootItems() or 0
		local targetGuid = Readable(UnitGUID and UnitGUID("target"))
		local targetName = Readable(UnitName("target"))
		for i = 1, n do
			local ok, guid = pcall(GetLootSourceInfo, i)
			guid = ok and Readable(guid) or nil
			if guid then
				local kind = GuidKind(guid)
				if kind == "GameObject" then
					sawGameObject = true
					-- Only trust target name when it is the same GUID as the loot source.
					if targetGuid and targetGuid == guid then
						objectName = targetName or objectName
					end
				elseif kind == "Creature" or kind == "Vehicle" then
					if targetGuid and targetGuid == guid then
						creatureName = targetName or creatureName
					elseif not creatureName and targetName and UnitIsDead and UnitIsDead("target") then
						-- Soft fallback when GUID compare fails on Forever secret GUIDs.
						creatureName = targetName
					end
				end
			end
		end
	end

	local sticky = GatherStickyActive()
	if sawGameObject or objectName then
		if sticky or IsGatheringNodeName(objectName) then
			return MarkGathering(objectName)
		end
		-- Unnamed GameObject without gather context → chest/container.
		return MarkItemBox(objectName or "Chest")
	end

	if creatureName then
		FLT.lastSource = creatureName
		FLT.lastSourceKind = "Creature"
		if FLT.SetMoneyMode then
			FLT.SetMoneyMode("Loot", creatureName, 5)
		end
		return creatureName, "Creature"
	end

	-- Fallback: dead target ≈ corpse loot; live/interactable object name if present.
	local target = Readable(UnitName("target"))
	if target then
		if UnitIsDead and UnitIsDead("target") then
			FLT.lastSource = target
			FLT.lastSourceKind = "Creature"
			if FLT.SetMoneyMode then
				FLT.SetMoneyMode("Loot", target, 5)
			end
			return target, "Creature"
		end
		local guid = Readable(UnitGUID and UnitGUID("target"))
		if GuidKind(guid) == "GameObject" then
			if sticky or IsGatheringNodeName(target) then
				return MarkGathering(target)
			end
			return MarkItemBox(target)
		end
	end

	-- Gather cast succeeded but GUID/name unavailable (common on Forever).
	if sticky then
		return MarkGathering(nil)
	end

	FLT.lastSourceKind = "Loot"
	if FLT.SetMoneyMode then
		FLT.SetMoneyMode("Loot", nil, 5)
	end
	return FLT.lastSource or "Loot", "Loot"
end

function FLT.OnLootOpenedForSource()
	FLT.DetectLootContainerSource()
	-- Instance-safe capture: snapshot slots + arm bag watch (chat may be Secret).
	if FLT.OnLootWindowOpened then
		FLT.OnLootWindowOpened()
	end
end

function FLT.OnGatherSpellCast(unitTarget, castGUID, spellID)
	-- RegisterUnitEvent("…", "player") still passes unit as arg1; tolerate reshuffled args.
	-- Core also passes the event name via FLT._lastSpellCastEvent when available.
	local eventName = FLT._lastSpellCastEvent
	local unit = Readable(unitTarget)
	local spell = spellID
	if type(unitTarget) == "number" and not spellID then
		spell = unitTarget
		unit = "player"
	elseif type(castGUID) == "number" and (spellID == nil or type(spellID) ~= "number") then
		spell = castGUID
	end
	if unit and unit ~= "player" then
		return
	end
	spell = tonumber(spell) or spell
	if FLT.NoteDisenchantCast(spell, nil, eventName) then
		return
	end
	FLT.NoteGatherCast(spell, nil, eventName)
end
