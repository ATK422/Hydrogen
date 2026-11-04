--!strict

-- Hydrogen.Commands: commands each system registers next to its own code, typed through
-- GreenTea, authorized and run on the server. Hydrogen.Commands is the server system (add it to
-- the server app); Hydrogen.Commands.Client is the client system (add it to the client app).
-- Neither does anything until it is added, so a game without commands pays nothing.

local Definition = require("./Definition")
local Log = require("./Log")
local Network = require("./Network")
local Args = require("@self/Args")
local Builtins = require("@self/Builtins")
local Client = require("@self/Client")
local Server = require("@self/Server")
local Types = require("@self/Types")
local Wire = require("@self/Wire")

export type OutputKind = Types.OutputKind
export type OutputLine = Types.OutputLine
export type Status = Types.Status
export type CommandResult = Types.CommandResult
export type CommandContext = Types.CommandContext
export type ParseContext = Types.ParseContext
export type Arg = Types.Arg
export type ArgOptions = Types.ArgOptions
export type Permission = Types.Permission
export type CommandSpec = Types.CommandSpec
export type PermissionResolver = Types.PermissionResolver
export type RateLimit = Types.RateLimit
export type CommandsOptions = Types.CommandsOptions
export type ArgInfo = Types.ArgInfo
export type CommandInfo = Types.CommandInfo
export type Suggestion = Types.Suggestion
export type Completion = Types.Completion
export type ClientOptions = Types.ClientOptions

local Commands = {
	-- The client system: console, chat commands, output. Add it to the client app.
	Client = Client,

	-- Registers a command; returns a function that removes it. Server-only.
	register = Server.register :: (name: string, spec: CommandSpec) -> () -> (),
	-- Replaces the options: permissions, admins, rate limit, built-ins.
	configure = function(options: CommandsOptions)
		Server.configure(options)
		Server.setBuiltins(Builtins.build(Server.options()))
	end,
	-- Runs a line as player, with the same checks as one typed in the console. Yields while the command does.
	execute = Server.execute :: (player: Player, text: string, output: ((kind: OutputKind, text: string) -> ())?) -> CommandResult,
	-- The commands player may run (every visible command with no player), as the client sees them.
	list = function(player: Player?): { CommandInfo }
		return Server.list(player)
	end,
	-- Whether player may run the command named (or aliased) name.
	can = Server.can :: (player: Player, name: string) -> boolean,
	-- Sends players (one, or everyone) their command list again, e.g. after a role change.
	refresh = function(player: Player?)
		Server.refresh(player)
	end,

	-- Argument types.
	player = Args.player :: (options: { name: string? }?) -> Arg,
	players = Args.players :: (options: { name: string? }?) -> Arg,
	number = Args.number :: (options: { name: string?, min: number?, max: number?, integer: boolean? }?) -> Arg,
	integer = Args.integer :: (options: { name: string?, min: number?, max: number? }?) -> Arg,
	string = Args.string :: (options: { name: string?, maxLength: number? }?) -> Arg,
	boolean = Args.boolean :: (options: { name: string? }?) -> Arg,
	enum = Args.enum :: (choices: { string } | Enum, options: { name: string? }?) -> Arg,
	text = Args.text :: (options: { name: string? }?) -> Arg,
	optional = Args.optional :: (arg: any, default: any?) -> Arg,
	rest = Args.rest :: (arg: any) -> Arg,
	named = Args.named :: (name: string, arg: any) -> Arg,
	arg = Args.arg :: (options: ArgOptions) -> Arg,
}

return Definition.define("Hydrogen.Commands", function()
	local System = Commands :: any

	-- Listeners this system added, removed on stop so a later app (the next test) starts clean.
	local disconnects: { () -> () } = {}

	function System:init()
		Server.setBuiltins(Builtins.build(Server.options()))
		Server.start()
		local wire = Wire.get()
		if not wire then
			Log.warn(`[HYDROGEN] Commands was added after the network started, so players can't send commands; add Hydrogen.Commands to the app before app:start()`)
			return
		end
		table.insert(disconnects, wire.run:On(Server.receive))
		-- Under Hydrogen.test one VM is the server and every client. Without Commands.Client in
		-- the test, nothing would hear the output, and each send would warn.
		if Network.activeLoopback() then
			table.insert(disconnects, wire.output:On(function() end))
			table.insert(disconnects, wire.catalog:On(function() end))
		end
	end

	function System:playerAdded(player: Player)
		Server.playerAdded(player)
	end

	function System:playerRemoving(player: Player)
		Server.playerRemoving(player)
	end

	function System:stop()
		Server.stop()
		for _, disconnect in disconnects do
			disconnect()
		end
		table.clear(disconnects)
	end

	return Commands
end)
