--!strict

-- Values as one line of text for the overlay. The server sends text rather than the values, so
-- anything (cycles, Instances, mixed tables) crosses the network safely and stays small.

local MAX_DEPTH = 3
local MAX_ENTRIES = 12
local MAX_STRING = 120

local Format = {}

local function sortKey(key: any): string
	return if type(key) == "number" then string.format("%020.6f", key) else tostring(key)
end

local function value(item: any, depth: number): string
	local kind = typeof(item)
	if kind == "string" then
		if #item > MAX_STRING then
			return string.format("%q", string.sub(item, 1, MAX_STRING)) .. `... ({#item} chars)`
		end
		return string.format("%q", item)
	elseif kind == "number" then
		return if item % 1 == 0 and math.abs(item) < 1e15 then string.format("%d", item) else string.format("%.4g", item)
	elseif kind == "Instance" then
		return `{item.ClassName}({item.Name})`
	elseif kind ~= "table" then
		return tostring(item)
	end

	if depth >= MAX_DEPTH then
		return "{...}"
	end

	-- Arrays in order, then the other keys sorted, so a value reads the same on every refresh.
	local parts = {}
	local length = #item
	local keys = {}
	for key in item do
		if not (type(key) == "number" and key >= 1 and key <= length and key % 1 == 0) then
			table.insert(keys, key)
		end
	end
	table.sort(keys, function(a, b)
		return sortKey(a) < sortKey(b)
	end)

	local shown = 0
	local total = length + #keys
	for index = 1, length do
		if shown >= MAX_ENTRIES then
			break
		end
		shown += 1
		table.insert(parts, value(item[index], depth + 1))
	end
	for _, key in keys do
		if shown >= MAX_ENTRIES then
			break
		end
		shown += 1
		local label = if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") then key else `[{value(key, depth + 1)}]`
		table.insert(parts, `{label} = {value(item[key], depth + 1)}`)
	end
	if total > shown then
		table.insert(parts, `... ({total - shown} more)`)
	end

	return `\{{table.concat(parts, ", ")}}`
end

function Format.value(item: any): string
	return value(item, 0)
end

-- One row per top-level field, sorted by field name. Reads through __iter, so a PlayerState
-- works as well as a plain table.
function Format.fields(data: any): { { name: string, value: string } }
	local rows = {}
	if type(data) ~= "table" then
		table.insert(rows, { name = "value", value = value(data, 0) })
		return rows
	end
	for key, entry in data do
		table.insert(rows, { name = tostring(key), value = value(entry, 1) })
	end
	table.sort(rows, function(a, b)
		return a.name < b.name
	end)
	return rows
end

return Format
