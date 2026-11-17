-- ForeverLootTracker — defaults / constants (WoW Forever port of FSLootTracker).
ForeverLootTracker = ForeverLootTracker or {}
local FLT = ForeverLootTracker

FLT.NAME = "ForeverLootTracker"
FLT.VERSION = "1.0.1"
FLT.DATA_VERSION = "1.4"

FLT.SOURCE = {
	Dropped = 0,
	Rolled = 1,
	Master = 2,
	Crafted = 3,
	Purchased = 4,
	Entered = -1,
}

FLT.SOURCE_NAMES = {
	[0] = "Dropped",
	[1] = "Rolled",
	[2] = "Master",
	[3] = "Crafted",
	[4] = "Purchased",
	[-1] = "Entered",
}

-- Emphasize interaction phrases. Friz has no true bold face; gold + outline-friendly
-- markup is the Forever UI stand-in for bold action words.
function FLT.ClickHint(label)
	return "|cffffd100" .. tostring(label) .. "|r"
end

-- Normalize common click spellings to bold/gold canonical labels.
function FLT.FormatClickHints(text)
	text = tostring(text or "")
	local C = FLT.ClickHint
	-- Longer phrases first so "Shift+Left Click" isn't partially eaten by "Left Click".
	local reps = {
		{ "Shift%+[Ll]eft%s*[Cc]lick", C("Shift+Left Click") },
		{ "Shift%+[Rr]ight%s*[Cc]lick", C("Shift+Right Click") },
		{ "Shift%-[Ll]eft", C("Shift+Left Click") },
		{ "Shift%-[Rr]ight", C("Shift+Right Click") },
		{ "Shift%-left", C("Shift+Left Click") },
		{ "Shift%-right", C("Shift+Right Click") },
		{ "[Ll]eft%-[Cc]lick", C("Left Click") },
		{ "[Rr]ight%-[Cc]lick", C("Right Click") },
		{ "[Ll]eft%s+[Cc]lick", C("Left Click") },
		{ "[Rr]ight%s+[Cc]lick", C("Right Click") },
	}
	for _, pair in ipairs(reps) do
		text = text:gsub(pair[1], pair[2])
	end
	return text
end

FLT.EXPORT = {
	json = 1,
	bbcode = 2,
	html = 3,
	csv = 5,
}

FLT.EXPORT_NAMES = {
	[1] = "JSON",
	[2] = "BBCode",
	[3] = "HTML",
	[5] = "CSV",
}

FLT.QUALITY_NAMES = {
	[0] = "Poor",
	[1] = "Common",
	[2] = "Uncommon",
	[3] = "Rare",
	[4] = "Epic",
	[5] = "Legendary",
	[6] = "Artifact",
	[7] = "Heirloom",
}

FLT.QUALITY_COLORS = {
	[0] = "|cff9d9d9d",
	[1] = "|cffffffff",
	[2] = "|cff1eff00",
	[3] = "|cff0070dd",
	[4] = "|cffa335ee",
	[5] = "|cffff8000",
	[6] = "|cffe6cc80",
	[7] = "|cffe6cc80",
}

function FLT.DeepCopy(src)
	if type(src) ~= "table" then
		return src
	end
	local out = {}
	for k, v in pairs(src) do
		out[k] = FLT.DeepCopy(v)
	end
	return out
end

function FLT.DefaultMoneyStats()
	return {
		total = 0, -- net (earned - spent)
		earned = 0,
		spent = 0,
		perHour = 0,
		average = 0,
		largest = 0, -- largest single gain
		largestLoss = 0, -- largest single spend (positive magnitude)
		count = 0,
	}
end

function FLT.NewSession(label)
	return {
		label = label or date("%Y-%m-%d %H:%M"),
		created = time(),
		items = {},
		money = {},
		currencies = {}, -- non-gold currency events
		itemCache = {},
		stats = {
			junkValue = 0,
			copper = FLT.DefaultMoneyStats(),
			currencies = {}, -- [currencyID] = { total, earned, spent, ... }
		},
		firstLoot = nil,
		lastLoot = nil,
	}
end

function FLT.DefaultSettings()
	return {
		dataVersion = FLT.DATA_VERSION,
		version = FLT.VERSION,
		user = {
			debug = false,
			ignored = {}, -- legacy [itemID] = name; migrated into ignoreRules
			-- Flexible ignore rules: { id, kind, value, label }
			-- kind = "item" | "name" | "source" | "type"
			ignoreRules = {},
			ignoreRulesMigrated = false,
			watched = {}, -- legacy; migrated into chars[key].watched
			watchedMigrated = false,
			sessionMigrated = false,
		},
		-- Per-character data keyed by Forever full name ("First Surname").
		chars = {
			-- ["First Surname"] = {
			--   watched = { [itemID] = name },
			--   session = <active loot session>,
			--   sessions = { [id] = snapshot },
			--   activeSessionId = id|nil,
			-- }
		},
		options = {
			persistSession = true,
			defaultCost = 0,
			timeFormat = "24h",
			exportFormat = FLT.EXPORT.csv,
			qualityFilters = {
				[0] = true,
				[1] = true,
				[2] = true,
				[3] = true,
				[4] = true,
				[5] = true,
				[6] = true,
				[7] = true,
			},
			sourceFilters = {
				[0] = true,
				[1] = true,
				[2] = true,
				[3] = true, -- Crafted
				[4] = true, -- Purchased
			},
			trackMoney = true,
			trackCurrency = true,
			trackPartyLoot = true,
			showInObjectiveTracker = true,
			showMinimapButton = true,
			showCost = false, -- optional Items column; default hidden
			recording = true,
			-- Money chart window in minutes; -1 = entire session (WildStar graphLength).
			graphWindowMinutes = -1,
			-- Loot queue (WildStar pollingInterval / LootStackUpdate).
			queueInterval = 0.08,
			queueBatch = 2,
		},
		-- Legacy account-wide session fields (migrated into chars[key] on login).
		session = nil,
		sessions = nil,
		activeSessionId = nil,
		ui = {
			point = "CENTER",
			x = 0,
			y = 0,
			minimapAngle = 210,
			-- Item list sort: key + ascending
			sortKey = "time",
			sortAsc = false,
			-- Money / currency log sort
			moneySortKey = "time",
			moneySortAsc = false,
		},
	}
end
