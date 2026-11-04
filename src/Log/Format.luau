--!strict

-- How a line reads: [Tag] message key=value key=value. Fields follow logfmt: sorted keys,
-- plain words unquoted, anything with spaces or quotes quoted. Values inside tables follow
-- Hydrogen.logger's rules (strings quoted, Instances as ClassName(Name), depth and length
-- limits), so the two read alike. Only lines that are emitted get here.

local Types = require("./Types")

local MAX_DEPTH = 2
local MAX_ENTRIES = 8
local MAX_STRING = 200

local Format = {}

local function quote(value: string): string
	if #value > MAX_STRING then
		return string.format("%q", string.sub(value, 1, MAX_STRING)) .. `... ({#value} chars)`
	end
	return string.format("%q", value)
end

local function nested(value: any, depth: number): string
	local valueType = typeof(value)
	if valueType == "string" then
		return quote(value)
	elseif valueType == "Instance" then
		return `{value.ClassName}({value.Name})`
	elseif valueType ~= "table" then
		return tostring(value)
	end

	if depth >= MAX_DEPTH then
		return "{...}"
	end

	local parts = {}
	local count = 0
	for key, entry in value do
		count += 1
		if count > MAX_ENTRIES then
			table.insert(parts, "...")
			break
		end
		if type(key) == "number" and key == count then
			table.insert(parts, nested(entry, depth + 1))
		else
			local keyText = if type(key) == "string" then key else `[{nested(key, depth + 1)}]`
			table.insert(parts, `{keyText} = {nested(entry, depth + 1)}`)
		end
	end
	return `\{{table.concat(parts, ", ")}}`
end

-- One field value: sword, 50, true, "two words", Player(Alice), {1, 2}.
function Format.value(value: any): string
	local valueType = typeof(value)
	if valueType == "table" then
		return nested(value, 0)
	elseif valueType == "Instance" then
		return `{value.ClassName}({value.Name})`
	end

	local text = if valueType == "string" then value else tostring(value)
	if text == "" or #text > MAX_STRING or string.find(text, "[%s\"=]") then
		return quote(text)
	end
	return text
end

local function keyText(key: any): string
	if type(key) == "string" and string.match(key, "^[%a_][%w_]*$") then
		return key
	end
	return `[{nested(key, MAX_DEPTH)}]`
end

local function byText(a: { string }, b: { string }): boolean
	return a[1] < b[1]
end

-- " key=value key=value", sorted by key, or "" for no fields.
function Format.fields(fields: Types.Fields?): string
	if fields == nil or next(fields) == nil then
		return ""
	end
	local entries: { { string } } = {}
	for key, value in fields do
		table.insert(entries, { keyText(key), Format.value(value) })
	end
	table.sort(entries, byText)
	local parts: { string } = table.create(#entries)
	for index, pair in entries do
		parts[index] = ` {pair[1]}={pair[2]}`
	end
	return table.concat(parts)
end

-- The whole line. Debug and error lines say so, since the console shows them like info and
-- warn lines.
function Format.text(level: Types.Level, tag: string?, message: string, fields: Types.Fields?): string
	local marker = if level == "debug" then "debug: " elseif level == "error" then "error: " else ""
	local prefix = if tag then `[{tag}] ` else ""
	return `{prefix}{marker}{message}{Format.fields(fields)}`
end

return Format
