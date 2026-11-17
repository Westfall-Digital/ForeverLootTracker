-- ForeverLootTracker — export formats (CSV / JSON / BBCode / HTML).
local FLT = ForeverLootTracker

local function EscapeCSV(value)
	value = tostring(value or "")
	if value:find('[,"\n]') then
		return '"' .. value:gsub('"', '""') .. '"'
	end
	return value
end

local function EscapeHTML(value)
	value = tostring(value or "")
	value = value:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
	return value
end

local function EscapeJSON(value)
	value = tostring(value or "")
	value = value:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
	return value
end

local function WowheadLink(itemID)
	return "https://www.wowhead.com/item=" .. tostring(itemID)
end

function FLT.BuildExportRows()
	local session = FLT.GetSession()
	local rows = {}
	for _, item in ipairs(session.items) do
		local cached = session.itemCache[item.itemID] or FLT.CacheItem(item.itemID, item.link)
		table.insert(rows, {
			time = FLT.FormatTime(item.time),
			itemID = item.itemID,
			name = (cached and cached.name) or ("Item " .. tostring(item.itemID)),
			link = item.link or "",
			count = item.count or 1,
			looter = item.looter or "",
			source = item.source or "",
			sourceType = FLT.SOURCE_NAMES[item.sourceType] or "",
			rollType = item.rollType or "",
			cost = item.cost or 0,
			quality = (cached and cached.quality) or 1,
			iLvl = (cached and cached.iLvl) or 0,
			type = (cached and cached.type) or "",
			zone = item.zone or "",
			wowhead = WowheadLink(item.itemID),
		})
	end
	return rows
end

function FLT.DoCSVExport()
	local rows = FLT.BuildExportRows()
	local out = {
		"TIMESTAMP,ID,NAME,COUNT,LOOTER,SOURCE,SOURCE_TYPE,ROLL,COST,QUALITY,ILVL,TYPE,ZONE,WOWHEAD",
	}
	for _, r in ipairs(rows) do
		table.insert(out, table.concat({
			EscapeCSV(r.time),
			EscapeCSV(r.itemID),
			EscapeCSV(r.name),
			EscapeCSV(r.count),
			EscapeCSV(r.looter),
			EscapeCSV(r.source),
			EscapeCSV(r.sourceType),
			EscapeCSV(r.rollType),
			EscapeCSV(r.cost),
			EscapeCSV(r.quality),
			EscapeCSV(r.iLvl),
			EscapeCSV(r.type),
			EscapeCSV(r.zone),
			EscapeCSV(r.wowhead),
		}, ","))
	end
	return table.concat(out, "\n")
end

function FLT.DoJSONExport()
	local rows = FLT.BuildExportRows()
	local parts = { "[\n" }
	for i, r in ipairs(rows) do
		table.insert(parts, "  {")
		table.insert(parts, ('"time":"%s",'):format(EscapeJSON(r.time)))
		table.insert(parts, ('"itemID":%d,'):format(r.itemID))
		table.insert(parts, ('"name":"%s",'):format(EscapeJSON(r.name)))
		table.insert(parts, ('"count":%d,'):format(r.count))
		table.insert(parts, ('"looter":"%s",'):format(EscapeJSON(r.looter)))
		table.insert(parts, ('"source":"%s",'):format(EscapeJSON(r.source)))
		table.insert(parts, ('"sourceType":"%s",'):format(EscapeJSON(r.sourceType)))
		table.insert(parts, ('"rollType":"%s",'):format(EscapeJSON(r.rollType)))
		table.insert(parts, ('"cost":%s,'):format(tostring(r.cost)))
		table.insert(parts, ('"quality":%d,'):format(r.quality))
		table.insert(parts, ('"iLvl":%d,'):format(r.iLvl))
		table.insert(parts, ('"type":"%s",'):format(EscapeJSON(r.type)))
		table.insert(parts, ('"zone":"%s",'):format(EscapeJSON(r.zone)))
		table.insert(parts, ('"wowhead":"%s"'):format(EscapeJSON(r.wowhead)))
		table.insert(parts, "  }" .. (i < #rows and "," or "") .. "\n")
	end
	table.insert(parts, "]")
	return table.concat(parts)
end

function FLT.DoBBCodeExport()
	local rows = FLT.BuildExportRows()
	local out = {}
	for _, r in ipairs(rows) do
		table.insert(out, ("(%s) [b]%s[/b] - %s - [url=%s]%s[/url] x%d"):format(
			r.time, r.source, r.looter, r.wowhead, r.name, r.count
		))
	end
	return table.concat(out, "\n")
end

function FLT.DoHTMLExport()
	local rows = FLT.BuildExportRows()
	local out = {
		"<html><body><table border='1'>",
		"<tr><th>TIMESTAMP</th><th>ID</th><th>NAME</th><th>COUNT</th><th>LOOTER</th><th>SOURCE</th><th>COST</th><th>QUALITY</th><th>ILVL</th><th>TYPE</th><th>ZONE</th></tr>",
	}
	for _, r in ipairs(rows) do
		table.insert(out, ("<tr><td>%s</td><td>%s</td><td><a href='%s'>%s</a></td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>"):format(
			EscapeHTML(r.time),
			EscapeHTML(r.itemID),
			EscapeHTML(r.wowhead),
			EscapeHTML(r.name),
			EscapeHTML(r.count),
			EscapeHTML(r.looter),
			EscapeHTML(r.source),
			EscapeHTML(r.cost),
			EscapeHTML(r.quality),
			EscapeHTML(r.iLvl),
			EscapeHTML(r.type),
			EscapeHTML(r.zone)
		))
	end
	table.insert(out, "</table></body></html>")
	return table.concat(out, "\n")
end

function FLT.GenerateExportString(formatID)
	formatID = formatID or (FLT.db and FLT.db.options.exportFormat) or FLT.EXPORT.csv
	if formatID == FLT.EXPORT.json then
		return FLT.DoJSONExport()
	elseif formatID == FLT.EXPORT.bbcode then
		return FLT.DoBBCodeExport()
	elseif formatID == FLT.EXPORT.html then
		return FLT.DoHTMLExport()
	end
	return FLT.DoCSVExport()
end
