-- ForeverLootTracker — multi-session save / restore / switch (per character).
local FLT = ForeverLootTracker

local function NextSessionId()
	local maxId = 0
	for id in pairs(FLT.EnsureSessionsTable()) do
		local n = tonumber(id) or 0
		if n > maxId then
			maxId = n
		end
	end
	return maxId + 1
end

function FLT.EnsureSessionsTable()
	local char = FLT.GetCharDB()
	char.sessions = char.sessions or {}
	return char.sessions
end

function FLT.SnapshotSession(session)
	session = session or FLT.GetSession()
	return {
		label = session.label,
		created = session.created,
		savedAt = time(),
		items = FLT.DeepCopy(session.items or {}),
		money = FLT.DeepCopy(session.money or {}),
		currencies = FLT.DeepCopy(session.currencies or {}),
		itemCache = FLT.DeepCopy(session.itemCache or {}),
		stats = FLT.DeepCopy(session.stats or { junkValue = 0, copper = FLT.DefaultMoneyStats(), currencies = {} }),
		firstLoot = session.firstLoot,
		lastLoot = session.lastLoot,
	}
end

function FLT.ApplySessionSnapshot(snap, labelOverride)
	local session = FLT.NewSession(labelOverride or (snap and snap.label) or "Session")
	if snap then
		session.label = labelOverride or snap.label or session.label
		session.created = snap.created or session.created
		session.items = FLT.DeepCopy(snap.items or {})
		session.money = FLT.DeepCopy(snap.money or {})
		session.currencies = FLT.DeepCopy(snap.currencies or {})
		session.itemCache = FLT.DeepCopy(snap.itemCache or {})
		session.stats = FLT.DeepCopy(snap.stats or session.stats)
		session.firstLoot = snap.firstLoot
		session.lastLoot = snap.lastLoot
	end
	FLT.SetSession(session)
	FLT.RebuildStats()
	if FLT.RefreshObjectiveTracker then
		FLT.RefreshObjectiveTracker()
	end
	return session
end

function FLT.SaveCurrentSession(label)
	local sessions = FLT.EnsureSessionsTable()
	local snap = FLT.SnapshotSession()
	if label and label ~= "" then
		snap.label = label
		FLT.GetSession().label = label
	end
	local id = NextSessionId()
	sessions[id] = snap
	FLT.SetActiveSessionId(id)
	FLT.Print(("Saved session #%d (%s)."):format(id, snap.label or "?"))
	return id
end

function FLT.ListSavedSessions()
	local out = {}
	for id, snap in pairs(FLT.EnsureSessionsTable()) do
		table.insert(out, {
			id = tonumber(id) or id,
			label = snap.label or ("Session " .. tostring(id)),
			created = snap.created,
			savedAt = snap.savedAt,
			itemCount = #(snap.items or {}),
			moneyCount = #(snap.money or {}),
		})
	end
	table.sort(out, function(a, b)
		return (a.savedAt or a.created or 0) > (b.savedAt or b.created or 0)
	end)
	return out
end

function FLT.LoadSavedSession(id, archiveCurrent)
	local sessions = FLT.EnsureSessionsTable()
	local snap = sessions[id] or sessions[tostring(id)]
	if not snap then
		FLT.Print("Session not found: " .. tostring(id))
		return false
	end
	if archiveCurrent then
		FLT.SaveCurrentSession()
	end
	FLT.ApplySessionSnapshot(snap)
	FLT.SetActiveSessionId(tonumber(id) or id)
	FLT.Print(("Loaded session #%s (%s)."):format(tostring(id), snap.label or "?"))
	if FLT.UI and FLT.UI.Refresh then
		FLT.UI.Refresh()
	end
	return true
end

function FLT.DeleteSavedSession(id)
	local sessions = FLT.EnsureSessionsTable()
	local key = sessions[id] and id or tostring(id)
	if not sessions[key] then
		FLT.Print("Session not found: " .. tostring(id))
		return false
	end
	sessions[key] = nil
	local active = FLT.GetActiveSessionId()
	if active == id or tostring(active) == tostring(id) then
		FLT.SetActiveSessionId(nil)
	end
	FLT.Print("Deleted saved session #" .. tostring(id))
	return true
end

function FLT.StartNewSession(label, archiveCurrent)
	if archiveCurrent then
		FLT.SaveCurrentSession()
	end
	local session = FLT.NewSession(label or ("Session " .. date("%H:%M:%S")))
	FLT.SetSession(session)
	FLT.SetActiveSessionId(nil)
	if FLT.RefreshObjectiveTracker then
		FLT.RefreshObjectiveTracker()
	end
	if FLT.UI and FLT.UI.Refresh then
		FLT.UI.Refresh()
	end
	FLT.Print("Started new session: " .. session.label)
end

function FLT.IsRecording()
	if not FLT.db or not FLT.db.options then
		return true
	end
	return FLT.db.options.recording ~= false
end

function FLT.SetRecording(enabled)
	FLT.db.options.recording = not not enabled
	local state = FLT.db.options.recording and "Recording" or "Paused"
	FLT.Print(state .. " loot capture.")
	if FLT.UI and FLT.UI.RefreshRecordingButton then
		FLT.UI.RefreshRecordingButton()
	end
end

function FLT.ToggleRecording()
	FLT.SetRecording(not FLT.IsRecording())
end
