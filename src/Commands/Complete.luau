--!strict

-- Autocomplete for a partly typed line, from the command list the server sent. Pure, so the
-- console, a game's own UI and tests all get the same answers.

local Args = require("./Args")
local Types = require("./Types")

type CommandInfo = Types.CommandInfo
type ArgInfo = Types.ArgInfo
type Completion = Types.Completion
type Suggestion = Types.Suggestion

local MAX_SUGGESTIONS = 8

local Complete = {}

local function startsWith(text: string, prefix: string): boolean
	return string.sub(string.lower(text), 1, #prefix) == prefix
end

local function findCommand(catalog: { CommandInfo }, word: string): CommandInfo?
	for _, info in catalog do
		if info.name == word or table.find(info.aliases, word) then
			return info
		end
	end
	return nil
end

local function wordFor(value: string): string
	if string.find(value, "%s") then
		return `"{value}"`
	end
	return value
end

-- The words an argument could take, before filtering by what's typed.
local function candidates(arg: ArgInfo, catalog: { CommandInfo }, playerNames: { string }): { string }
	if arg.type == "player" or arg.type == "players" then
		local list = { "me" }
		if arg.type == "players" then
			table.insert(list, "all")
			table.insert(list, "others")
		end
		for _, name in playerNames do
			table.insert(list, name)
		end
		return list
	end
	if arg.choices then
		return arg.choices
	end
	if arg.type == "command" then
		local list = {}
		for _, info in catalog do
			table.insert(list, info.name)
		end
		return list
	end
	return {}
end

-- line: what's typed so far. catalog: Commands.Client.commands(). playerNames: names to offer for
-- player arguments (the console passes everyone in the game).
function Complete.complete(line: string, catalog: { CommandInfo }, playerNames: { string }): Completion
	local result: Completion = { suggestions = {}, usage = nil, arg = nil }
	local _, prefixEnd = string.find(line, "^%s*/?")
	local prefix = string.sub(line, 1, prefixEnd :: number)
	local body = string.sub(line, (prefixEnd :: number) + 1)
	local tokens = Args.tokenize(body)
	local trailing = #body > 0 and string.match(body, "%s$") ~= nil

	if #tokens == 0 or (#tokens == 1 and not trailing) then
		local typed = if #tokens == 1 then string.lower(tokens[1].text) else ""
		local seen: { [string]: boolean } = {}
		for pass = 1, 2 do
			for _, info in catalog do
				if seen[info.name] then
					continue
				end
				local word: string? = nil
				if pass == 1 and startsWith(info.name, typed) then
					word = info.name
				elseif pass == 2 then
					for _, alias in info.aliases do
						if startsWith(alias, typed) then
							word = alias
							break
						end
					end
				end
				if word and #result.suggestions < MAX_SUGGESTIONS then
					seen[info.name] = true
					table.insert(result.suggestions, {
						text = `{prefix}{word} `,
						label = if word == info.name then info.name else `{word} ({info.name})`,
						detail = if info.description ~= "" then info.description else nil,
					})
				end
			end
		end
		local exact = if #tokens == 1 then findCommand(catalog, typed) else nil
		if exact then
			result.usage = exact.usage
		end
		return result
	end

	local info = findCommand(catalog, string.lower(tokens[1].text))
	if not info then
		return result
	end
	result.usage = info.usage

	-- Which argument the cursor is in, and what of it is typed.
	local argIndex = #tokens - 1 + (if trailing then 1 else 0)
	local arg = info.args[argIndex]
	local last = info.args[#info.args]
	if not arg and last and last.rest then
		arg = last
	end
	if not arg then
		return result
	end
	result.arg = arg
	if arg.type == "text" then
		return result
	end

	local partial = if trailing then "" else tokens[#tokens].text
	local before = if trailing then body else string.sub(body, 1, tokens[#tokens].start - 1)
	-- A players list: complete the name after the last comma.
	local keep = ""
	if arg.type == "players" then
		local head, tail = string.match(partial, "^(.*,)(.*)$")
		if head then
			keep, partial = head, tail :: string
		end
	end
	local typed = string.lower(partial)

	for _, value in candidates(arg, catalog, playerNames) do
		if #result.suggestions >= MAX_SUGGESTIONS then
			break
		end
		if startsWith(value, typed) then
			table.insert(result.suggestions, {
				text = `{prefix}{before}{wordFor(keep .. value)} `,
				label = value,
				detail = arg.type,
			})
		end
	end
	return result
end

return Complete
