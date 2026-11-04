--!strict

-- Argument types for commands: the built-in ones, GreenTea schemas turned into arguments, and the
-- tokenizer that splits a typed line into words.

local gt = require("../../roblox_packages/gt")
local Types = require("./Types")

type Arg = Types.Arg
type ParseContext = Types.ParseContext

export type Token = {
	text: string,
	-- Byte where the word starts in the line, including an opening quote.
	start: number,
}

local Args = {}

local function trim(text: string): string
	return (string.match(text, "^%s*(.-)%s*$") :: string)
end

-- Words separated by whitespace. "Double" or 'single' quotes group words; an unclosed quote runs
-- to the end of the line.
function Args.tokenize(line: string): { Token }
	local tokens: { Token } = {}
	local index = 1
	local length = #line
	while index <= length do
		local first, last = string.find(line, "^%s+", index)
		if first then
			index = (last :: number) + 1
			continue
		end
		local char = string.sub(line, index, index)
		if char == '"' or char == "'" then
			local close = string.find(line, char, index + 1, true)
			local finish = if close then close - 1 else length
			table.insert(tokens, { text = string.sub(line, index + 1, finish), start = index })
			index = if close then close + 1 else length + 1
		else
			local _, wordEnd = string.find(line, "^[^%s]+", index)
			local finish = wordEnd :: number
			table.insert(tokens, { text = string.sub(line, index, finish), start = index })
			index = finish + 1
		end
	end
	return tokens
end

-- The rest of the line from a token, as typed. Quotes around all of it are removed.
function Args.remainder(line: string, token: Token): string
	local text = trim(string.sub(line, token.start))
	local quote = string.sub(text, 1, 1)
	if #text >= 2 and (quote == '"' or quote == "'") and string.sub(text, -1) == quote then
		return string.sub(text, 2, -2)
	end
	return text
end

local function quoted(text: string): string
	return string.format("%q", text)
end

local function new(name: string, kind: string, parse: (string, ParseContext) -> (boolean, any)): Arg
	return {
		name = name,
		type = kind,
		optional = false,
		default = nil,
		rest = nil,
		choices = nil,
		parse = parse,
	}
end

function Args.isArg(value: any): boolean
	return type(value) == "table"
		and not gt.isGreenTeaType(value)
		and type(value.parse) == "function"
		and type(value.name) == "string"
end

local function rangeText(min: number?, max: number?): string
	if min and max then
		return ` from {min} to {max}`
	elseif min then
		return ` of at least {min}`
	elseif max then
		return ` of at most {max}`
	end
	return ""
end

local function parseNumber(text: string, integer: boolean?, min: number?, max: number?): (boolean, any)
	local value = tonumber(text)
	local noun = if integer then "a whole number" else "a number"
	if value == nil or value ~= value or value == math.huge or value == -math.huge then
		return false, `expected {noun}{rangeText(min, max)}, got {quoted(text)}`
	end
	local number = value :: number
	if integer and number % 1 ~= 0 then
		return false, `expected {noun}{rangeText(min, max)}, got {text}`
	end
	if (min and number < min) or (max and number > max) then
		return false, `expected {noun}{rangeText(min, max)}, got {text}`
	end
	return true, number
end

local BOOLEANS: { [string]: boolean } = {
	["true"] = true,
	yes = true,
	on = true,
	["1"] = true,
	["false"] = false,
	no = false,
	off = false,
	["0"] = false,
}

local function parseBoolean(text: string): (boolean, any)
	local value = BOOLEANS[string.lower(text)]
	if value == nil then
		return false, `expected true or false, got {quoted(text)}`
	end
	return true, value
end

-- Finds a choice by name: exact (any case) first, then a unique prefix.
function Args.matchChoice(text: string, choices: { string }): (boolean, any)
	local lowered = string.lower(text)
	local matches: { string } = {}
	for _, choice in choices do
		local candidate = string.lower(choice)
		if candidate == lowered then
			return true, choice
		end
		if string.sub(candidate, 1, #lowered) == lowered then
			table.insert(matches, choice)
		end
	end
	if #matches == 1 then
		return true, matches[1]
	end
	if #matches > 1 and lowered ~= "" then
		return false, `{quoted(text)} could be {table.concat(matches, ", ")}`
	end
	local shown = if #choices > 8
		then `{table.concat(choices, ", ", 1, 8)}, ...`
		else table.concat(choices, ", ")
	return false, `expected one of {shown}, got {quoted(text)}`
end

-- Players by a word: me, all (or *), others, or a name or display name, whole or the start of it.
-- A comma joins several.
function Args.findPlayers(text: string, context: ParseContext): (boolean, any)
	local found: { Player } = {}
	local seen: { [Player]: boolean } = {}
	local function add(player: Player)
		if not seen[player] then
			seen[player] = true
			table.insert(found, player)
		end
	end

	for part in string.gmatch(text, "[^,]+") do
		local query = string.lower(trim(part))
		if query == "me" then
			add(context.player)
		elseif query == "all" or query == "*" or query == "everyone" then
			for _, player in context.players do
				add(player)
			end
		elseif query == "others" then
			for _, player in context.players do
				if player ~= context.player then
					add(player)
				end
			end
		else
			local exact: Player? = nil
			local display: { Player } = {}
			local prefixed: { Player } = {}
			for _, player in context.players do
				local name = string.lower(player.Name)
				local displayName = string.lower(player.DisplayName or player.Name)
				if name == query then
					exact = player
					break
				elseif displayName == query then
					table.insert(display, player)
				elseif string.sub(name, 1, #query) == query or string.sub(displayName, 1, #query) == query then
					table.insert(prefixed, player)
				end
			end
			local matches: { Player } = if exact then { exact } elseif #display > 0 then display else prefixed
			if #matches == 0 then
				return false, `no player matches {quoted(trim(part))}`
			elseif #matches > 1 then
				local names = {}
				for _, player in matches do
					table.insert(names, player.Name)
				end
				return false, `{quoted(trim(part))} matches {table.concat(names, ", ")}; type more of the name`
			end
			add(matches[1])
		end
	end

	if #found == 0 then
		return false, `no player matches {quoted(text)}`
	end
	return true, found
end

-- Builders. Each returns a new Arg; options.name sets the name shown in usage and errors.

type Named = { name: string? }?

function Args.player(options: Named): Arg
	return new(options and options.name or "player", "player", function(text, context)
		local ok, found = Args.findPlayers(text, context)
		if not ok then
			return false, found
		end
		if #found > 1 then
			return false, `expected one player, but {quoted(text)} matches {#found}`
		end
		return true, found[1]
	end)
end

function Args.players(options: Named): Arg
	return new(options and options.name or "players", "players", Args.findPlayers)
end

function Args.number(options: { name: string?, min: number?, max: number?, integer: boolean? }?): Arg
	local integer = options and options.integer
	local min = options and options.min
	local max = options and options.max
	return new(options and options.name or "number", if integer then "integer" else "number", function(text)
		return parseNumber(text, integer, min, max)
	end)
end

function Args.integer(options: { name: string?, min: number?, max: number? }?): Arg
	return Args.number({
		name = options and options.name or "integer",
		min = options and options.min,
		max = options and options.max,
		integer = true,
	})
end

function Args.string(options: { name: string?, maxLength: number? }?): Arg
	local maxLength = options and options.maxLength
	return new(options and options.name or "string", "string", function(text)
		if maxLength and #text > maxLength then
			return false, `expected at most {maxLength} characters, got {#text}`
		end
		return true, text
	end)
end

function Args.boolean(options: Named): Arg
	local arg = new(options and options.name or "boolean", "boolean", parseBoolean)
	arg.choices = { "true", "false" }
	return arg
end

-- One of a fixed set of words, or of a Roblox Enum's items (run receives the EnumItem).
function Args.enum(choices: { string } | Enum, options: Named): Arg
	if typeof(choices) == "Enum" then
		local enum = choices :: Enum
		local items: { [string]: EnumItem } = {}
		local names: { string } = {}
		for _, item in enum:GetEnumItems() do
			items[item.Name] = item
			table.insert(names, item.Name)
		end
		local arg = new(options and options.name or tostring(enum), "enum", function(text)
			local ok, name = Args.matchChoice(text, names)
			if not ok then
				return false, name
			end
			return true, items[name]
		end)
		arg.choices = names
		return arg
	end

	if type(choices) ~= "table" or #(choices :: { string }) == 0 then
		error(`[HYDROGEN] Commands.enum expects a non-empty list of words or a Roblox Enum`, 2)
	end
	local list = table.clone(choices :: { string })
	local arg = new(options and options.name or "choice", "enum", function(text)
		return Args.matchChoice(text, list)
	end)
	arg.choices = list
	return arg
end

-- The rest of the line, spaces and all, as one string. Must be the last argument.
function Args.text(options: Named): Arg
	local arg = new(options and options.name or "text", "text", function(text)
		return true, text
	end)
	arg.rest = "text"
	return arg
end

function Args.arg(options: Types.ArgOptions): Arg
	if type(options) ~= "table" or type(options.name) ~= "string" or type(options.parse) ~= "function" then
		error("[HYDROGEN] Commands.arg expects { name = string, parse = function(text, context) }", 2)
	end
	local arg = new(options.name, options.type or options.name, options.parse)
	arg.choices = options.choices and table.clone(options.choices)
	return arg
end

-- GreenTea schemas as arguments: the word is converted by the schema's kind, then checked by the
-- schema itself, so ranges, integer checks and patterns all apply.

local function firstLine(cause: any): string
	local text = tostring(cause)
	return (string.match(text, "^[^\n]*") :: string)
end

local function literalChoices(schema: any): { string }?
	if schema.kind == "literal" then
		return { tostring(schema.literal.value) }
	end
	if schema.kind ~= "union" then
		return nil
	end
	local choices = {}
	for _, member in schema.union.contents do
		if member.kind ~= "literal" then
			return nil
		end
		table.insert(choices, tostring(member.literal.value))
	end
	return choices
end

local function withoutNil(schema: any): (any, boolean)
	if schema.kind ~= "union" or not schema.union.optional then
		return schema, false
	end
	local rest = {}
	for _, member in schema.union.contents do
		local basic = member.basic
		if not (basic and (basic.type == "nil" or basic.typeof == "nil")) then
			table.insert(rest, member)
		end
	end
	if #rest == 1 then
		return rest[1], true
	end
	return gt.union(table.unpack(rest)), true
end

function Args.fromSchema(schema: any, index: number): Arg
	local inner, optional = withoutNil(schema)
	local check = function(value: any): (boolean, any)
		local ok, cause = schema:matches(value)
		if ok then
			return true, value
		end
		return false, firstLine(cause)
	end

	local arg: Arg
	local choices = literalChoices(inner)
	if choices then
		local values: { [string]: any } = {}
		for _, member in (if inner.kind == "union" then inner.union.contents else { inner }) :: { any } do
			values[tostring(member.literal.value)] = member.literal.value
		end
		arg = new(`arg{index}`, "enum", function(text)
			local ok, name = Args.matchChoice(text, choices)
			if not ok then
				return false, name
			end
			return true, values[name]
		end)
		arg.choices = choices
	elseif inner.kind == "number" then
		local range = inner.number.range
		local integer = inner.number.integer
		local min = range and range.min
		local max = range and range.max
		arg = new(if integer then "integer" else "number", if integer then "integer" else "number", function(text)
			local ok, value = parseNumber(text, integer, min, max)
			if not ok then
				return false, value
			end
			local valid, cause = check(value)
			if not valid then
				return false, `expected {inner:format()}, got {text}: {cause}`
			end
			return true, value
		end)
	elseif inner.kind == "string" then
		arg = new("string", "string", function(text)
			local valid, cause = check(text)
			if not valid then
				return false, `expected {inner:format()}: {cause}`
			end
			return true, text
		end)
	elseif inner.kind == "basic" and (inner.basic.typeof == "boolean" or inner.basic.type == "boolean") then
		arg = new("boolean", "boolean", parseBoolean)
		arg.choices = { "true", "false" }
	else
		-- Anything else: the first reading of the word the schema accepts.
		arg = new(`arg{index}`, "value", function(text)
			local candidates: { any } = {}
			local number = tonumber(text)
			if number ~= nil then
				table.insert(candidates, number)
			end
			local boolean = BOOLEANS[string.lower(text)]
			if boolean ~= nil and (text == "true" or text == "false") then
				table.insert(candidates, boolean)
			end
			table.insert(candidates, text)
			local lastCause = ""
			for _, candidate in candidates do
				local ok, value = check(candidate)
				if ok then
					return true, value
				end
				lastCause = value
			end
			return false, `expected {inner:format()}: {lastCause}`
		end)
	end
	arg.optional = optional
	return arg
end

-- Turns an entry of a spec's args (an Arg or a GreenTea schema) into an Arg.
function Args.from(value: any, index: number): Arg?
	if Args.isArg(value) then
		return value
	end
	if gt.isGreenTeaType(value) then
		return Args.fromSchema(value, index)
	end
	return nil
end

local function argOf(value: any, caller: string): Arg
	local arg = Args.from(value, 1)
	if not arg then
		error(`[HYDROGEN] {caller} expects an argument (Commands.player(), Commands.number(), ...) or a GreenTea schema`, 3)
	end
	return arg
end

function Args.optional(value: any, default: any?): Arg
	local arg = table.clone(argOf(value, "Commands.optional"))
	arg.optional = true
	arg.default = default
	return arg
end

-- Every remaining word, each parsed by value; run receives them as a list. Must be the last argument.
function Args.rest(value: any): Arg
	local arg = table.clone(argOf(value, "Commands.rest"))
	arg.rest = "list"
	return arg
end

function Args.named(name: string, value: any): Arg
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] Commands.named expects a name and an argument`, 2)
	end
	local arg = table.clone(argOf(value, "Commands.named"))
	arg.name = name
	return arg
end

return Args
