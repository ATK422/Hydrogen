--!strict

-- What MessagingService messages and teleport data are sent as: JSON. Checks a value can be
-- JSON at all, and measures it. In a game the size is HttpService:JSONEncode's, exactly;
-- elsewhere (Lune) it's a close estimate.

local Json = {}

local HttpService: HttpService? = nil

-- Why the value can't be sent as JSON, or nil if it can.
local function problem(value: any, path: string, seen: { [any]: boolean }): string?
	local kind = type(value)
	if kind == "string" or kind == "boolean" or value == nil then
		return nil
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			return `{path} is {value}, which JSON can't hold`
		end
		return nil
	elseif kind ~= "table" then
		return `{path} is a {typeof(value)}, which JSON can't hold; send plain numbers, strings, booleans and tables`
	end

	if seen[value] then
		return `{path} contains itself`
	end
	seen[value] = true

	local count = 0
	local strings = 0
	for key in value do
		count += 1
		if type(key) == "string" then
			strings += 1
		elseif type(key) ~= "number" then
			return `{path} has a {typeof(key)} key; JSON keys are strings`
		end
	end
	if strings > 0 and strings < count then
		return `{path} mixes array items and string keys`
	elseif strings == 0 and count > 0 and #value ~= count then
		return `{path} is an array with holes or non-integer keys`
	end

	for key, inner in value do
		local found = problem(inner, if type(key) == "number" then `{path}[{key}]` else `{path}.{key}`, seen)
		if found then
			return found
		end
	end
	seen[value] = nil
	return nil
end

local function stringSize(text: string): number
	local size = #text + 2
	for index = 1, #text do
		local byte = string.byte(text, index)
		if byte == 34 or byte == 92 or byte == 8 or byte == 9 or byte == 10 or byte == 12 or byte == 13 then
			size += 1
		elseif byte < 32 then
			size += 5
		end
	end
	return size
end

local function estimate(value: any): number
	local kind = type(value)
	if kind == "string" then
		return stringSize(value)
	elseif kind == "number" then
		return #(if value == math.floor(value) and math.abs(value) < 2 ^ 53 then string.format("%d", value) else tostring(value))
	elseif kind == "boolean" then
		return if value then 4 else 5
	elseif kind ~= "table" then
		return 4 -- null
	end

	local size = 2
	local first = true
	if next(value) ~= nil and #value == 0 then
		for key, inner in value do
			size += (if first then 0 else 1) + stringSize(tostring(key)) + 1 + estimate(inner)
			first = false
		end
	else
		for _, inner in ipairs(value) do
			size += (if first then 0 else 1) + estimate(inner)
			first = false
		end
	end
	return size
end

-- Returns the encoded size in bytes, or nil and the reason the value can't be sent.
function Json.size(value: any): (number?, string?)
	local found = problem(value, "the value", {})
	if found then
		return nil, found
	end
	local ok, encoded = pcall(function()
		HttpService = HttpService or game:GetService("HttpService")
		return (HttpService :: HttpService):JSONEncode(value)
	end)
	if ok and type(encoded) == "string" then
		return #encoded, nil
	end
	return estimate(value), nil
end

-- Only the check, for data that has no size limit of its own.
function Json.check(value: any): string?
	return problem(value, "the value", {})
end

return Json
