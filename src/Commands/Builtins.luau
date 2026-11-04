--!strict

-- The built-in commands: help for everyone, and kick for players with its permission. A game
-- command with the same name or alias takes the built-in's place.

local Args = require("./Args")
local Server = require("./Server")
local Types = require("./Types")

type CommandContext = Types.CommandContext

local Builtins = {}

local function commandArg(): Types.Arg
	local arg = Args.optional(Args.arg({
		name = "command",
		-- The client completes this type from its own command list.
		type = "command",
		parse = function(text: string)
			return true, string.lower(text)
		end,
	}))
	return arg
end

local function help(context: CommandContext, name: string?): string
	if name then
		local command = Server.find(name)
		if not command or command.hidden or not Server.can(context.player, command.name) then
			context:fail(`No command named {string.format("%q", name)}. Type "help" for a list.`)
		end
		local found = command :: Server.Command
		local lines = { found.usage }
		if found.description ~= "" then
			table.insert(lines, found.description)
		end
		if #found.aliases > 0 then
			table.insert(lines, `Aliases: {table.concat(found.aliases, ", ")}`)
		end
		return table.concat(lines, "\n")
	end

	local lines = { "Commands:" }
	for _, command in Server.visible(context.player) do
		local line = `  {command.usage}`
		if command.description ~= "" then
			line ..= ` - {command.description}`
		end
		table.insert(lines, line)
	end
	return table.concat(lines, "\n")
end

local function kick(context: CommandContext, targets: { Player }, reason: string?): string
	local names = {}
	for _, target in targets do
		target:Kick(reason or `Kicked by {context.player.Name}`)
		table.insert(names, target.Name)
	end
	return `Kicked {table.concat(names, ", ")}.`
end

-- The built-ins the options ask for.
function Builtins.build(options: Types.CommandsOptions): { Server.Command }
	local list = {}
	if options.help ~= false then
		table.insert(
			list,
			Server.build("help", {
				description = "Lists the commands you can use, or explains one.",
				aliases = { "commands", "cmds" },
				args = { commandArg() },
				run = help,
			}, true)
		)
	end
	if options.kick ~= false then
		table.insert(
			list,
			Server.build("kick", {
				description = "Removes players from the server.",
				args = { Args.players(), Args.optional(Args.text({ name = "reason" })) },
				permission = if type(options.kick) == "string" then options.kick else "admin",
				run = kick,
			}, true)
		)
	end
	return list
end

return Builtins
