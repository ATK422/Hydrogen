--!strict

-- The server half of Commands: the registry, permissions, the rate limit and the pipeline that
-- turns a typed line into a call to a command's run. Players reach it through the network; server
-- code and tests call execute directly.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Clock = require("../Clock")
local Log = require("../Log")
local Network = require("../Network")
local Args = require("./Args")
local Types = require("./Types")
local Wire = require("./Wire")

type Arg = Types.Arg
type CommandSpec = Types.CommandSpec
type CommandContext = Types.CommandContext
type CommandInfo = Types.CommandInfo
type CommandResult = Types.CommandResult
type OutputKind = Types.OutputKind
type Permission = Types.Permission
type CommandsOptions = Types.CommandsOptions
type ParseContext = Types.ParseContext

export type Command = {
	name: string,
	aliases: { string },
	description: string,
	args: { Arg },
	permission: Permission?,
	hidden: boolean,
	run: (CommandContext, ...any) -> ...any,
	usage: string,
	-- Built-ins give way to a game command with the same name or alias.
	builtin: boolean,
}

local DEFAULT_RATE = { perSecond = 3, burst = 6 }
local DEFAULT_MAX_LENGTH = 500

local Server = {}

-- Game commands by name and by alias, and the built-ins the same way.
local commands: { [string]: Command } = {}
local lookup: { [string]: Command } = {}
local builtins: { [string]: Command } = {}
local builtinLookup: { [string]: Command } = {}

local options: CommandsOptions = {}
local admins: { [number]: boolean } = {}

-- Runtime state, from the system's init to its stop.
local running = false
local players: { Player } = {}
local buckets: { [Player]: { tokens: number, at: number, warned: boolean } } = {}
local refreshTimer: thread? = nil

local function trim(text: string): string
	return (string.match(text, "^%s*(.-)%s*$") :: string)
end

local function quoted(text: string): string
	return string.format("%q", text)
end

local function argUsage(arg: Arg): string
	local name = if arg.rest then `{arg.name}...` else arg.name
	return if arg.optional then `[{name}]` else `<{name}>`
end

local function usageOf(name: string, args: { Arg }): string
	local parts = { name }
	for _, arg in args do
		table.insert(parts, argUsage(arg))
	end
	return table.concat(parts, " ")
end

local function checkName(caller: string, name: any): string
	if type(name) ~= "string" or not string.match(name, "^[%w_%-%.]+$") then
		error(`[HYDROGEN] {caller}: command names and aliases are single words of letters, digits, _ - or ., got {quoted(tostring(name))}`, 3)
	end
	return string.lower(name)
end

-- Validates a spec and builds the command, without registering it.
function Server.build(rawName: any, spec: any, builtin: boolean): Command
	local name = checkName("Commands.register", rawName)
	local caller = `Commands.register({quoted(name)})`
	if type(spec) ~= "table" then
		error(`[HYDROGEN] {caller} expects a spec table: \{ args = ..., run = function(ctx, ...) end }`, 3)
	end
	if type(spec.run) ~= "function" then
		error(`[HYDROGEN] {caller}: the spec needs run = function(ctx, ...) end`, 3)
	end
	if spec.permission ~= nil and type(spec.permission) ~= "string" and type(spec.permission) ~= "function" then
		error(`[HYDROGEN] {caller}: permission must be a string or a function(player): boolean`, 3)
	end

	local aliases: { string } = {}
	for _, alias in spec.aliases or {} do
		local lowered = checkName(caller, alias)
		if lowered ~= name and not table.find(aliases, lowered) then
			table.insert(aliases, lowered)
		end
	end

	local args: { Arg } = {}
	for index, value in spec.args or {} do
		local arg = Args.from(value, index)
		if not arg then
			error(`[HYDROGEN] {caller}: argument {index} is not an argument; use Commands.player(), Commands.number(), ... or a GreenTea schema`, 3)
		end
		if arg.rest and index ~= #spec.args then
			error(`[HYDROGEN] {caller}: argument {index} ({arg.name}) takes the rest of the line, so it must be the last`, 3)
		end
		table.insert(args, arg)
	end

	return {
		name = name,
		aliases = aliases,
		description = if type(spec.description) == "string" then spec.description else "",
		args = args,
		permission = spec.permission,
		hidden = spec.hidden == true,
		run = spec.run,
		usage = usageOf(name, args),
		builtin = builtin,
	}
end

-- Sends every player their command list again on the next frame, once however many calls ask.
local function scheduleRefresh()
	if not running or refreshTimer then
		return
	end
	refreshTimer = Clock.delay(0, function()
		refreshTimer = nil
		Server.refresh()
	end)
end

function Server.register(name: any, spec: any): () -> ()
	if RunService:IsClient() and not Network.activeLoopback() then
		error(`[HYDROGEN] Commands.register is server-only; register commands in a server system`, 2)
	end
	local command = Server.build(name, spec, false)
	for _, word in { command.name, table.unpack(command.aliases) } do
		local existing = lookup[word]
		if existing then
			local what = if word == existing.name then "command" else `an alias of command {quoted(existing.name)}`
			error(`[HYDROGEN] Commands.register({quoted(command.name)}): {quoted(word)} is already {what}; names and aliases must be unique`, 2)
		end
	end

	commands[command.name] = command
	lookup[command.name] = command
	for _, alias in command.aliases do
		lookup[alias] = command
	end
	scheduleRefresh()

	return function()
		if commands[command.name] ~= command then
			return
		end
		commands[command.name] = nil
		for word, entry in lookup do
			if entry == command then
				lookup[word] = nil
			end
		end
		scheduleRefresh()
	end
end

function Server.setBuiltins(list: { Command })
	table.clear(builtins)
	table.clear(builtinLookup)
	for _, command in list do
		builtins[command.name] = command
		builtinLookup[command.name] = command
		for _, alias in command.aliases do
			builtinLookup[alias] = command
		end
	end
end

function Server.configure(newOptions: CommandsOptions)
	if type(newOptions) ~= "table" then
		error(`[HYDROGEN] Commands.configure expects an options table`, 2)
	end
	if newOptions.permissions ~= nil and type(newOptions.permissions) ~= "function" then
		error(`[HYDROGEN] Commands.configure: permissions must be a function(player, permission, command): boolean`, 2)
	end
	local rate = newOptions.rateLimit
	if rate ~= nil and (type(rate) ~= "table" or type(rate.perSecond) ~= "number" or rate.perSecond <= 0) then
		error(`[HYDROGEN] Commands.configure: rateLimit needs a positive perSecond`, 2)
	end
	options = table.clone(newOptions)
	table.clear(admins)
	local list: { number } = newOptions.admins or {}
	for _, userId in list do
		admins[userId] = true
	end
	scheduleRefresh()
end

function Server.options(): CommandsOptions
	return options
end

local function find(word: string): Command?
	return lookup[word] or builtinLookup[word]
end

-- The default resolver: listed admins, and everyone in Studio. Never test players, so a test
-- gets the same answer in Studio and under Lune.
local function defaultResolver(player: Player, _permission: string, _command: string): boolean
	if admins[player.UserId] then
		return true
	end
	return options.studio ~= false and RunService:IsStudio() and Network.activeLoopback() == nil
end

local function resolve(player: Player, permission: string, command: string): boolean
	local resolver = options.permissions or defaultResolver
	local ok, result = pcall(resolver, player, permission, command)
	if not ok then
		Log.warn(`[HYDROGEN] Commands permission resolver failed for {player.Name} and {quoted(permission)}; denying: {result}`)
		return false
	end
	return result == true
end

local function allowed(player: Player, command: Command): boolean
	local permission = command.permission
	if permission == nil then
		return true
	end
	if type(permission) == "function" then
		local ok, result = pcall(permission, player)
		if not ok then
			Log.warn(`[HYDROGEN] Permission check of command {command.name} failed for {player.Name}; denying: {result}`)
			return false
		end
		return result == true
	end
	return resolve(player, permission :: string, command.name)
end

-- Every command in effect: game commands, then built-ins no game command shadows.
local function each(): { Command }
	local list: { Command } = {}
	for _, command in commands do
		table.insert(list, command)
	end
	for _, command in builtins do
		local shadowed = false
		for _, word in { command.name, table.unpack(command.aliases) } do
			if lookup[word] then
				shadowed = true
				break
			end
		end
		if not shadowed then
			table.insert(list, command)
		end
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	return list
end

function Server.can(player: Player, name: string): boolean
	local command = find(string.lower(name))
	return command ~= nil and allowed(player, command)
end

function Server.info(command: Command, player: Player?): CommandInfo
	local args = {}
	for _, arg in command.args do
		local choices = arg.choices
		if arg.type == "command" and player then
			choices = {}
			for _, other in Server.visible(player) do
				table.insert(choices :: { string }, other.name)
			end
		end
		table.insert(args, {
			name = arg.name,
			type = arg.type,
			optional = arg.optional,
			rest = arg.rest ~= nil,
			choices = choices,
		})
	end
	return {
		name = command.name,
		aliases = table.clone(command.aliases),
		description = command.description,
		usage = command.usage,
		args = args,
		restricted = command.permission ~= nil,
	}
end

-- The commands a player may run and see, sorted by name. With no player, every visible command.
function Server.visible(player: Player?): { Command }
	local list = {}
	for _, command in each() do
		if not command.hidden and (player == nil or allowed(player, command)) then
			table.insert(list, command)
		end
	end
	return list
end

function Server.list(player: Player?): { CommandInfo }
	local list = {}
	for _, command in Server.visible(player) do
		table.insert(list, Server.info(command, player))
	end
	return list
end

function Server.find(name: string): Command?
	return find(string.lower(name))
end

local function sendCatalog(player: Player)
	local wire = Wire.peek()
	if not wire or not running or not table.find(players, player) then
		return
	end
	wire.catalog:Fire(player, Server.list(player))
end

-- Sends players their command lists again: after their permissions change, for example.
function Server.refresh(player: Player?)
	if not running then
		return
	end
	local targets: { Player } = if player then { player } else table.clone(players)
	for _, target in targets do
		task.spawn(sendCatalog, target)
	end
end

-- Edit distance, for "did you mean".
local function distance(a: string, b: string): number
	-- previous[j + 1] is the distance from a's first i - 1 letters to b's first j.
	local previous: { number } = {}
	for j = 1, #b + 1 do
		previous[j] = j - 1
	end
	for i = 1, #a do
		local current: { number } = { i }
		for j = 1, #b do
			local cost = if string.byte(a, i) == string.byte(b, j) then 0 else 1
			current[j + 1] = math.min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost)
		end
		previous = current
	end
	return previous[#b + 1]
end

local function suggestion(player: Player, word: string): string?
	local best: string? = nil
	local bestScore = math.huge
	for _, command in Server.visible(player) do
		for _, candidate in { command.name, table.unpack(command.aliases) } do
			local score = distance(word, candidate)
			if string.sub(candidate, 1, #word) == word then
				score = math.min(score, 1)
			end
			if score < bestScore then
				best, bestScore = command.name, score
			end
		end
	end
	local limit = if #word <= 3 then 1 else 2
	if best and bestScore <= limit then
		return best
	end
	return nil
end

local function currentPlayers(): { Player }
	if running then
		return players
	end
	local ok, list = pcall(function()
		return Players:GetPlayers()
	end)
	return if ok then list else {}
end

local Failure = {}
Failure.__index = Failure

local function newContext(player: Player, command: Command, alias: string, text: string, emit: (OutputKind, string) -> ()): CommandContext
	local context = {
		player = player,
		command = command.name,
		alias = alias,
		text = text,
		args = {},
	} :: any
	function context.reply(_: any, message: any)
		emit("info", tostring(message))
	end
	function context.fail(_: any, message: any): never
		error(setmetatable({ message = tostring(message) }, Failure), 0)
	end
	return context :: CommandContext
end

-- Parses the words after the command name. Returns the values, or nil and the error line.
local function parseArgs(command: Command, text: string, tokens: { Args.Token }, context: ParseContext): ({ any }?, string?)
	local values: { any } = {}
	local position = 2
	local function usage(): string
		return `Usage: {command.usage}`
	end
	local function parseOne(arg: Arg, index: number, word: string): (boolean, any)
		local ok, valid, value = pcall(arg.parse, word, context)
		if not ok then
			Log.warn(`[HYDROGEN] Argument {arg.name} of command {command.name} failed to parse {quoted(word)}: {valid}`)
			return false, `Bad argument {index} ({arg.name}) for {command.name}: {quoted(word)} couldn't be read. {usage()}`
		end
		if not valid then
			return false, `Bad argument {index} ({arg.name}) for {command.name}: {tostring(value)}. {usage()}`
		end
		return true, value
	end

	for index, arg in command.args do
		local token = tokens[position]
		if arg.rest == "list" then
			local list = {}
			for at = position, #tokens do
				local ok, value = parseOne(arg, index, tokens[at].text)
				if not ok then
					return nil, value
				end
				table.insert(list, value)
			end
			position = #tokens + 1
			if #list == 0 and not arg.optional then
				return nil, `Missing argument {index} ({arg.name}) for {command.name}. {usage()}`
			end
			values[index] = if #list == 0 and arg.default ~= nil then arg.default else list
		elseif token == nil then
			if not arg.optional then
				return nil, `Missing argument {index} ({arg.name}) for {command.name}. {usage()}`
			end
			values[index] = arg.default
		else
			local word = if arg.rest == "text" then Args.remainder(text, token) else token.text
			local ok, value = parseOne(arg, index, word)
			if ok then
				values[index] = value
				position = if arg.rest == "text" then #tokens + 1 else position + 1
			elseif arg.optional and index < #command.args then
				-- say [times] <message...>: "say hello" leaves times out, and the word goes to the next argument.
				values[index] = arg.default
			else
				return nil, value
			end
		end
	end

	if position <= #tokens then
		local extra = #tokens - 1
		return nil, `Too many arguments for {command.name}: it takes {#command.args}, got {extra}. {usage()}`
	end
	return values, nil
end

-- Parses, authorizes and runs a line as player. Yields while the command yields. Every line of
-- output goes to output (if given) as it's produced, and into the result.
function Server.execute(player: Player, line: string, output: ((OutputKind, string) -> ())?): CommandResult
	if type(player) ~= "table" and typeof(player) ~= "Instance" then
		error(`[HYDROGEN] Commands.execute expects a player and a line of text`, 2)
	end
	if type(line) ~= "string" then
		error(`[HYDROGEN] Commands.execute expects a line of text, got {typeof(line)}`, 2)
	end

	local result: CommandResult = { ok = false, status = "ok", command = nil, output = {} }
	local function emit(kind: OutputKind, text: string)
		table.insert(result.output, { kind = kind, text = text })
		if output then
			local ok, err = pcall(output, kind, text)
			if not ok then
				Log.warn(`[HYDROGEN] Commands output callback failed: {err}`)
			end
		end
	end

	local text = trim(line)
	if string.sub(text, 1, 1) == "/" then
		text = trim(string.sub(text, 2))
	end
	local tokens = Args.tokenize(text)
	if #tokens == 0 then
		result.status = "empty"
		return result
	end

	local alias = string.lower(tokens[1].text)
	local command = find(alias)
	if command == nil or (command.hidden and not allowed(player, command)) then
		result.status = "unknown"
		local message = `Unknown command {quoted(tokens[1].text)}.`
		local guess = suggestion(player, alias)
		if guess then
			message ..= ` Did you mean {quoted(guess)}?`
		end
		if builtinLookup.help and find("help") == builtinLookup.help then
			message ..= ` Type "help" for a list.`
		end
		emit("error", message)
		return result
	end
	local found = command :: Command
	result.command = found.name

	if not allowed(player, found) then
		result.status = "denied"
		emit("error", `You don't have permission to use {quoted(found.name)}.`)
		return result
	end

	local values, problem = parseArgs(found, text, tokens, { player = player, players = currentPlayers() })
	if not values then
		result.status = "invalid"
		emit("error", problem :: string)
		return result
	end

	local context = newContext(player, found, alias, line, emit)
	context.args = values
	local returned = table.pack(xpcall(found.run, function(err: any): any
		if getmetatable(err) == Failure then
			return err
		end
		return debug.traceback(tostring(err), 2)
	end, context, table.unpack(values, 1, #found.args)))

	if not returned[1] then
		local err = returned[2]
		result.status = "failed"
		if getmetatable(err) == Failure then
			emit("error", err.message)
		else
			Log.warn(`[HYDROGEN] Command {found.name} failed for {player.Name}: {err}`)
			local detail = if RunService:IsStudio() then `: {string.match(tostring(err), "^[^\n]*")}` else ""
			emit("error", `{found.name} failed with an error{detail}.`)
		end
		return result
	end

	if type(returned[2]) == "string" then
		emit("info", returned[2])
	end
	result.ok = true
	return result
end

-- A line from the network: length cap and rate limit first.
function Server.receive(player: Player, line: string)
	if not running then
		return
	end
	local wire = Wire.peek()
	local function send(kind: OutputKind, text: string)
		if wire then
			wire.output:Fire(player, kind, text)
		end
	end

	local maxLength = options.maxLength or DEFAULT_MAX_LENGTH
	if #line > maxLength then
		send("error", `That command is too long ({#line} characters; the limit is {maxLength}).`)
		return
	end

	local rate = options.rateLimit or DEFAULT_RATE
	local burst = rate.burst or rate.perSecond
	local now = Clock.now()
	local bucket = buckets[player]
	if not bucket then
		bucket = { tokens = burst, at = now, warned = false }
		buckets[player] = bucket
	end
	bucket.tokens = math.min(burst, bucket.tokens + (now - bucket.at) * rate.perSecond)
	bucket.at = now
	if bucket.tokens < 1 then
		-- One notice per burst of spam, not one per message.
		if not bucket.warned then
			bucket.warned = true
			send("error", "You're sending commands too fast; wait a moment.")
		end
		return
	end
	bucket.tokens -= 1
	bucket.warned = false

	Server.execute(player, line, send)
end

-- Lifecycle, called by the Commands system.

function Server.start()
	running = true
	table.clear(players)
	table.clear(buckets)
end

function Server.playerAdded(player: Player)
	if not table.find(players, player) then
		table.insert(players, player)
	end
	task.spawn(sendCatalog, player)
end

function Server.playerRemoving(player: Player)
	local index = table.find(players, player)
	if index then
		table.remove(players, index)
	end
	buckets[player] = nil
end

function Server.stop()
	running = false
	table.clear(players)
	table.clear(buckets)
	if refreshTimer then
		Clock.cancel(refreshTimer)
		refreshTimer = nil
	end
end

function Server.isRunning(): boolean
	return running
end

return Server
