--!strict

-- The public types of Hydrogen.Commands, in one place so every file agrees on them.

export type OutputKind = "info" | "error"

export type OutputLine = {
	kind: OutputKind,
	text: string,
}

export type Status = "ok" | "empty" | "unknown" | "denied" | "invalid" | "failed"

-- What Commands.execute returns. output holds every line the caller was sent, in order.
export type CommandResult = {
	ok: boolean,
	status: Status,
	-- The command's name, once the text named one.
	command: string?,
	output: { OutputLine },
}

-- Passed to run as its first argument.
export type CommandContext = {
	-- Who ran the command.
	player: Player,
	-- The command's registered name.
	command: string,
	-- The name or alias the player typed, lowercased.
	alias: string,
	-- The whole line as typed.
	text: string,
	-- The parsed arguments, the same values run receives after ctx.
	args: { any },
	-- Sends a line to the caller.
	reply: (self: CommandContext, message: string) -> (),
	-- Sends an error line to the caller and stops the command.
	fail: (self: CommandContext, message: string) -> never,
}

-- What an argument's parse sees besides the text.
export type ParseContext = {
	player: Player,
	-- Every player in the game, in join order.
	players: { Player },
}

-- One argument of a command. Build them with the Commands helpers (player, number, enum, ...),
-- pass a GreenTea schema, or make your own with Commands.arg.
export type Arg = {
	-- Shown in usage and errors: give <target> <item> <count>.
	name: string,
	-- Shown in autocomplete: player, number, text, ...
	type: string,
	optional: boolean,
	-- What run receives when an optional argument is left out.
	default: any,
	-- "text" takes the rest of the line as one string; "list" parses every remaining word.
	rest: ("text" | "list")?,
	-- Values autocomplete offers, when the set is fixed.
	choices: { string }?,
	-- Turns one word into a value: true and the value, or false and why it isn't valid.
	parse: (text: string, context: ParseContext) -> (boolean, any),
}

-- A custom argument for Commands.arg.
export type ArgOptions = {
	name: string,
	type: string?,
	choices: { string }?,
	parse: (text: string, context: ParseContext) -> (boolean, any),
}

-- Who may run a command: a permission name for the resolver, or a check of its own.
export type Permission = string | (player: Player) -> boolean

export type CommandSpec = {
	description: string?,
	aliases: { string }?,
	-- Each entry is an Arg or a GreenTea schema.
	args: { any }?,
	-- nil: everyone may run it.
	permission: Permission?,
	-- Left out of help and autocomplete; still runs for players allowed to.
	hidden: boolean?,
	-- Receives the context and then each parsed argument. A returned string is sent to the caller.
	run: (context: CommandContext, ...any) -> ...any,
}

-- Decides whether a player holds a permission. Keep it fast: it runs for every command a
-- player could see whenever their list is sent, and before every run.
export type PermissionResolver = (player: Player, permission: string, command: string) -> boolean

export type RateLimit = {
	perSecond: number,
	burst: number?,
}

export type CommandsOptions = {
	-- Overrides the default resolver (admins plus everyone in Studio).
	permissions: PermissionResolver?,
	-- UserIds the default resolver grants every permission.
	admins: { number }?,
	-- Default true: in Studio the default resolver grants every permission (not to test players).
	studio: boolean?,
	-- Commands each player may send over the network. Default 3 per second, bursts of 6.
	rateLimit: RateLimit?,
	-- Longest line accepted from a client, in bytes. Default 500.
	maxLength: number?,
	-- The built-in help and kick commands. Default true for both; a string for kick sets its permission.
	help: boolean?,
	kick: (boolean | string)?,
}

-- One argument as the client sees it, for usage hints and autocomplete.
export type ArgInfo = {
	name: string,
	type: string,
	optional: boolean,
	rest: boolean,
	choices: { string }?,
}

-- One command as the client sees it.
export type CommandInfo = {
	name: string,
	aliases: { string },
	description: string,
	usage: string,
	args: { ArgInfo },
	-- Needs a permission (the console hides its mobile button when a player has none of these).
	restricted: boolean,
}

export type Suggestion = {
	-- What to put in the box when the suggestion is accepted.
	text: string,
	-- What to show.
	label: string,
	-- Usually the argument's type, or the command's description.
	detail: string?,
}

export type Completion = {
	suggestions: { Suggestion },
	-- The usage line of the command being typed, if any.
	usage: string?,
	-- The argument being typed, if any.
	arg: ArgInfo?,
}

export type ClientOptions = {
	-- Default true: build the console UI.
	console: boolean?,
	-- Keys that toggle the console. Default { Enum.KeyCode.F2 }.
	keys: { Enum.KeyCode }?,
	-- A button that toggles the console on touch screens. Default "auto": shown when the player
	-- can run a restricted command.
	mobileButton: (boolean | "auto")?,
	-- Default true: each command the player may run also works from the chat bar as /name.
	textChat: boolean?,
	-- Default true: output is also shown in the chat window while the console is closed.
	chatOutput: boolean?,
}

return nil
