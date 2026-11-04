# Hydrogen.Commands

> In-game commands (`give me sword 5`, `kick bob`) that each server system registers next to its own code, with typed arguments parsed and validated on the server, pluggable permissions, a rate limit, and an optional client console with history and autocomplete that also binds to the TextChatService chat bar.

## Use it when / Don't use it when

Use it when:
- the game needs admin, moderator or debug commands (`give`, `teleport`, `setround`, `kick`);
- players should have chat commands of their own (`/dance`, `/team red`);
- you want a dev console in Studio: by default everyone may run every command in Studio.

Don't use it when:
- the action belongs in a game UI button: fire a normal `clientEvent` from the UI (see `network.md`);
- you need moderation persistence (bans across servers): Commands runs the command, your system stores the ban;
- you need commands with no player at all (from a webhook or the server console): call your system's functions directly.

## Quick start

Server: add the system and register commands in the systems that own them.

```luau
-- ServerScriptService/Main.server.luau
local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage.Network)
app:addSystemsFolders(ServerScriptService.Systems)
app:addSystem(Hydrogen.Commands)
Hydrogen.Commands.configure({ admins = { 12345678 } }) -- your UserId; Studio grants everyone
app:start()
```

```luau
-- ServerScriptService/Systems/Inventory.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return Hydrogen.define(function(use)
	local Commands = use(Hydrogen.Commands)
	local Inventory = {}

	function Inventory.give(player: Player, item: string, count: number) end

	Commands.register("give", {
		description = "Give items to a player",
		args = { Commands.player(), Commands.named("item", gt.string()), Commands.named("count", gt.number({ integer = true, range = "[1, 999]" })) },
		permission = "admin",
		run = function(ctx, target: Player, item: string, count: number): string
			Inventory.give(target, item, count)
			return `Gave {count} {item} to {target.Name}`
		end,
	})

	return Inventory
end)
```

Client: add the client system. It builds the console (F2, or a button on touch screens) and the chat commands (`/give`).

```luau
-- StarterPlayerScripts/Main.client.luau
local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage:WaitForChild("Network"))
app:addSystem(Hydrogen.Commands.Client)
app:start()
```

## API

`Commands` is `Hydrogen.Commands` (or `use(Hydrogen.Commands)`). `Client` is `Hydrogen.Commands.Client`.

Server (server-only):
- `app:addSystem(Hydrogen.Commands)`: the server system. Registers the network objects in its `init`; add it before `app:start()`.
- `Commands.register(name: string, spec: CommandSpec): () -> ()`: registers a command; returns a function that removes it. Names and aliases are single words (`[%w_%-%.]+`), case-insensitive. Errors on a taken name or alias, or a bad spec.
- `Commands.configure(options: CommandsOptions)`: replaces all options. Any time; players get updated command lists on the next frame.
- `Commands.execute(player: Player, text: string, output: ((kind: OutputKind, text: string) -> ())?): CommandResult`: runs a line as `player` with every check except the rate limit and length cap. **Yields** while the command yields. `output` gets each line as it's produced.
- `Commands.list(player: Player?): { CommandInfo }`: the commands `player` may run, not hidden, sorted; every visible command when `player` is nil.
- `Commands.can(player: Player, name: string): boolean`: whether `player` may run the command named or aliased `name`.
- `Commands.refresh(player: Player?)`: sends one player (or everyone) their command list again. Call it after their permissions change.

Argument builders (each returns an `Arg`; `options.name` is the name shown in usage and errors):
- `Commands.player(options?)`: one `Player`. Accepts a name or display name, whole or its start (`ali`), and `me`. Ambiguous or multiple matches are errors.
- `Commands.players(options?)`: `{ Player }`. Adds `all` (`*`, `everyone`), `others`, and comma lists (`me,bob`).
- `Commands.number(options?: { name, min, max, integer })`, `Commands.integer(options?: { name, min, max })`: `number`.
- `Commands.string(options?: { name, maxLength })`: one word or one "quoted phrase".
- `Commands.boolean(options?)`: `true/false`, `yes/no`, `on/off`, `1/0`.
- `Commands.enum(choices: { string } | Enum, options?)`: one of the words (any case, or a unique start of one); with a Roblox `Enum`, `run` receives the `EnumItem`.
- `Commands.text(options?)`: the rest of the line as one string, spaces kept. Must be the last argument.
- `Commands.rest(arg)`: every remaining word parsed by `arg`, as a list. Must be the last argument. Needs at least one word unless wrapped in `optional`.
- `Commands.optional(arg, default?)`: may be left out; `run` gets `default` (or nil).
- `Commands.named(name, arg)`: the same argument with a display name (useful for GreenTea schemas).
- `Commands.arg({ name: string, type: string?, choices: { string }?, parse: (text: string, context: ParseContext) -> (boolean, any) })`: a custom argument. `parse` returns `true, value` or `false, "why"`.
- Any GreenTea schema works as an argument: `gt.number(...)` and `gt.string(...)` are parsed then checked by the schema (ranges, `integer`, patterns, lengths); `gt.literal` unions become choices; `gt.optional(x)` is optional; `gt.boolean()` is a boolean; anything else tries the word as a number, then boolean, then string.

Client (client-only; under `Hydrogen.test` each fake client has its own view, use `t:as`):
- `app:addSystem(Hydrogen.Commands.Client)`: the client system. Registers the same network objects; builds the console and chat commands in `start` (real clients only).
- `Client.configure(options: ClientOptions)`: before the app starts.
- `Client.run(text: string)`: sends a line to the server. Errors if the client system isn't in the app.
- `Client.commands(): { CommandInfo }`: what this player may run, as last sent.
- `Client.output(): { OutputLine }`: output received, oldest first, last 200 lines.
- `Client.onOutput(fn: (kind: OutputKind, text: string) -> ()): () -> ()`, `Client.onCommandsChanged(fn: ({ CommandInfo }) -> ()): () -> ()`: listeners; return a disconnect function.
- `Client.complete(text: string): Completion`: suggestions and the usage hint for a partly typed line (what the console shows).
- `Client.open()`, `Client.close()`, `Client.toggle()`, `Client.isOpen(): boolean`: the console (no-ops without one).

Types (from `Hydrogen`):
```luau
type CommandSpec = {
	description: string?,
	aliases: { string }?,
	args: { any }?,             -- Commands.* args or GreenTea schemas
	permission: (string | (player: Player) -> boolean)?, -- nil = everyone
	hidden: boolean?,           -- not in help/autocomplete; still runs if allowed
	run: (ctx: CommandContext, ...any) -> ...any, -- a returned string is sent to the caller
}
type CommandContext = {
	player: Player, command: string, alias: string, text: string, args: { any },
	reply: (self, message: string) -> (),     -- a line to the caller
	fail: (self, message: string) -> never,   -- an error line to the caller; stops run
}
type PermissionResolver = (player: Player, permission: string, command: string) -> boolean
type CommandsOptions = {
	permissions: PermissionResolver?, -- replaces the default
	admins: { number }?,              -- UserIds the default resolver allows
	studio: boolean?,                 -- default true: default resolver allows everyone in Studio (not test players)
	rateLimit: { perSecond: number, burst: number? }?, -- default 3/s, burst 6
	maxLength: number?,               -- default 500 bytes per line from a client
	help: boolean?,                   -- default true
	kick: (boolean | string)?,        -- default true; a string sets its permission (default "admin")
}
type CommandResult = { ok: boolean, status: CommandStatus, command: string?, output: { CommandOutputLine } }
type CommandStatus = "ok" | "empty" | "unknown" | "denied" | "invalid" | "failed"
type CommandOutputLine = { kind: "info" | "error", text: string }
type CommandInfo = { name: string, aliases: { string }, description: string, usage: string, args: { CommandArgInfo }, restricted: boolean }
type CommandArgInfo = { name: string, type: string, optional: boolean, rest: boolean, choices: { string }? }
type CommandCompletion = { suggestions: { CommandSuggestion }, usage: string?, arg: CommandArgInfo? }
type CommandSuggestion = { text: string, label: string, detail: string? } -- text = the whole new line
type CommandsClientOptions = {
	console: boolean?,                  -- default true
	keys: { Enum.KeyCode }?,            -- default { Enum.KeyCode.F2 }
	mobileButton: (boolean | "auto")?,  -- default "auto": on touch screens, when the player has a restricted command
	textChat: boolean?,                 -- default true: /name in the chat bar
	chatOutput: boolean?,               -- default true: output also in chat while the console is closed
}
```
Also exported: `Hydrogen.CommandArg`, `CommandArgOptions`, `CommandParseContext` (`{ player: Player, players: { Player } }`), `CommandPermission`, `CommandOutputKind`.

Built-ins: `help [command]` (aliases `commands`, `cmds`; everyone) and `kick <players> [reason...]` (permission `"admin"`).

## Rules

- **Add both halves.** `Hydrogen.Commands` on the server and `Hydrogen.Commands.Client` on every client, both before `app:start()`. Each registers the network names `Hydrogen/Commands/Run`, `/Output` and `/Catalog`; one side without the other is a `NETWORK MISMATCH`. Neither added: nothing is registered and nothing runs.
- **Register commands once.** Call `register` in a system's constructor (runs once per server) or keep the returned remover. Registering a taken name or alias errors. For a temporary command: `Scope.of(self):add(Commands.register(...))`.
- **The server decides everything.** The client sends only the raw line. The server parses, checks the permission, then runs. A line over `maxLength` or beyond the rate limit is answered with an error and not parsed. Commands called with `execute` skip the rate limit and length cap.
- **Line syntax.** Words split on spaces; `"double"` or `'single'` quotes group words. A leading `/` is ignored. Command names and aliases are case-insensitive.
- **Argument order.** `text` and `rest` must be last. An optional argument whose word doesn't parse, with more arguments after it, is left out and the word goes to the next argument (`say [times] <message...>`: `say hi` works). The last argument never falls through: its error is reported.
- **Permissions.** `permission = nil`: everyone. A string: asked of the resolver. A function: called with the player. The default resolver allows `admins` and, in Studio, everyone; never fake test players, so tests behave the same in Studio and under Lune. A resolver or check that errors denies and warns. Resolvers run for every command whenever a player's list is sent, so keep them fast and non-yielding.
- **Errors in `run`.** `ctx:fail(msg)` sends `msg` as an error line. Any other error is warned on the server with a traceback; the caller sees `<name> failed with an error.` (plus the message in Studio).
- **Output** goes only to the caller. Lines sent to a player who left are dropped silently. `run` may yield; the player may leave meanwhile.
- **Built-ins** give way to a game command with the same name or alias; the built-in's other aliases still work. Turn them off with `configure({ help = false, kick = false })`.
- **Hidden commands** are missing from `help`, autocomplete and "did you mean", and are reported as unknown to players not allowed to run them.
- **Unknown commands** suggest the closest command the player may run (`Did you mean "give"?`).
- **Chat commands** (TextChatService only) are created on each client for that player's commands, as `TextChatCommand`s named `/name` and `/alias` in `TextChatService.HydrogenCommands`. Aliases Roblox or the game already use (e.g. `/help`) are skipped, so `help` is `/commands` in chat. Legacy chat: no chat commands; the console still works.
- **Cost.** Requiring Hydrogen defines the two systems and nothing else. No per-frame work: the rate limit refills lazily, the console only reacts to input.

## Recipes

### Plug in a role system (e.g. Hydrogen.Guards)
```luau
Hydrogen.Commands.configure({
	permissions = function(player: Player, permission: string, _command: string): boolean
		return Roles.has(player, permission) -- permission is the spec's string, e.g. "admin"
	end,
})
-- when a player's roles change:
Hydrogen.Commands.refresh(player)
```

### Arguments with defaults and the rest of the line
```luau
Commands.register("announce", {
	args = { Commands.optional(Commands.integer({ name = "seconds", min = 1, max = 60 }), 5), Commands.text({ name = "message" }) },
	permission = "admin",
	run = function(_ctx, seconds: number, message: string)
		Announcements.show(message, seconds) -- "announce Server restarting soon" -> 5, "Server restarting soon"
	end,
})
```

### Several targets, and replies while working
```luau
Commands.register("heal", {
	aliases = { "h" },
	args = { Commands.optional(Commands.players(), nil) },
	permission = "admin",
	run = function(ctx, targets: { Player }?)
		for _, target in targets or { ctx.player } do
			Health.heal(target)
			ctx:reply(`Healed {target.Name}`)
		end
	end,
})
```

### A command everyone can use, with a check of its own
```luau
Commands.register("team", {
	args = { Commands.enum({ "red", "blue" }) },
	run = function(ctx, team: string)
		if Match.isRunning() then
			ctx:fail("You can't switch teams during a match.")
		end
		Teams.assign(ctx.player, team)
		return `You joined {team}.`
	end,
})
```

### A custom argument type
```luau
local function mapArg(): Hydrogen.CommandArg
	return Commands.arg({
		name = "map",
		choices = Maps.names(), -- autocomplete
		parse = function(text: string): (boolean, any)
			local map = Maps.find(text)
			if not map then
				return false, `no map named "{text}"`
			end
			return true, map
		end,
	})
end
```

### Your own console UI instead of the built-in one
```luau
Hydrogen.Commands.Client.configure({ console = false })
local Client = Hydrogen.Commands.Client
Client.onOutput(function(kind, text) MyLog.add(text, kind == "error") end)
-- on submit:  Client.run(textBox.Text)
-- on change:  local completion = Client.complete(textBox.Text)  -- suggestions[i].text is the new line
```

## Mistakes

- Don't add only `Hydrogen.Commands` on the server. Do add `Hydrogen.Commands.Client` to every client app too.
- Don't register commands in `init` or `start` without removing them. Do register in the constructor, or keep the remover (tests start the app many times).
- Don't check permissions inside `run` with your own admin list. Do set `permission` and a resolver, so `help`, autocomplete and the mobile button agree.
- Don't trust `ctx.player` holding a permission to mean the target is valid. Do check game rules (range, ownership) in `run` and `ctx:fail` with a reason.
- Don't call `Client.run` on the server or `Commands.register` on the client. They are one side only (`register` errors on a client).
- Don't yield in a permission resolver. Do load roles in `playerAdded` and call `Commands.refresh(player)` when they're ready.
- Don't parse arguments in `run` from `ctx.text`. Do declare `args`, so players get usage errors and autocomplete.

## Testing

`Commands.execute(player, text)` runs everything but the network and returns `{ ok, status, command, output }`, so most tests need only the server system:

```luau
Hydrogen.test({ systems = { Hydrogen.Commands, Inventory }, players = { "Alice", "Bob" } }, function(t, alice, bob)
	Hydrogen.Commands.configure({ admins = { alice.UserId } })
	local result = Hydrogen.Commands.execute(alice, "give bo sword 5") -- "bo" matches Bob
	assert(result.ok and result.output[1].text == "Gave 5 sword to Bob")

	local denied = Hydrogen.Commands.execute(bob, "give alice sword 5")
	assert(denied.status == "denied")
	local bad = Hydrogen.Commands.execute(alice, "give alice sword lots")
	assert(bad.status == "invalid") -- "Bad argument 3 (count) for give: expected a whole number ..."
end)
```

Over the network, add the client system and act as a player:

```luau
Hydrogen.test({ systems = { Hydrogen.Commands, Hydrogen.Commands.Client }, players = { "Alice" } }, function(t, alice)
	local Client = Hydrogen.Commands.Client
	t:as(alice, function()
		Client.run("help")
		local output = Client.output()
		assert(string.find(output[#output].text, "Commands:", 1, true))
		assert(Client.complete("he").suggestions[1].text == "help ")
	end)
end)
```

- Fake players are never granted by the Studio rule; use `admins = { player.UserId }` or a resolver.
- After `configure` or `register` during a test, `t:advance(0)` delivers the updated command lists; `Commands.refresh(player)` does too.
- The rate limit uses `Hydrogen.Clock`: `t:advance(seconds)` refills it.
- Remove commands a test registers (`local remove = Commands.register(...)`; `remove()` after), or register them once at module level.
- The console and chat commands are built only in a real client, so they need a Studio play test.

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] Commands.register("x"): "y" is already command/an alias of command "z"; names and aliases must be unique` | Rename, or remove the other first. Often a command registered again in `init` on a second app start. |
| `[HYDROGEN] Commands.register: command names and aliases are single words ...` | Use letters, digits, `_`, `-` or `.`. |
| `[HYDROGEN] Commands.register("x"): the spec needs run = function(ctx, ...) end` / `expects a spec table` | Pass `{ run = function(ctx, ...) end, ... }`. |
| `[HYDROGEN] Commands.register("x"): argument N is not an argument ...` | An `args` entry is neither a `Commands.*` argument nor a GreenTea schema. |
| `[HYDROGEN] Commands.register("x"): argument N (name) takes the rest of the line, so it must be the last` | Move `text`/`rest` to the end. |
| `[HYDROGEN] Commands.register("x"): permission must be a string or a function(player): boolean` | Fix `permission`. |
| `[HYDROGEN] Commands.register is server-only; ...` | Register in a server system. |
| `[HYDROGEN] Commands was added after the network started, so players can't send commands; ...` | `app:addSystem(Hydrogen.Commands)` before `app:start()`. |
| `[HYDROGEN] Commands.Client was added after the network started, ...` | Same, for the client system. |
| `[HYDROGEN] Commands.Client.run needs Hydrogen.Commands.Client added to the client app before app:start()` | Add the client system. |
| `[HYDROGEN] Commands.Client.configure must be called before the app starts` | Move the call before `app:start()`. |
| `[HYDROGEN] Commands permission resolver failed for <player> and "<permission>"; denying: ...` | Your resolver errored. Fix it; until then the command is denied. |
| `[HYDROGEN] Permission check of command <name> failed for <player>; denying: ...` | A `permission` function errored. |
| `[HYDROGEN] Command <name> failed for <player>: <traceback>` | `run` errored (not `ctx:fail`). The caller saw `<name> failed with an error.` |
| `[HYDROGEN] Argument <arg> of command <name> failed to parse "<word>": ...` | A custom `parse` errored instead of returning `false, why`. |
| `[HYDROGEN] Commands output callback failed: ...` | The `output` function given to `execute` errored. |
| `[HYDROGEN] Commands.Client listener failed: ...` | An `onOutput` / `onCommandsChanged` listener errored. |
| `[HYDROGEN] Commands.configure: rateLimit needs a positive perSecond` / `permissions must be a function ...` | Fix the options. |
| `[HYDROGEN] Commands.enum expects a non-empty list of words or a Roblox Enum` | Fix the choices. |
| `[HYDROGEN] NETWORK MISMATCH ...` | One side added a Commands system and the other didn't. Add both. |

What players see (`CommandResult.status` in brackets): `Unknown command "x". Did you mean "y"? Type "help" for a list.` (unknown); `You don't have permission to use "x".` (denied); `Bad argument N (name) for x: why. Usage: ...`, `Missing argument N (name) for x. Usage: ...`, `Too many arguments for x: it takes N, got M. Usage: ...` (invalid); `x failed with an error.` or the `ctx:fail` message (failed); `You're sending commands too fast; wait a moment.` and `That command is too long (N characters; the limit is M).` (network only).

## Works with

- `systems.md`: commands live in the systems that own the behaviour; `use(Hydrogen.Commands)` orders boot.
- `network.md`: Commands uses Hydrogen's network; both sides must add their system.
- `scope.md`: `Scope.of(self):add(Commands.register(...))` for commands that live as long as a system or round.
- `testing.md`: `Hydrogen.test`, `t:as`, `t:advance`, `t:expectWarning`.
- `clock.md`: the rate limit reads `Hydrogen.Clock`.
- A role registry (Hydrogen.Guards): plug in through `configure({ permissions = ... })` and call `refresh` on role changes.
