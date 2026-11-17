-- ForeverLootTracker — deferred loot/currency commit queue (WildStar LootStackUpdate).
-- Spreads CacheItem / list inserts across frames so large drops don't hitch.
local FLT = ForeverLootTracker

local queue = {}
local pumping = false

local function Interval()
	local sec = FLT.db and FLT.db.options and FLT.db.options.queueInterval
	sec = tonumber(sec) or 0.08
	if sec < 0.02 then
		sec = 0.02
	end
	return sec
end

local function BatchSize()
	return math.max(1, tonumber(FLT.db and FLT.db.options and FLT.db.options.queueBatch) or 2)
end

function FLT.QueueSize()
	return #queue
end

function FLT.IsQueueBusy()
	return #queue > 0 or pumping
end

-- Read-only peek for roll-dedupe upgrades of pending item commits.
function FLT.PeekQueueJobs()
	return queue
end

function FLT.UpdateQueueIndicator()
	if FLT.UI and FLT.UI.RefreshQueueIndicator then
		FLT.UI.RefreshQueueIndicator()
	end
end

function FLT.Enqueue(kind, payload)
	table.insert(queue, { kind = kind, payload = payload })
	FLT.UpdateQueueIndicator()
	if not pumping then
		pumping = true
		if C_Timer and C_Timer.After then
			C_Timer.After(Interval(), FLT.ProcessQueueTick)
		else
			FLT.ProcessQueueTick()
		end
	end
end

function FLT.ProcessQueueTick()
	local batch = BatchSize()
	local processed = 0
	while processed < batch do
		local job = table.remove(queue, 1)
		if not job then
			break
		end
		processed = processed + 1
		if job.kind == "item" and FLT.CommitItemRecord then
			FLT.CommitItemRecord(job.payload)
		elseif job.kind == "currency" and FLT.CommitCurrencyRecord then
			FLT.CommitCurrencyRecord(job.payload)
		end
	end

	FLT.UpdateQueueIndicator()

	if #queue > 0 then
		if C_Timer and C_Timer.After then
			C_Timer.After(Interval(), FLT.ProcessQueueTick)
		else
			FLT.ProcessQueueTick()
		end
	else
		pumping = false
		-- One UI refresh after the burst finishes.
		if FLT.UI and FLT.UI.RefreshIfShown then
			FLT.UI.RefreshIfShown()
		end
		if FLT.RefreshObjectiveTracker then
			FLT.RefreshObjectiveTracker()
		end
		if FLT.UpdateTitanPlugin then
			FLT.UpdateTitanPlugin()
		end
		FLT.UpdateQueueIndicator()
	end
end

function FLT.FlushQueue()
	while #queue > 0 do
		local job = table.remove(queue, 1)
		if job.kind == "item" and FLT.CommitItemRecord then
			FLT.CommitItemRecord(job.payload)
		elseif job.kind == "currency" and FLT.CommitCurrencyRecord then
			FLT.CommitCurrencyRecord(job.payload)
		end
	end
	pumping = false
	FLT.UpdateQueueIndicator()
	if FLT.UI and FLT.UI.RefreshIfShown then
		FLT.UI.RefreshIfShown()
	end
end
