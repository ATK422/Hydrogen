# Hydrogen

A mildly opinionated Luau framework/bootstrapper for Roblox. Hydrogen gives you:

- **Systems**: modules with `init` / `start`, player (`playerAdded` / `playerRemoving`), character (`characterAdded` / `characterRemoving`) and shutdown (`stop`) hooks that run in dependency order.
- **App**: collects your systems (and network definitions) and boots them.
- **Network**: typed, schema-checked remote events and functions. Nothing fired during startup is lost, because events are queued until the network and each client are ready. Middleware inspects or transforms traffic, and a logger and a rate limiter are built in. Events can be unreliable, and batching and buffer encoding are there when traffic gets heavy.
- **Testing**: `Hydrogen.test` runs your systems with fakes, fake players and a fake clock in one call, checks what was fired with expectations, and always cleans up. It runs in Studio and under Lune, with any test framework. Underneath, `app:replace` swaps a system for a fake and `Hydrogen.loopback` runs server and client systems together in one VM.
- **The kit**: the modules most games end up writing themselves, each free until you use it. Saving with `Data`, per-player and replicated state with `PlayerState` and `State`, purchases with `Receipts`, cleanup with `Scope`, plus `Log`, `Signal`, `Scheduler`, tagged-instance `Component`s, client `Input`, server-side `Guards`, in-game `Commands`, `Config` and feature flags, a `Debug` overlay, and cross-server `Teleport` (with Data hand-off) and `Messaging`.
- **Tools**: `pesde x atk422/create_hydrogen` starts a new game, and `pesde x atk422/hydrogen_lint` checks its network before you playtest.

Package: `atk422/hydrogen` on the [pesde](https://pesde.dev) registry. Current version: **0.5.4** (see [CHANGELOG.md](CHANGELOG.md)). License: MIT.

---

## Part 1: Using Hydrogen in a game

### Start a new game

```bash
pesde x atk422/create_hydrogen
```

It asks for a name and a few options, then sets up Rojo, Rokit, pesde, a booted `Hydrogen.App` on both sides, example systems, a test using `Hydrogen.loopback()`, editor settings and optionally StyLua, Selene, luau-lsp and GitHub Actions. It installs the tools and packages and makes the first commit. Pass `-- --help` for the flags, or `-- my-game --yes` to take every default. See [tools/create-hydrogen](tools/create-hydrogen/README.md). Coding agents scaffolding a game should read [tools/create-hydrogen/docs/ai/create.md](tools/create-hydrogen/docs/ai/create.md).

### Install into an existing project

```bash
pesde add atk422/hydrogen
```

```bash
pesde install
```

Hydrogen validates network payloads with [GreenTea](https://github.com/corecii/greentea). Write your schemas with `Hydrogen.gt`, the same GreenTea copy Hydrogen checks with, so you don't need to install it separately.

### Upgrading from 0.5.0

Nothing breaks: 0.5.1 adds `Clock.serverNow`, meters in `Hydrogen.State`, input buffering, `Hydrogen.Teleport` and `Hydrogen.Messaging`. One rule changed in the docs: register network listeners (`:On`, `:Use`) in `init`, not `start`. A client handles the events the server queued for it as the network starts, before any `start` hook runs, so a client listener added in `start` misses them. Move such listeners to `init`.

### Upgrading from 0.4

Almost all of 0.5 is new kit modules (Data, PlayerState, State, Scope, Receipts, Log, Signal, Scheduler, Component, Input, Guards, Commands, Config, Debug, the test harness and the network lint), and they cost nothing until you use them. These changes can affect a 0.4 game:

- **Systems you `use` are added for you.** A system that's `use`d but wasn't added to the app now boots first, instead of only warning. If a client system `use`s a module that should only run on the server, split it or `app:replace` it on the client.
- **`Hydrogen.logger()` output and `[HYDROGEN]` warnings go through `Hydrogen.Log`.** The text is unchanged, but `Hydrogen.Log.setLevel` now applies to them: a level above `info` hides traffic lines, and one above `warn` hides Hydrogen's warnings.
- **Under `Hydrogen.loopback()`**, `net:client()` is `nil` while the server handles a client's message, and opening a loopback drops events an earlier test queued.

Things you can now delete from game code:

- `CharacterAdded` wiring per player: define `characterAdded` / `characterRemoving` on the system, with `Hydrogen.Scope.of(self, character)` for cleanup.
- A signal class or timer helpers copied into the project: use `Hydrogen.Signal` and `Hydrogen.Scheduler`.
- Modules that returned a bare GreenTea schema had to stay out of `app:addNetwork` (0.4.0's object count looped on them forever). 0.5 counts them, so a shared module can return network objects, State and schemas together.

### Upgrading from 0.3

Most of 0.4 is new and opt-in. These changes can break a 0.3 game:

- **Registering a network name twice errors** (it used to warn and keep the first). Rename one, or put place-specific objects in a [namespace](#namespaces).
- **`serverFunction:Fire` times out after 10 seconds** instead of waiting forever. Raise it per function with `:SetTimeout(seconds)`, or use `:SetTimeout(math.huge)` for the old behaviour. See [Server function timeouts](#server-function-timeouts).
- **The server and every client must run the same Hydrogen version.** The ready handshake changed, and the server creates a third remote (`HydrogenNetworkUnreliableRemoteEvent`). In practice the server and its clients always share one package, so this only matters if you vendor Hydrogen in two places.

Things you can now delete from game code:

- `player.Parent` checks before firing to a player: sends to players who have left are dropped.
- Hand-built ordering between systems' `PlayerRemoving` handlers, such as a save-after-everything hook: use [player and shutdown hooks](#player-and-shutdown-hooks).
- `:: Folder` casts on `WaitForChild` results passed to `addNetwork` / `addSystemsFolders`.

### Public API

```luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

Hydrogen.App            -- App.new(), then add systems/network, then :start()
Hydrogen.define         -- define a system
Hydrogen.clientEvent    -- client -> server event
Hydrogen.serverEvent    -- server -> client event
Hydrogen.clientFunction -- client -> server request/response
Hydrogen.serverFunction -- server -> client request/response
Hydrogen.namespace      -- prefix network names, e.g. Hydrogen.namespace("Lobby").clientEvent("Play")
Hydrogen.useMiddleware  -- add middleware to every network object
Hydrogen.logger         -- build a logging middleware for debugging
Hydrogen.rateLimit      -- build a middleware that drops a player's messages beyond a rate
Hydrogen.DROP           -- return this from a middleware to stop a message
Hydrogen.loopback       -- headless tests: one VM plays the server and fake clients
Hydrogen.test           -- one call per test: loopback, fake clock, app, fakes, players, expectations
Hydrogen.harness        -- the same harness for frameworks with setup/teardown hooks
Hydrogen.Clock          -- time for systems and tests: Clock.now(), serverNow(), wait, delay, heartbeat, fake()
Hydrogen.gt             -- GreenTea, for writing schemas
Hydrogen.Scope          -- cleanup tied to lifetimes: Scope.new(), Scope.of(system, player or character?)
Hydrogen.Data           -- session-locked DataStore persistence: Data.player, Data.store, Data.memory
Hydrogen.PlayerState    -- per-player state from Data or runtime, replicated per field
Hydrogen.State          -- replicated state: value, map, list, meter, playerValue, playerMap, playerList, playerMeter, computed
Hydrogen.Receipts       -- kit: routes ProcessReceipt and grants each purchase once; add it to the app
Hydrogen.Log            -- tagged, levelled logging: Log.of(system or name, player?), setLevel, sinks, buffer
Hydrogen.Character      -- test helpers for fake characters; the characterAdded / characterRemoving hooks need nothing
Hydrogen.Signal         -- typed in-process signals: Signal.new(), Connect, Once, Wait, Fire
Hydrogen.Scheduler      -- timers tied to lifetimes: after, every, fixed (game loop), debounce, throttle
Hydrogen.Component      -- code bound to CollectionService-tagged instances: Component.new(tag, options)
Hydrogen.Input          -- client input actions: contexts with priorities, rebinding, device glyphs, touch buttons
Hydrogen.Guards         -- server-side rules for incoming traffic: cooldowns, roles, range checks, timestamps, predicates
Hydrogen.Commands       -- kit: in-game commands run on the server; add it, and Commands.Client on clients
Hydrogen.Config         -- typed config and feature flags: Config.define, value, shared, flag; add it to the app
Hydrogen.Debug          -- kit: network stats (Debug.stats()) and a developer overlay; add it to the app on both sides
Hydrogen.Teleport       -- kit, server-only: teleports that save and release Data first, retry, and take it back; typed tickets
Hydrogen.Messaging      -- kit, server-only: typed MessagingService topics with schema checks, size and rate limits, retries
```

Types are exported too, for annotations: `Hydrogen.App`, `Hydrogen.Defined<T>`, `Hydrogen.ClientEvent<T...>`, `Hydrogen.ServerEvent<T...>`, `Hydrogen.ClientFunction<A..., R...>`, `Hydrogen.ServerFunction<A..., R...>`, `Hydrogen.MiddlewareContext`, `Hydrogen.Middleware<T...>`, `Hydrogen.AnyMiddleware`, `Hydrogen.LoggerOptions`, `Hydrogen.RateLimitOptions`, `Hydrogen.Namespace`, `Hydrogen.Loopback`, `Hydrogen.AppOptions`, `Hydrogen.Scope`, `Hydrogen.Harness`, `Hydrogen.TestOptions`, `Hydrogen.Expectation`, `Hydrogen.Delivery`, `Hydrogen.FakeClock` and `Hydrogen.FakeClockOptions`. Data adds `Hydrogen.PlayerStore<T>`, `Hydrogen.KeyStore<T>`, `Hydrogen.DataBackend`, `Hydrogen.MemoryBackend` and `Hydrogen.UpdateOnceResult`; PlayerState adds `Hydrogen.PlayerState<S>`. For State: `Hydrogen.StateValue<T>`, `Hydrogen.StateMap<K, V>`, `Hydrogen.StateList<T>`, `Hydrogen.PlayerValue<T>`, `Hydrogen.PlayerMap<K, V>`, `Hydrogen.PlayerList<T>`, `Hydrogen.Computed<T>`, `Hydrogen.StateOptions`, `Hydrogen.PlayerStateOptions`, `Hydrogen.StateSerializer`, `Hydrogen.StateMeter`, `Hydrogen.PlayerMeter`, `Hydrogen.MeterOptions`, `Hydrogen.PlayerMeterOptions` and `Hydrogen.MeterLimit`. For Receipts: `Hydrogen.Receipt`, `Hydrogen.PurchaseDecision`, `Hydrogen.ProductHandler`, `Hydrogen.GamePassHandler`, `Hydrogen.ReceiptStore`, `Hydrogen.ReceiptsOptions`, `Hydrogen.Marketplace`, `Hydrogen.MemoryReceiptStore` and `Hydrogen.FakeMarketplace`. For Log: `Hydrogen.Logger`, `Hydrogen.LogLevel`, `Hydrogen.LogThreshold`, `Hydrogen.LogFields`, `Hydrogen.LogMessage`, `Hydrogen.LogLine`, `Hydrogen.LogSink`, `Hydrogen.LogBuffer` and `Hydrogen.LogRateLimitOptions`. Signal adds `Hydrogen.Signal<T...>` and `Hydrogen.Connection`; Scheduler adds `Hydrogen.Timer`, `Hydrogen.EveryOptions` and `Hydrogen.FixedOptions`. For Component: `Hydrogen.Component<I, T>`, `Hydrogen.ComponentOptions<I, A, T>`, `Hydrogen.ComponentPlainOptions<I, A>` and `Hydrogen.ComponentIdentity`. For Input: `Hydrogen.InputAction<V>`, `Hydrogen.InputContext`, `Hydrogen.InputDevice`, `Hydrogen.InputKey`, `Hydrogen.InputBinding`, `Hydrogen.InputSavedBindings`, `Hydrogen.InputGlyph`, `Hydrogen.InputConflict` and `Hydrogen.InputSource<V>`. For Guards: `Hydrogen.Guard`, `Hydrogen.GuardOptions`, `Hydrogen.GuardRejectHook`, `Hydrogen.Cooldown`, `Hydrogen.CooldownOptions`, `Hydrogen.RoleResolver`, `Hydrogen.RoleSource`, `Hydrogen.GuardPredicate`, `Hydrogen.RangeOptions`, `Hydrogen.TimestampOptions` and `Hydrogen.GuardsConfigureOptions`. For Commands: `Hydrogen.CommandSpec`, `Hydrogen.CommandContext`, `Hydrogen.CommandArg`, `Hydrogen.CommandArgOptions`, `Hydrogen.CommandParseContext`, `Hydrogen.CommandPermission`, `Hydrogen.CommandResult`, `Hydrogen.CommandStatus`, `Hydrogen.CommandOutputKind`, `Hydrogen.CommandOutputLine`, `Hydrogen.CommandInfo`, `Hydrogen.CommandArgInfo`, `Hydrogen.CommandCompletion`, `Hydrogen.CommandSuggestion`, `Hydrogen.CommandsOptions`, `Hydrogen.CommandsClientOptions` and `Hydrogen.PermissionResolver`. For Config: `Hydrogen.Config<V, F>`, `Hydrogen.ConfigSpec<V, F>`, `Hydrogen.Flag`, `Hydrogen.FlagRule`, `Hydrogen.ConfigSegment`, `Hydrogen.ConfigEnvironment`, `Hydrogen.ConfigSource` and `Hydrogen.MemoryConfigSource`. For Debug: `Hydrogen.DebugOptions`, `Hydrogen.NetStat`, `Hydrogen.NetLatency`, `Hydrogen.DebugView`, `Hydrogen.DebugPlayerView`, `Hydrogen.DebugRow`, `Hydrogen.BootReport`, `Hydrogen.DebugWarning` and `Hydrogen.DebugInspectable`. For Teleport: `Hydrogen.TeleportResult`, `Hydrogen.TeleportFailure`, `Hydrogen.TeleportFailReason`, `Hydrogen.TeleportSendOptions`, `Hydrogen.TeleportRequest`, `Hydrogen.TeleportAccepted`, `Hydrogen.TeleportBackend`, `Hydrogen.TeleportConfig`, `Hydrogen.TeleportTicket<T>` and `Hydrogen.FakeTeleportService`. For Messaging: `Hydrogen.MessagingTopic<T>`, `Hydrogen.MessagingTopicOptions`, `Hydrogen.MessageInfo`, `Hydrogen.MessagingBackend`, `Hydrogen.MessagingMessage`, `Hydrogen.MessagingConfig` and `Hydrogen.MessagingMemoryBus`.
Two commands live outside the game: `pesde x atk422/create_hydrogen` starts a new game, and `pesde x atk422/hydrogen_lint` checks its network before you playtest ([Checking the network before you playtest](#checking-the-network-before-you-playtest)).

The names describe **who fires it**: a `clientEvent` is fired by the client and heard by the server; a `serverEvent` is fired by the server and heard by clients.

### Systems

A system is a ModuleScript that returns `Hydrogen.define(...)`. The constructor gets a `use` function for declaring dependencies.

```luau
-- ServerScriptService/Systems/Logger.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function(use)
	local Logger = {}

	function Logger:init()
		-- set up state; don't talk to other systems' runtime state yet
	end

	function Logger:start()
		-- everything is initialized and the network is live
	end

	function Logger.log(message: string)
		print(`[log] {message}`)
	end

	return Logger
end)
```

```luau
-- ServerScriptService/Systems/Players.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local LoggerSystem = require(script.Parent.Logger)

return Hydrogen.define(function(use)
	local Logger = use(LoggerSystem) -- Logger's init/start run before ours

	local PlayersSystem = {}

	function PlayersSystem:start()
		Logger.log("players system started")
	end

	return PlayersSystem
end)
```

Rules worth knowing:

- **The system's `id` is the ModuleScript's name** (e.g. `Logger`). It is read from the calling script, so call `define` at the top level of the module, once per module. Dependency warnings, cycle errors and boot errors name systems by the module's full name (e.g. `ServerScriptService.Lobby.Systems.Data`), so two systems called `Data` can be told apart.
- **Or pass the id yourself:** `Hydrogen.define("Data", function(use) ... end)`. Do this whenever `define` is called through a wrapper function, because the inferred id would be the wrapper's module. An explicit id is also what messages show.
- Every hook is optional and called with `:` (it receives the system as `self`).
- `use(other)` must be called synchronously inside the constructor. It records the dependency and returns `other` (typed without its lifecycle fields, so you can't call `init`/`start` on it by accident).
- **A system you `use` is added to the app for you** if you didn't add it, and boots before the systems that use it, at `app:start()` or when a system added later needs it. With `debug = true` the app prints `[HYDROGEN] Added <Y>: <X> uses it`. The one exception is a system replaced with `app:replace`: the fake stands in for it, so its own dependencies aren't added (you get `System X depends on system Y which was not added to the app` if nothing else adds them).
- Circular `use` chains error at `app:start()` with the cycle printed: `Cyclic system dependency: A -> B -> A`.
- An error in `init` or `start` still stops the boot, but is reported as `[HYDROGEN] System <full name> failed in start: <error and traceback>`.
- Systems with no dependency relationship start in the order they were added.

### Player and shutdown hooks

Systems can also define `playerAdded`, `playerRemoving` and `stop`:

```luau
function Data:playerAdded(player: Player)
	-- load the profile
end

function Data:playerRemoving(player: Player)
	-- save the profile
end

function Data:stop()
	-- flush anything left before the server shuts down
end
```

Hydrogen calls them in dependency order, so you don't depend on the order Roblox runs `PlayerRemoving` connections in:

- `playerAdded` runs on each system in dependency order (dependencies first), for players already in the game when `app:start()` finishes and for everyone who joins later.
- `playerRemoving` runs in **reverse** dependency order. A system that `use`s `Data` gets its `playerRemoving` before `Data` saves, so it can still record a forfeit or a last score.
- `stop` runs in reverse dependency order on shutdown. On the server, `app:start()` binds `app:stop()` to `game:BindToClose`. `stop` first runs `characterRemoving` and `playerRemoving` for every player still in the game, waits until every one of those hooks has returned, then calls the `stop` hooks.
- The hooks for one player run one after another in a single thread, so a hook that yields (a DataStore call) delays the next system's hook for that player. Different players don't wait for each other.
- If a player leaves while their `playerAdded` hooks are still running, `playerRemoving` waits for them to finish. Every system sees `playerAdded` before `playerRemoving` for the same player, and each exactly once.
- A hook that errors is reported with `[HYDROGEN] <hook> failed in system <full name>` and the remaining systems still run, so one broken system can't stop `Data` from saving.
- A system added after `app:start()` gets `playerAdded` for players already in the game.
- The player hooks run on the client too (for every player, including the local one). `stop` is only bound on the server; on the client you can call `app:stop()` yourself.
- For cleanup tied to the system or to a player, ask for a scope with `Hydrogen.Scope.of`. See [Scopes](#scopes).
- For characters, define `characterAdded` / `characterRemoving`. See [Character hooks](#character-hooks).

### Character hooks

Systems can define `characterAdded` and `characterRemoving` to set up and tear down things on each character:

```luau
local Scope = Hydrogen.Scope

return Hydrogen.define(function(use)
	local PlayerData = use(PlayerDataStore) -- loaded before our characterAdded runs

	local Combat = {}

	function Combat:characterAdded(player: Player, character: Model)
		-- Destroyed right after Combat's characterRemoving for this character.
		local scope = Scope.of(self, character)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.MaxHealth = 100 + PlayerData:get(player).level * 10
		scope:connect(humanoid.Died, function()
			PlayerData:update(player, function(data)
				data.deaths += 1
				return nil
			end)
		end)
	end

	function Combat:characterRemoving(player: Player, character: Model)
		-- respawn, LoadCharacter, destroyed, streamed out, or the player is leaving
	end

	return Combat
end)
```

They follow the same rules as the player hooks:

- `characterAdded` runs on each system in dependency order, for the character a player already has and for every respawn or `LoadCharacter`. It waits until that player's `playerAdded` hooks have all returned, so data a system `use`s is loaded.
- `characterRemoving` runs in **reverse** dependency order: on `CharacterRemoving`, when the character leaves the DataModel without it (destroyed, or streamed out on a client), and before any `playerRemoving` when the player leaves or the app stops. It waits for that character's `characterAdded` hooks to finish.
- For one player, everything runs in order in one thread: `playerAdded`, then each character's `characterAdded` and `characterRemoving` (the next character's `characterAdded` waits for the previous `characterRemoving`), then `playerRemoving`. Different players don't wait for each other.
- A character that's gone before its first hook could run (the player respawned while their data was still loading) gets no hooks at all.
- A hook that errors is warned (`[HYDROGEN] characterAdded failed in system <name>`) and the other systems still run.
- `Scope.of(self, character)` is the system's scope for that character, destroyed right after its `characterRemoving`. It's separate from the player scope.
- They run in client apps too, for every player's character. Other players' characters can arrive well after the player, and their parts may stream in later: use `WaitForChild`. With streaming, a character that streams out counts as removed and gets `characterAdded` again when it streams back in.
- `characterRemoving` isn't death; connect `humanoid.Died` in `characterAdded`.
- An app whose systems define neither hook connects nothing for characters.

In tests, fake players get characters with `t:spawnCharacter(player)`; see [Testing your systems](#testing-your-systems). Agents: [docs/ai/character.md](docs/ai/character.md).

#### Why it's designed this way

- **Hooks, not a signal to connect.** `player.CharacterAdded:Connect` in `playerAdded` misses the character that already exists, runs before your data is loaded, has no order between systems, and leaves you to disconnect. A hook fixes all four, and it reads like `playerAdded`.
- **A character is a child of its player.** That one rule gives the ordering people expect: character hooks start after the player's data is loaded and finish before it saves.
- **One thread per player.** Running a player's character hooks one after another means `characterRemoving` for the old character can't run after `characterAdded` for the new one and wipe its state.
- **Stream-out is removal.** A streamed-out character keeps its descendants, so a nametag added on the first `characterAdded` would be duplicated on the next. Treating stream-out as removal destroys it with the character scope, and stream-in adds it again.
- **Built on an extension point.** The App doesn't special-case characters: they are a hook pair registered with `Definition.hooks` (see [Adding a lifecycle hook](#adding-a-lifecycle-hook)), so other kit modules get the same guarantees.

### Scopes

A scope collects what has to be undone (connections, threads, Instances, cleanup functions) and undoes it all when its lifetime ends. Every system has one that lasts until `app:stop()`, and one per player that lasts until that player leaves. Ask for them with `Hydrogen.Scope.of`:

```luau
local Scope = Hydrogen.Scope

return Hydrogen.define(function(use)
	local Combat = {}

	function Combat:start()
		-- Destroyed on app:stop(), right after Combat's stop hook.
		Scope.of(self):connect(RunService.Heartbeat, stepProjectiles)
	end

	function Combat:playerAdded(player: Player)
		-- Destroyed when the player leaves, right after Combat's playerRemoving for them.
		local scope = Scope.of(self, player)
		local arena = scope:add(ArenaTemplate:Clone())
		arena.Parent = workspace.Arenas
		scope:connect(player.CharacterAdded, onCharacter)
		scope:spawn(function()
			while true do
				task.wait(1)
				regenerate(player)
			end
		end)
	end

	return Combat
end)
```

`Scope.of(system)` is the system's scope, `Scope.of(system, player)` its scope for that player, and `Scope.of(system, character)` its scope for a character, destroyed right after the system's `characterRemoving` for it (see [Character hooks](#character-hooks)). Each is created the first time it's asked for, and every later call returns the same one, so it works the same from a hook, a remote handler, a callback or another system (`Scope.of(Combat, player)`). `Hydrogen.Scope.new(name?)` makes one you destroy yourself.

| Method | Does |
| --- | --- |
| `scope:add(task)` | Tracks `task` and returns it. On cleanup a function is called, a thread cancelled, an `RBXScriptConnection` disconnected, an Instance or scope destroyed, and any other object gets its `Destroy`, `Disconnect`, `destroy`, `disconnect` or `cancel` (a promise) method called. Anything else errors when added. |
| `scope:connect(signal, callback)` | `signal:Connect(callback)`, tracked. Any signal with `Connect` works. |
| `scope:spawn(fn, ...)`, `scope:delay(seconds, fn, ...)` | `task.spawn` / `task.delay`, cancelled if the scope goes first. |
| `scope:child(name?)` | A scope destroyed with this one, or earlier with `child:destroy()`: one per round, per character, per open UI. |
| `scope:remove(task)` | Cleans one task now and stops tracking it. |
| `scope:destroy()` | Cleans everything. `scope:Destroy()` is the same, so Trove, Maid and Janitor can hold a scope. |
| `scope.alive` | `false` once destroyed. |

Network listeners go in with `add`, because `:On` returns a disconnect function: `scope:add(Remotes.Chat:On(onChat))`.

Rules:

- **Cleanup runs newest first**, like `defer`: what you made later may depend on what you made earlier.
- A task that errors is reported with `[HYDROGEN] Cleanup failed in scope <name>: <error>`, and the rest still run.
- Cleanup runs in the thread that destroys the scope. A task that yields delays the next one, and for a player scope also the next system's `playerRemoving`, like a yielding hook.
- **Destroyed is final.** Anything added to a destroyed scope is cleaned straight away, and `spawn` / `delay` on it never run. So work that finishes after its player left (a DataStore load, a delay) can't leak. After a yield, check `scope.alive` to skip work for a player who's gone.
- A player scope is open from the player's first `playerAdded` hook until the system's `playerRemoving` for them returns, so it is destroyed in reverse dependency order: a system's scope for a player is gone before the systems it `use`s run their `playerRemoving`. If the player leaves while `playerAdded` is still running, cleanup waits for it like `playerRemoving` does.
- A system scope is open from `init` until `app:stop()`, and is destroyed right after the system's `stop` hook. A boot that errors destroys the system scopes too.
- `Scope.of` after a lifetime ended returns a destroyed scope. It errors for a system that no started app runs, and for a player the app hasn't added yet.
- Under `app:replace`, `Scope.of(original)` and `Scope.of(fake)` are the same scope, so the fake and the systems that `use` the original agree.
- Adding the same task twice tracks it once. A thread that destroys its own scope isn't cancelled; it finishes what it's doing.
- A system that never calls `Scope.of` creates no scope. Hooks are called exactly as before; Hydrogen never passes a scope in.

What can't be automatic: Luau has no hook into `RBXScriptSignal:Connect`, `task.spawn` or `Instance.new`, so a scope only knows what goes through it. Use `scope:connect`, `scope:spawn`, `scope:delay` and `scope:add` where you would have called those directly.

#### Why scopes work this way

- **You ask for a scope; hooks aren't handed one.** Getting a scope is always one visible call, `Scope.of`, and hook signatures stay what they were. Scopes are created on first use, so a system that never asks pays nothing.
- **`Scope.of(system, player)`, not an ambient "current scope".** A current scope tracked per thread would be lost in every connection callback and `task.spawn`, which is exactly where most cleanup is created. `Scope.of` works from any thread.
- **Network listeners aren't tracked behind your back.** A listener registered in `playerAdded` usually serves every player (handlers receive the player), so disconnecting it when the first player leaves would be a bug you'd have to fight. `scope:add(event:On(...))` says what you mean and keeps the callback typed.
- **Closed scopes clean instead of erroring.** The usual cleanup bug is async work finishing after its player left. Cleaning what it adds makes that safe without a check at every step.
- **Destroy is final, so there's no reuse.** A stale reference to last round's scope can't leak into this round. Make a `child()` per round instead.
- Tasks are kept in a table keyed by the task with an insertion counter, so `add`, `remove` and finished threads forgetting themselves are O(1), and `destroy` sorts once.

### Signals

`Hydrogen.Signal` lets a system broadcast something that happened ("a player died", "the round ended") without knowing who listens. It works within one side, server or client. To cross the network, use a `serverEvent` or `clientEvent`.

```luau
-- ReplicatedStorage/Shared/Events.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

-- The annotation is what types Fire, Connect and Wait.
local PlayerDied: Hydrogen.Signal<Player, Player?> = Hydrogen.Signal.new("PlayerDied") -- victim, killer

return {
	PlayerDied = PlayerDied,
}
```

```luau
-- In a system
function Quests:start()
	Scope.of(self):add(Events.PlayerDied:Connect(function(victim: Player, killer: Player?)
		if killer then
			progress(killer, "kills", 1)
		end
	end))
end

-- Elsewhere
Events.PlayerDied:Fire(victim, killer)
```

| Method | Does |
| --- | --- |
| `Signal.new<T...>(name?)` | A new signal. Annotate it (`Hydrogen.Signal<Player, number>`) so firing and listening are type-checked. `name` appears in error warnings. |
| `signal:Connect(fn)` | Calls `fn(...)` on every `Fire`, in connection order. Returns a `Connection` (`:Disconnect()`, `.Connected`), which `scope:add` cleans. |
| `signal:Once(fn)` | Like `Connect`, but disconnects before the first call. |
| `signal:Wait()` | Yields until the next `Fire` and returns its arguments. |
| `signal:Fire(...)` | Runs every listener now. |
| `signal:FireDeferred(...)` | `Fire`, after the current thread yields (`task.defer`). |
| `signal:DisconnectAll()`, `signal:Destroy()` | Disconnect everyone. After `Destroy`, `Connect` returns a disconnected connection and `Fire` does nothing. |

Rules:

- **`Fire` is immediate.** When it returns, every listener has run or reached its first yield.
- **A listener that yields doesn't hold anything up.** The other listeners and the code that fired carry on, and the yielded listener resumes on its own.
- **An error in a listener** is warned as `[HYDROGEN] Listener of signal <name> failed: <error and traceback>`, and the other listeners still run. `Fire` never throws a listener's error.
- **Connecting or disconnecting during a `Fire`:** a listener connected during a `Fire` first hears the next one, and a listener disconnected during a `Fire` (by an earlier listener, or by itself) isn't called again, even by that `Fire`.
- A `Fire` from inside a listener runs all listeners before the outer `Fire` continues.
- Disconnecting drops the signal's reference to your function, so nothing leaks, even if you keep the connection around.

#### Why it's designed this way

- **Immediate by default.** A listener sees the world exactly as it was when `Fire` was called, the stack trace includes the code that fired, and tests can `Fire` and assert on the next line with no frame to wait for. Deferred dispatch protects against re-entrancy, but listeners then see tables the firer may already have changed. `FireDeferred` is there when you want it.
- **One thread per `Fire`, not one per listener.** Listeners run one after another on a reused thread. If one yields, that thread stays with it and the rest continue on another, so a yield still never blocks the others. In Roblox Studio, one `Fire` costs about 0.9 µs with 1 listener, 1.9 µs with 5 and 3.6 µs with 20. A `BindableEvent` costs 2.3 µs and 5.4 µs with 1 and 5, a GoodSignal-style signal (a thread per listener) 4.8 µs and 15 µs with 5 and 20, and a plain table of callbacks 0.05 µs per listener, with no yield or error safety (`bench/Signal.luau`).
- **Connection order, copy on write.** Listeners live in an array. Changing it during a `Fire` swaps in a new array, so the `Fire` in progress walks the list it started with. A `Fire` with no changes copies nothing.
- **Errors are warned, not thrown.** One broken listener shouldn't break the system that fired, or the other listeners. Warnings go through Hydrogen's log, so `Hydrogen.test` captures them (`t:expectWarning`).

### Timers with `Hydrogen.Scheduler`

`Hydrogen.Scheduler` runs code later or repeatedly, and every timer it returns can be bound to a lifetime:

```luau
local Scheduler = Hydrogen.Scheduler

function Regen:start()
	-- Cancelled on app:stop().
	Scheduler.every(1, function()
		regenerateEveryone()
	end):bind(self)

	-- A 20 Hz game loop.
	Scheduler.fixed(1 / 20, function(dt: number)
		stepProjectiles(dt)
	end):bind(self)
end

function Regen:playerAdded(player: Player)
	-- Cancelled when this player leaves.
	Scheduler.after(30, function()
		giveStarterBonus(player)
	end):bind(self, player)
end
```

| Function | Does |
| --- | --- |
| `Scheduler.after(seconds, fn)` | Runs `fn()` once after `seconds`. |
| `Scheduler.every(seconds, fn, { jitter? })` | Runs `fn(elapsed)` every `seconds`, first after one interval. `jitter` adds a random 0 to `jitter` seconds to each interval. |
| `Scheduler.fixed(seconds, fn, { maxSteps? })` | A fixed-timestep loop: `fn(seconds)` runs once per step of exactly `seconds`. After a hitch it runs the missed steps back to back, up to `maxSteps` (default 5), and drops the rest. |
| `Scheduler.debounce(seconds, fn)` | Returns `call, cancel`. `call(...)` runs `fn` once `seconds` have passed without another call, with the last arguments. |
| `Scheduler.throttle(seconds, fn)` | Returns `call, cancel`. `call(...)` runs `fn` at once, at most once per `seconds`. Calls in between become one run at the end of the window, with the last arguments. |
| `Scheduler.count()` | Timers waiting to run, so a test can check nothing leaked. |

A `Timer` has `:cancel()`, `:pause()`, `:resume()` (it continues with the time that was left), `.active` and `.paused`. `timer:bind(scope)` cancels it with any `Hydrogen.Scope`, and `timer:bind(system, player?)` with `Scope.of(system, player)`. `scope:add(timer)` works too. Add debounce's and throttle's `cancel` to a scope the same way.

Rules:

- **Everything runs on `Hydrogen.Clock`**, so `t:advance` in `Hydrogen.test` drives timers deterministically. `t:advance(300)` runs a 60-second `every` five times, and each run sees `Clock.now()` at its own due time.
- **Errors:** a callback that errors is warned as `[HYDROGEN] Scheduler: every(1) callback failed: <error and traceback>`, and the timer keeps running.
- **Yields:** a callback that yields doesn't hold up other timers. A repeating timer whose last run is still yielded skips its runs until that run returns, so runs never pile up or overlap, and you get one warning per timer. Put slow work in `task.spawn` if every run must happen.
- **Running late:** `every` keeps its phase through small delays. If a whole interval was missed, it runs once and starts over from then, with no burst. `fixed` catches up as described above. During a catch-up each step sees the same `Clock.now()`.
- **Ordering:** timers run in due-time order. Ties run in the order they were created, interleaved correctly with `Clock.delay`. A timer created inside a callback with a due time of now runs right after, not in the same pass.
- Timers left on a test's fake clock are dropped when the clock is restored, as the fake clock drops its own waiting threads.

#### Why it's designed this way

- **One heap and one waiting thread.** All timers live in a min-heap ordered by due time, and a single `Clock.delay` waits for the earliest one. A thousand timers cost one waiting thread. With no timers nothing waits at all, and nothing ever runs per frame. A Heartbeat-driven wheel would check the timers every frame even when the next is minutes away. Under the fake clock it would also run each timer at the end of an `advance` rather than at its own time.
- **Callbacks run on a reused thread,** like signal listeners, so a firing creates no thread unless the callback yields.
- **Skipping instead of overlapping:** a game loop that runs twice at once, or queues 30 runs behind a yield, is the classic timer bug. Skipping, with a warning, makes that bug visible instead.
- **`bind`** is the one-word way to tie a timer to the lifetime it belongs to. Leaking a repeating timer past its player is the most common timer bug.

### Network definitions

Declare network objects in shared modules that **both** the server and client require. Each object needs a unique name and a GreenTea schema.

```luau
-- ReplicatedStorage/Network/Chat.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	-- client -> server
	SendMessage = Hydrogen.clientEvent("SendMessage", gt.string()),

	-- server -> client(s); several values are allowed
	MessagePosted = Hydrogen.serverEvent("MessagePosted", gt.string(), gt.string()),

	-- client -> server, returns a value (args and returns wrapped in gt.args / gt.returns)
	GetHistory = Hydrogen.clientFunction("GetHistory", gt.args(gt.number()), gt.returns(gt.array(gt.string()))),

	-- server -> one client, returns a value (curried: args first, then returns)
	Ping = Hydrogen.serverFunction("Ping", gt.number())(gt.number()),
}
```

| Kind | Fire side | Fire methods | Listen side | Listener |
| --- | --- | --- | --- | --- |
| `clientEvent` | client | `:Fire(...)` | server | `:On(function(player, ...) end)` |
| `serverEvent` | server | `:Fire(player \| {players}, ...)`, `:FireAll(...)`, `:FireExcept(player \| {players}, ...)` | client | `:On(function(...) end)` |
| `clientFunction` | client | `:Fire(...)` → returns | server | `:On(function(player, ...) return ... end)` |
| `serverFunction` | server | `:Fire(player, ...)` → returns | client | `:On(function(...) return ... end)` |

#### Namespaces

`Hydrogen.namespace(prefix)` returns the four constructors with every name prefixed by `prefix/`. Use it when several places share code, so a place's `Play` can't collide with a common `Play`:

```luau
local Lobby = Hydrogen.namespace("Lobby")

return {
	Play = Lobby.clientEvent("Play", gt.string()),                    -- sent as "Lobby/Play"
	Joined = Lobby.namespace("Queue").serverEvent("Joined", gt.number()), -- sent as "Lobby/Queue/Joined"
}
```

The prefixed name is the object's name everywhere: on the wire, in `context.name` and in the logger.

Every `:On` returns a disconnect function. Events can have many listeners; a function has one handler (calling `:On` again replaces it).

#### Literal unions

`gt.literal("M1")` and `gt.union` of literals type as `string` (the type solver widens literals when it infers a generic), so a handler would see `move: string`. To keep `"M1" | "M2"`, annotate the network object and cast the constructor; the schema still rejects other values at runtime:

```luau
export type Move = "M1" | "M2"
local MoveSchema = gt.union(gt.literal("M1"), gt.literal("M2"))
local Attack: Hydrogen.ClientEvent<Move> = Hydrogen.clientEvent("Attack", MoveSchema) :: any
```

#### Unreliable events

For data that the next message replaces anyway, such as a per-tick frame, call `:Unreliable()` on a `serverEvent` or `clientEvent`. It returns the event, so it chains onto the definition:

```luau
BattleFrame = Hydrogen.serverEvent("BattleFrame", gt.buffer()):Unreliable(),
```

The sender then uses an `UnreliableRemoteEvent`: messages can be lost or arrive out of order, and Roblox limits each one to about 900 bytes. Unreliable events are never queued. Anything sent before the network starts, or to a player whose client hasn't finished starting, is dropped. Only the sending side needs `:Unreliable()`, but calling it in the shared definition is simplest.

#### Server function timeouts

`serverFunction:Fire` waits for the client to answer, and a client (an exploiter, or one that just left) can simply never answer. So `Fire` errors with `[HYDROGEN] <name> timed out after 10s waiting for <player>` after **10 seconds** by default. Change it per function:

```luau
Confirm = Hydrogen.serverFunction("Confirm", gt.string())(gt.boolean()):SetTimeout(30),
```

`:SetTimeout(math.huge)` waits forever, which lets a client hang the calling thread for good. Call server functions from their own thread (`task.spawn`) if a slow client shouldn't hold up the rest of a system.

Payloads are checked against the schema on both ends:

- **Firing** with values that don't match the schema errors immediately.
- **Receiving** an event whose payload doesn't match is dropped with a `[HYDROGEN] Dropped invalid <name> from <player>` warning; listeners never see it. This is what protects the server from exploiters sending arbitrary data.
- **Functions** check arguments and return values on both ends. A bad request errors back to the caller.
- Events arriving with an unknown network id are dropped with a warning.

Usage inside a system:

```luau
-- server
function ChatServer:init()
	Chat.SendMessage:On(function(player, text)
		Chat.MessagePosted:FireAll(player.Name, text)
	end)
end

-- client
function ChatClient:init()
	Chat.MessagePosted:On(function(author, text)
		print(`{author}: {text}`)
	end)
end

function ChatClient:start()
	Chat.SendMessage:Fire("hello")
end
```

Register listeners in `init`. The network starts between the `init` and `start` hooks, and a client handles the events the server queued for it right then, so a listener added in `start` can miss them. Call functions from `start`.

### Middleware

Middleware sees, and can replace, every payload going over the wire. It has this shape:

```luau
function(context: Hydrogen.MiddlewareContext, ...: any): ...any
	-- return the values to pass on (return ... to leave them unchanged)
	return ...
end
```

`context` tells you what's happening:

| Field | Value |
| --- | --- |
| `name` | the network object's name |
| `kind` | `"ClientEvent"`, `"ServerEvent"`, `"ClientFunction"` or `"ServerFunction"` |
| `direction` | `"outgoing"` (about to be sent) or `"incoming"` (just received) |
| `payload` | `"event"`, `"request"` or `"response"` |
| `player` | on the server, the single player involved (sender, or function target) |
| `players` | on the server, every target of an outgoing `serverEvent` |

To stop a message instead of passing it on, return `Hydrogen.DROP`. A dropped event never reaches the remote or the listeners. A dropped function request or response errors, because the caller is waiting for an answer.

Attach it per object or globally. Each call returns a function that removes the middleware again.

```luau
Chat.SendMessage:Use(middleware)      -- events: runs on send and on receive
Chat.GetHistory:UseRequest(middleware)  -- functions: the arguments
Chat.GetHistory:UseResponse(middleware) -- functions: the return values
Hydrogen.useMiddleware(middleware)    -- every network object
```

The same middleware runs on both sides, so check `context.direction` when it should only act one way. Middleware is layered like an onion: outgoing data runs through object middleware in the order added, then global middleware; incoming data runs through global middleware, then object middleware, each in reverse order. That way an encode/decode pair undoes itself correctly.

Schemas describe your app-level values: they're checked **before** outgoing middleware and **after** incoming middleware. A middleware that changes the wire format must convert back on the receiving side.

Because incoming middleware runs before validation, it receives whatever the other side sent, regardless of the Luau types. On the server that means data from possibly malicious clients: check types before using values in incoming middleware.

#### Logging traffic

`Hydrogen.logger(options?)` builds a middleware that prints every message and passes it through unchanged. Add it on both server and client while debugging:

```luau
Hydrogen.useMiddleware(Hydrogen.logger())
```

Output looks like:

```
[HYDROGEN] -> SendMessage: "hello"
[HYDROGEN] <- SendMessage from Player1: "hello"
[HYDROGEN] -> MessagePosted to 3 players: "Player1", "hello"
[HYDROGEN] <- GetHistory request from Player1: 10
```

Options:

- `filter: (context) -> boolean`: return `false` to skip a message, e.g. `function(context) return context.name ~= "MouseMoved" end`.
- `output: (message: string) -> ()`: where lines go. By default they go through [`Hydrogen.Log`](#logging-with-hydrogenlog) at `info` with the tag `HYDROGEN`: printed, and seen by your sinks, buffers and `t:expectLog`.

Because it's global middleware, the logger shows what is actually on the wire, after your own outgoing middleware and before your own incoming middleware.

#### Rate limiting

Schemas stop bad data, not floods. `Hydrogen.rateLimit(options)` builds a middleware that drops a player's messages once they go over a rate. Each player has a separate allowance for each network object:

```luau
Hydrogen.useMiddleware(Hydrogen.rateLimit({ perSecond = 20 }))                 -- every object
Remotes.PlaceTower:Use(Hydrogen.rateLimit({ perSecond = 5, burst = 10 }))       -- one event
Remotes.GetShop:UseRequest(Hydrogen.rateLimit({ perSecond = 2 }))               -- one function
```

Options:

- `perSecond: number`: messages allowed per second, refilled continuously.
- `burst: number?`: how many may arrive at once before the rate applies. Defaults to `perSecond`.
- `onLimit: (context) -> ()?`: called for each dropped message, e.g. to log or kick. Nothing is logged by default.

It only limits what the server receives from clients (incoming events and function requests). Responses and everything on the client pass through. A limited function request errors back to the client.

### Batching and buffer encoding

Both are off by default, and the plain path above doesn't change. Turn them on when frequent traffic, such as a per-tick frame event, shows up in the network stats. Batching removes the per-call overhead Roblox adds to every remote call. Encoding shrinks each payload. In both cases GreenTea still validates what arrives, and middleware still sees plain values.

#### Batching

```luau
local app = Hydrogen.App.new({ batching = true })
```

With batching on, `Fire` doesn't send right away. Hydrogen collects events per target (each player on the server, the server on the client) and sends them on `Heartbeat`, one remote call per target per frame. The receiver unpacks the call and runs the events in the order they were fired. Each event runs in its own thread, as separate remote calls would, so a listener that yields or errors doesn't hold up the rest.

- Reliable and unreliable events batch separately. Roblox limits an `UnreliableRemoteEvent` message to about 900 bytes, so an unreliable batch is split to stay under an estimated 900 bytes. An unreliable event too big to share a call is sent on its own, as it would be without batching.
- Calling a function sends the events already waiting for that target first, so they arrive before the call.
- Queuing doesn't change. Events fired before the network starts are queued, events for a player whose client hasn't started are held until its handshake, and sends to players who left are dropped. That includes a player who left between `Fire` and the flush.
- Only the sender's setting matters, because receivers always understand batches. Still, turn it on for both apps so both directions batch.
- Under `Hydrogen.loopback()` batching is skipped and events are sent right away. Loopback runs every fake client in one VM, so a single client-side batch would mix their events. Loopback tests your systems' logic; the batching tests cover the wire format.

Trade-offs: every event waits until the end of the frame, which adds up to one frame of latency. A batch is unpacked into one thread per event on the receiving side, the same count as unbatched. And a frame with one event to a target gains nothing: that event is sent as itself.

Why an `App.new` option: batching changes how the whole network runtime sends, and that runtime is shared by everything on one side (see [Booting the app](#booting-the-app)). It has to be decided once, before the network starts, like `debug`. A per-event switch would let events fired in the same frame arrive in a different order than they were fired.

#### Buffer encoding

```luau
local Unit = gt.table({
	id = gt.number({ integer = true, range = "[0, 65535]" }),
	position = gt.Vector3(),
	hp = gt.number({ integer = true, range = "[0, 255]" }),
})

return {
	BattleFrame = Hydrogen.serverEvent("BattleFrame", gt.array(Unit)):Unreliable():Encode(),
}
```

`:Encode()` works on all four kinds (`clientEvent`, `serverEvent`, `clientFunction`, `serverFunction`; for functions it covers the arguments and the return values). The payload is packed into a `buffer` laid out by the schema:

| Schema | Packed as |
| --- | --- |
| `gt.number()` | 8-byte float |
| `gt.number({ integer = true, range = ... })` | the smallest of 1, 2 or 4 bytes that holds the whole range, else 8 |
| `gt.string()`, `gt.buffer()` | length (1 byte below 128) + bytes |
| `gt.boolean()` | 1 byte |
| `gt.Vector3()` | 12 bytes |
| `gt.CFrame()` | 48 bytes, lossless |
| `gt.array(T)` | count + items |
| `gt.table({ ... })` | the fields in key order, without the names |
| `gt.dictionary(K, V)` | count + keys and values |
| `gt.optional(T)` | 1 byte + `T` when present |
| `gt.literal(value)` | nothing |
| several values, `gt.vararg(T)` | each in order (varargs with a count) |

Anything else is sent as a plain Luau value beside the buffer, so every schema can be encoded; those values just don't shrink. That covers unions, `gt.any()`, Instances, EnumItems, `Color3` and tables with both fields and an indexer.

- Validation doesn't change. The receiver decodes, runs incoming middleware, then checks the schema. A message that can't be decoded is dropped with `[HYDROGEN] Dropped undecodable <name>`; for a function, the call errors.
- Middleware, including the logger, sees plain values on both sides. Encoding happens after outgoing middleware and decoding before incoming middleware.
- Both sides must call `:Encode()`, so put it in the shared definition. A side that doesn't will reject the other side's messages.
- Encoded tables carry only the keys the schema declares. GreenTea tables accept extra keys, so an extra key gets through unencoded but is lost when encoded.
- A sized integer outside its range errors when encoding. That can only happen if outgoing middleware changes a value after it was validated.
- Encoding and decoding run in Luau on every message, so they cost more CPU than handing values to the remote. They pay off for large or frequent payloads (arrays of numbers, vectors and CFrames) and do little for an occasional short string.

Why a method on the object: the wire format is part of the definition, both sides need the same one, and the shared definition is where both sides already agree. It also chains like `:Unreliable()`, so you encode the hot events and leave the rest alone.

Compared with Blink or Zap, which generate code ahead of time, Hydrogen packs at runtime from the schema. Each event in a batch carries its own buffer, and ids and counts travel as plain numbers. Expect most of the size savings, not all of them.

### Booting the app

Run one app on the server and one on each client. **Hydrogen supports one app per side.** The dependency graph and the network runtime are shared by the whole Luau VM, so a second app on the same side shares them instead of getting its own. The exception is a test under [`Hydrogen.loopback`](#testing-your-systems), where a server app and a client app can share one VM.

```luau
-- ServerScriptService/Main.server.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage.Network)          -- requires every ModuleScript under it
app:addSystemsFolders(ServerScriptService.Systems) -- collects every system under it
app:start()
```

```luau
-- StarterPlayerScripts/Main.client.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage.Network)
app:addSystemsFolders(ReplicatedStorage.ClientSystems)
app:start()
```

App methods:

- `App.new(options?)`: a fresh app with its own system list. `options.debug = true` prints how long the boot took and how long each system's `init` and `start` took, slowest first. `options.output` changes where that goes (defaults to `print`). `options.batching = true` sends each frame's events as one remote call per target (see [Batching](#batching)).
- `app:addSystem(system)` / `app:addSystems({ ... })`: add systems directly.
- `app:addSystemsFolders(a, b, ...)`: require every ModuleScript in each instance and add the ones that are systems. An instance that is itself a ModuleScript is required too. Non-systems are skipped with a warning, and an instance with no systems at all warns.
- `app:addNetwork(a, b, ...)`: require every ModuleScript in each instance (again including the instance itself if it is a ModuleScript) so their network objects get registered. If the modules' return values hold no network objects, it warns `[HYDROGEN] addNetwork found no network objects in <name>`; that usually means the wrong instance was passed.
- `app:replace(original, fake)`: before `start`, swap a system for a fake (see [Testing your systems](#testing-your-systems)).
- `app:start()`: boot. Systems added after this are `init`ed and `start`ed immediately.
- `app:stop()`: run the shutdown sequence (see [Player and shutdown hooks](#player-and-shutdown-hooks)). Called for you by `BindToClose` on the server; runs once.

Both adders take any `Instance`, so the result of `WaitForChild` can be passed without a cast. On the client, anything outside the LocalScript's own descendants may not have replicated yet when it runs, so `WaitForChild` it first:

```luau
local playerScripts = script.Parent
app:addSystemsFolders(script.Systems, playerScripts:WaitForChild("common"))
```

What `app:start()` does, in order:

1. Sorts systems so dependencies come first.
2. Calls every `init`.
3. Starts the network. The server creates `ReplicatedStorage.HydrogenNetworkRemoteEvent`, `HydrogenNetworkUnreliableRemoteEvent` and `HydrogenNetworkRemoteFunction`. **On the client this yields** until those exist and until the server hands back any events queued for this player.
4. Calls every `start`.
5. Starts the player hooks (`playerAdded` for players already in the game, then for joins) and, on the server, binds `app:stop()` to `BindToClose`.

### Network rules (read these before debugging)

- **Register every network object before `app:start()`.** Objects created after the network starts are ignored with `[HYDROGEN] Network already initialized ignoring X registration`.
- **The server and the client must register the same set of names.** Wire ids are assigned by sorting names alphabetically on each side, so a name that exists on one side only shifts every id after it. Put definitions in shared modules and `addNetwork` the same folders on both sides. When a client connects it sends a fingerprint of its names. If it doesn't match the server's, both sides warn `[HYDROGEN] NETWORK MISMATCH`.
- Names must be unique. Registering a name twice errors. Use `Hydrogen.namespace` to keep names from different places apart.
- Events sent to a player who has left (or is leaving) are dropped. This covers sends from a `PlayerRemoving` handler, or after a yield, that would otherwise queue for a player who will never become ready.
- Events fired before the network starts (e.g. in `init`) are queued and sent once it does. Server events aimed at a player whose client hasn't finished starting are held and delivered on that client's handshake.
- **Functions are not queued.** Only call `clientFunction:Fire` / `serverFunction:Fire` from `start` or later; calling one earlier errors with `called before the network started`.
- `serverFunction:Fire` invokes a single client and yields until it answers or the timeout (10 seconds by default) runs out.
- Middleware added after a message is queued does not run on it; add middleware before firing anything.
- With batching on, events go out on `Heartbeat`, at the end of the frame they were fired in. A function call first sends the events already waiting for its target.

### Checking the network before you playtest

The rules above break at runtime, often far from the cause. `hydrogen_lint` finds those bugs before you press Play. From the game's folder:

```bash
pesde x atk422/hydrogen_lint
```

```
error[one-sided] on the server: ServerEvent "Kick" is registered on the server only
  --> src/server/Admin.luau:7 (ServerScriptService.Server.Admin)
  fix: Ids come from the sorted names, so every name after it reaches the wrong object. It's defined in ServerScriptService.Server.Admin, which clients can't see. Move it to a shared module (such as ReplicatedStorage.Shared.Network) and pass that folder to app:addNetwork on both sides.

server: 1 script, 3 names, network started
client: 1 script, 2 names, network started
1 error, 0 warnings
```

It boots your game twice under Lune, once as the server and once as the client, and compares what Hydrogen's network registered on each side. It reports:

- **one-sided names**: a name on one side only, including definitions in ServerScriptService or StarterPlayer modules, and different `addNetwork` folders on each side (it lists both sides' folders)
- **duplicates**, after `Hydrogen.namespace` prefixes and the `State/<name>` events `Hydrogen.State` and PlayerState register
- **late registrations**: objects first created in a `start` hook or after `app:start()`, with the line that required them
- **mismatches**: a different `:Encode()`, schema or kind of object on each side
- `serverFunction`s missing their curried returns, `clientFunction`s without `gt.args` / `gt.returns`, events nothing listens to, names that differ only by case, a module `addNetwork` would loop on forever (only possible on a pre-release Hydrogen build), script errors during the boot, and Hydrogen's own boot warnings

Flags go after `--`: `--json` prints a JSON report for CI and agents, `--strict` fails on warnings too, `--ignore <rule>` drops a rule, and `--help` lists them all. The exit code is 0 with no errors, 1 with errors and 2 if the lint couldn't run. In CI:

```yaml
- name: Network lint
  run: pesde x atk422/hydrogen_lint -- --strict
```

Rules worth knowing:

- It needs a Rojo project (`default.project.json`) and runs `rojo sourcemap`; without Rojo, pass `--sourcemap <file>`.
- It runs your Scripts and LocalScripts, the modules they require and your systems' `init` and `start` hooks. No players join and no frames run, so a module first required from `playerAdded` or a button press isn't checked. Keep definitions in modules both sides require before `app:start()`.
- A function fired from a `start` hook waits forever, as if the other side never answered. The rest of that hook doesn't run.
- Engine APIs it doesn't emulate return harmless stand-ins, and `WaitForChild` doesn't wait. Your game's `print` output stays out of the report (`--verbose` shows it).

See [docs/ai/lint.md](docs/ai/lint.md) for every flag, rule and the JSON format.

#### Why it's designed this way

- **It runs the game rather than parsing it.** Network names in real games are built at runtime: `Hydrogen.namespace` prefixes, `State/<name>`, PlayerState fields, loops, side-specific branches and modules found through `addNetwork` folders and Instance paths. A static parser would have to resolve Rojo paths, follow requires and evaluate Luau to get them right. Booting each side and reading the registries Hydrogen's network runtime builds gets exactly the names, kinds, schemas and `:Encode()` flags the game would have, from the same code. The cost is that game code must load under Lune, so engine calls get permissive stand-ins, and the lint only sees what the boot reaches.
- **Two worlds in one process.** Each side gets its own Instance tree from the sourcemap, globals, module cache and `RunService` answers, the way two Roblox VMs would. That's faster than two processes (about half a second for a small game, Rojo included) and doesn't depend on finding a `lune` executable to start twice.
- **It doesn't change Hydrogen's network.** It wraps the runtime's methods on the loaded module tables to record who registered what, from which line, and whether the network had started. A duplicate is reported and skipped instead of erroring, so one bug doesn't hide the rest.
- **The engine ships inside Hydrogen** (`src/Testing/Lint/`), and `atk422/hydrogen_lint` is a small launcher that finds the Hydrogen your project installed and runs its engine. The lint reads internal registries, so it always matches the runtime version the game uses, and `pesde x` needs no setup and always runs the newest launcher. Nothing in a game requires the engine, so it costs nothing there.
- **Text for people, JSON for machines**, both with a fix per diagnostic, and exit codes CI can use. Game output never goes to stdout, so `--json` stays parseable.

### Saving data with `Hydrogen.Data`

Declare a store once. It is a system, so add it to the app like any other:

```luau
-- ReplicatedStorage/State/PlayerData.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return Hydrogen.Data.player("PlayerData", {
	template = { coins = 0, inventory = {} :: { string } },
	schema = gt.table({
		coins = gt.number({ integer = true, range = "[0, inf]" }),
		inventory = gt.array(gt.string()),
	}),
})
```

Systems that `use` it see the player's data already loaded in their own `playerAdded`:

```luau
return Hydrogen.define(function(use)
	local PlayerData = use(require(ReplicatedStorage.State.PlayerData))
	local Shop = {}

	function Shop:playerAdded(player: Player)
		print(PlayerData:get(player).coins) -- loaded, no waiting
	end

	function Shop.buy(player: Player, item: string, price: number): boolean
		return PlayerData:update(player, function(data)
			if data.coins < price then
				return false -- abort: nothing changes
			end
			data.coins -= price
			table.insert(data.inventory, item)
		end)
	end

	return Shop
end)
```

That is the whole setup. The store loads each player in `playerAdded`, saves and releases them in `playerRemoving`, autosaves, and flushes everything in `stop` (bound to `BindToClose`).

| Method | What it does |
| --- | --- |
| `store:get(player)` | The loaded data. It is deep-frozen; change it with `update`. Errors if not loaded. |
| `store:find(player)` / `store:isLoaded(player)` | `get` without the error, and whether the load succeeded. |
| `store:waitForLoad(player, timeout?)` | Yields until the player's load finishes (or, if it hasn't started, while they're in the game). Returns whether it loaded. |
| `store:update(player, fn)` | Runs `fn` on a copy, checks the result against the schema and commits it in one step. Return `false` to abort. Returns whether it committed. |
| `store:save(player)` | Saves now and yields until stored. Returns `ok, err`. Saves already running are joined, not repeated. |
| `store:transaction({ a, b }, fn)` | Changes several players all-or-nothing, for trades. `fn` gets `{ [player]: data }`. |
| `store:updateOnce(player, id, fn)` | `update` that runs once per `id` and returns after it is stored. For purchase receipts. |
| `store:changed(fn)` | `fn(player, data, old)` after every commit. Returns a disconnect function. |
| `store:view(userId)` | Reads someone's saved data without locking it (an offline profile). Yields. |

Options (only `template` is required):

- `schema`: a GreenTea schema. Without one, Hydrogen derives it from the template (`gt.typeof`), which is enough for flat data; write one for arrays and ranges.
- `migrations`: a list run in order on data saved before it existed: `function(old) return new end`, or `{ migrate = fn, backwardsCompatible = true }` when servers that don't know the migration can still read its result.
- `autosave` (seconds, default 120), `lockTimeout` (600), `loadTimeout` (30), `retries` (5).
- `key = function(userId) return "Player_" .. userId end` to match keys from an older save system. Defaults to `tostring(userId)`.
- `onLoadFailed = function(player, message) end`: defaults to kicking the player with a message.
- `backend`: where records go (see [Backends](#backends-and-tests)).

#### Purchases: `updateOnce`

```luau
local result = PlayerData:updateOnce(player, receiptInfo.PurchaseId, function(data)
	data.coins += 100
end)
-- "applied" or "duplicate": the grant is stored, return PurchaseGranted
-- "aborted" or "failed":    return NotProcessedYet; Roblox asks again later
```

The id is recorded in the same commit as the change, in the record's own metadata (the last 100 ids are kept), and `updateOnce` only reports success once a save holding both has gone through. If the save fails, the grant stays in memory without being repeated, and the next call for that id saves before answering `"duplicate"`. A player leaving waits for a grant that is still saving; once their data is being released, `updateOnce` answers `"failed"` so the purchase is granted on their next server.

#### Trades: `transaction`

```luau
PlayerData:transaction({ seller, buyer }, function(all)
	local item = table.remove(all[seller].inventory, index)
	if not item or all[buyer].coins < price then
		return false
	end
	all[buyer].coins -= price
	all[seller].coins += price
	table.insert(all[buyer].inventory, item)
end)
```

The change applies to both players at once in memory, and is saved right away with a two-phase commit (as in Lyra): a pending marker is written, then each record with the transaction's id and its previous data, then the marker is removed. A server that loads a record whose marker still exists uses the previous data, so a crash mid-trade stores either both sides or neither. Until that commit succeeds, those players are saved together and never one at a time.

#### Data that isn't a player's

`Hydrogen.Data.store(name, options)` has the same methods keyed by string, plus `load(key)` and `unload(key)`. Load a key before using it; whatever is still loaded is saved and released when the app stops.

```luau
local Guilds = Hydrogen.Data.store("Guilds", { template = { members = {} :: { number }, bank = 0 } })

local ok, err = Guilds:load(guildId) -- yields; session-locked like player data
Guilds:update(guildId, function(guild) guild.bank += 50 end)
Guilds:unload(guildId)
```

#### Backends and tests

On a server, stores use Roblox DataStores. Under Lune, and under `Hydrogen.loopback()` (in Studio too), they use an in-memory backend, so tests and headless runs never touch real data. `Hydrogen.Data.useBackend(Hydrogen.Data.memory())` makes every store use memory, for example in Studio without API access; a `backend` option overrides it for one store. A backend is any table with `update`, `read`, `write` and `budget` (see `Hydrogen.DataBackend`).

The memory backend has test controls: `backend:fail(count, kind?)` makes the next requests error, `backend:setBudget(kind, amount)` simulates throttling, `backend.latency` delays each request, and `backend:peek(store, key)` returns what is stored. `Hydrogen.Data.Clock` holds the time sources (`now`, `wait`) so a test or a fake clock can replace them.

Rules:

- **Data stores do nothing on clients.** Defining one in a shared module is safe (and lets a shared `PlayerState` use it); the client's copy never loads or saves.
- **`update` callbacks must not yield**, so no other change can slip in between reading and writing. A yield errors and nothing changes.
- **An `update` called inside another callback for the same key joins it.** A helper such as `addCoins(player, n)` that calls `PlayerData:update` works inside an `updateOnce` grant or a `transaction`: it changes the same pending copy, which commits or aborts as a whole. A nested update can't abort on its own (return `false` from the outer callback), and `updateOnce` and `transaction` can't be nested. Assigning a `PlayerState` field inside a callback joins it the same way. `get` inside a callback still returns the last committed data.
- **Session locking:** a key is held by one server at a time. A load waits up to `loadTimeout` for another server to release it (a player who just left that server), then fails. A lock not refreshed for `lockTimeout` seconds is treated as abandoned (that server crashed) and taken over, with a warning. Autosave refreshes the lock even when nothing changed.
- **A server that loses its lock stops saving** that key and kicks the player, rather than overwriting the newer server's data.
- **When a load fails** (DataStores down, lock never released, data that fails validation), the player is kicked by default. Until they are gone, `get` returns the template so other systems' `playerAdded` still run, `isLoaded` is `false`, and nothing is saved. A player who leaves while their load is waiting for a lock stops the wait.
- **Missing fields are filled from the template** at every depth where both are tables; existing values are never replaced. Data saved by a newer server (more migrations) is refused unless the newer migrations are marked `backwardsCompatible`.
- **Requests are retried** with exponential backoff (1, 2, 4, 8 seconds), and wait while the DataStore request budget is spent. During shutdown, retries are shortened to fit in `BindToClose`'s time.
- **On shutdown**, `playerRemoving` saves and releases every player, then the store's `stop` saves and releases every other key. New loads fail once shutdown starts.
- **A player who rejoins the same server quickly** waits for their previous session to finish saving before loading again.
- Changed listeners run in their own thread; an error in one is reported with `[HYDROGEN]` and doesn't affect the change.
- Records are capped by Roblox at 4 MB per key. Hydrogen doesn't split large data across keys.

#### Why it's designed this way

- **A store is a system.** Lapis and Lyra need `PlayerAdded` / `PlayerRemoving` / `BindToClose` wiring, and every game writes it slightly differently. Hydrogen's player hooks already run in dependency order, so loading in the store's `playerAdded` means everything that `use`s it sees loaded data, and saving in its `playerRemoving` means those systems get their last word first.
- **Frozen data and copy-on-update**, like Lapis's `freezeData`. A frozen table can be handed out freely: nothing can change it by accident and skip validation or saving. `update` copies, runs your function, and keeps the old value for every top-level field that didn't change, so only real changes are frozen again and listeners (PlayerState) can find what changed by comparing references.
- **The lock lives in the record**, written by `UpdateAsync` (as in Lapis), rather than in MemoryStore (as in Lyra). One request loads and locks, one saves and refreshes, and there is no second service to fail.
- **Transactions commit in memory first, then persist as a group.** `update` never yields and is never blocked by a trade being saved; the cost is that until the commit succeeds, the trade's players are always saved together.
- **`updateOnce` is the receipt primitive** rather than a full receipt handler, so `ProcessReceipt` routing can live in its own module and still record purchases atomically with the grant.

### Per-player state with `Hydrogen.PlayerState`

```luau
-- ReplicatedStorage/State/Session.luau, required by the server and the client
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local PlayerData = require(script.Parent.PlayerData)

return Hydrogen.PlayerState.new("Session", {
	data = PlayerData,                      -- coins and inventory come from Data and are saved
	runtime = { inCombat = false, kills = 0 }, -- live only while the player is in the game
	replicate = {
		coins = "owner",    -- only this player's client
		inCombat = "everyone", -- every client
		-- inventory and kills stay on the server
	},
})
```

Add both modules to both apps (`app:addSystemsFolders(ReplicatedStorage.State)` on each side). Then, on the server:

```luau
local state = Session:get(player)
state.coins += 10           -- checked against PlayerData's schema, saved with the profile, sent to the owner
state.inCombat = true       -- runtime only, sent to everyone
Session:update(player, "inventory", function(items)
	table.insert(items, "sword") -- edits a copy; return a value instead to replace it
end)
```

And on the client:

```luau
Session:changed("coins", function(player, coins, old)
	if player == Players.LocalPlayer then
		coinsLabel.Text = tostring(coins)
	end
end)
local mine = Session:find(Players.LocalPlayer) -- nil until the first update arrives
```

| Method | Server | Client |
| --- | --- | --- |
| `Session:get(player)` | The player's state. Read fields; assign to change them. Errors before `playerAdded` or after `playerRemoving`. | What has been replicated for `player`, read-only. Errors if nothing arrived yet. |
| `Session:find(player)` | `get`, or `nil`. | `get`, or `nil`. |
| `Session:update(player, field, fn)` | Edits one field through a copy. | Errors. |
| `Session:changed(field, fn)` | `fn(player, value, old)` on every change, whatever made it (including `PlayerData:update`). | When an update arrives, including the first. |

Rules:

- **Declaring a field takes one word.** Fields of the Data store's template (and schema) are saved fields; fields in `runtime` are runtime-only, with the given starting value. `replicate` maps a field to `"owner"` or `"everyone"`; fields not listed never leave the server. A typo, an unknown audience or a field that is both saved and runtime errors when the state is defined.
- **The state is created in `playerAdded` and removed in `playerRemoving`**, in dependency order: it `use`s its Data store, so it is created after the data loads and removed before it saves. Systems that `use` the state see it in their own `playerAdded`.
- **Assigning a saved field writes to the Data store**, validated against the store's schema at the assignment. Changes made through the store (`update`, `updateOnce`, `transaction`) show up in the state and are replicated too, so there is one source of truth.
- **Values are frozen.** `table.insert(state.inventory, x)` errors: assign a new table or use `update`. Assigning an unknown field errors.
- Reading a field is a plain table lookup (the state's metatable `__index` is the values table), so reads cost about the same as a normal table. Writes go through `__newindex`. `for field, value in state do` iterates the fields.
- **Replication is coalesced**: changes are sent once at the end of the frame, only the fields that changed, only to the clients allowed to see them. A player who joins gets the public fields of everyone already in the game, and leaving players are removed from every client.
- The state's network event is named `Hydrogen/PlayerState/<name>`, so define each state in a shared module on both sides, like any network object. A state with no replicated fields registers no network object.
- Under `Hydrogen.loopback()`, the server API is what `get` and `changed` use. `Session:replica(viewer, player)` returns what `viewer`'s client has received about `player`, so a test can check who sees what.

#### Why it's designed this way

- **Replication is declared per field**, next to where the field comes from, because "who can see this?" is the question that matters most and should be answered in one word, not in a separate remote per value.
- **PlayerState doesn't keep its own copy of saved data.** It listens to its store, so a purchase granted through `PlayerData:updateOnce` replicates exactly like `state.coins += 10`, and there's no second copy to save or reconcile.
- **Field access goes through a proxy** so assignment can validate, save and replicate. Reads hit a plain table through `__index`, so the cost is on writes, which are much rarer.
- **Sending lives in its own small module**, so the `State` module can take it over without changing how fields are declared.
### State

`Hydrogen.State` is state the server owns and clients see: the round phase, a timer, each player's coins, a leaderboard, an inventory. Define it once in a shared module, write it on the server, and read or observe it anywhere.

```luau
-- ReplicatedStorage/Network/GameState.luau (required by addNetwork on both sides)
local State = Hydrogen.State
local gt = Hydrogen.gt

return {
	Round = State.value("Round", gt.string(), "Lobby"),                      -- everyone sees it
	Scores = State.map("Scores", gt.string(), gt.number()),                  -- sent as key diffs
	Feed = State.list("Feed", gt.string()),                                  -- sent as inserts/removes
	Coins = State.playerValue("Coins", gt.number(), 0),                      -- only that player sees it
	Level = State.playerValue("Level", gt.number(), 1, { visibleTo = "everyone" }),
	Inventory = State.playerMap("Inventory", gt.string(), gt.number()),
}
```

```luau
-- server
GameState.Round:set("Playing")
GameState.Coins:update(player, function(coins) return coins + 10 end)
GameState.Inventory:set(player, "sword", 1)

-- client
GameState.Round:observe(function(round)
	statusLabel.Text = round -- called now with the current value, then on every change
end)
local coins = GameState.Coins:get(Players.LocalPlayer)
```

There is nothing to add to the app: defining a state registers its network event, and the server starts replicating the first time state is used.

| Constructor | Holds | Who sees it | Writes (server) | Reads (both sides) |
| --- | --- | --- | --- | --- |
| `State.value(name, schema, initial)` | one value | everyone | `set`, `update` | `get`, `observe` |
| `State.map(name, keySchema, valueSchema)` | key → value | everyone | `set` (nil removes), `remove`, `update`, `replace`, `clear` | `get`, `all`, `size`, `observe`, `observeKey`, `onChange` |
| `State.list(name, itemSchema)` | array | everyone | `push`, `insert`, `remove`, `set`, `replace`, `clear` | `get`, `all`, `size`, `observe` |
| `State.playerValue` / `playerMap` / `playerList` | the same, per player | the owner, or everyone with `visibleTo = "everyone"` | the same, player first: `Coins:set(player, 10)` | the same, player first: `Coins:get(player)`; plus `observeAll(fn(player, ...))` for every player |
| `State.meter(name, { max = 100 })` | a number moving at a rate between min and max | everyone | `set`, `add`, `setRate`, `setRange` | `get`, `getRate`, `getRange`, `observe`, `onLimit`; on the server, `getAt` with `history` |
| `State.playerMeter(name, options)` | the same, per player | the owner, or everyone with `visibleTo = "everyone"` | the same, player first, plus `sync` | the same, player first, plus `observeAll`; the owner can `predictRate` / `predictAdd` with `predict = true` |
| `State.computed(fn)` | `fn()` | each side computes its own | none | `get`, `observe` |

Options, as the last argument:

- `visibleTo = "owner" | "everyone"`: per-player state only. Defaults to `"owner"`.
- `encode = true`: packs the state's messages with [buffer encoding](#buffer-encoding).
- `serializer = { schema, serialize, deserialize }`: sends values in another form, e.g. a class instance as a number. `schema` describes the serialized form and is what the wire is checked against; writes are still checked against the state's own schema.

Rules worth knowing:

- **Define states in shared modules that both sides require before `app:start()`**, as with network objects: each state is a `serverEvent` named `State/<name>`, so a state defined on one side only shifts wire ids. Defining one after the network started errors, and so does a duplicate name.
- **Only the server writes.** A write is checked against the schema (an error at your line), applied at once, and observers on the server run straight away. A write that doesn't change anything (the same number or string) does nothing. A table value always counts as a change, so changing a table in place and setting it again still replicates.
- **Writes in one frame go out together.** At the end of the frame each changed state sends one message (one per changed player, for per-player state), however many writes it took. Maps send only the changed and removed keys; `replace(entries)` works out the difference for you. Lists send the inserts, removes and sets, or the whole list when that is smaller. Call `State.flush()` to send now, e.g. before firing an event whose listeners expect the new state.
- **Late joiners get a snapshot.** When a player joins, they are sent everything already written that they may see, then every change after it. It arrives in the ready handshake, so client systems see it in `start`.
- **Players leaving.** Other clients drop a departed player's state. On the server it stays readable, so a later `playerRemoving` hook can still save it, and is freed with the player. Writes for a player who left are applied on the server and not sent.
- **Observers** get the current value immediately, then each change, and return a disconnect function. Map and list observers get a copy of the whole collection; use `observeKey` or `onChange` for one key at a time. Per-player state's `observeAll(function(player, value, previous) end)` watches every player at once, e.g. for a leaderboard: it is called now for each player whose state exists on this side, then on every change. A player whose state was never written has the initial value and isn't called until it changes. An observer that errors is reported with `[HYDROGEN] Observer of State <name> failed` without stopping the others, and one that yields doesn't hold up the write.
- **Computed state** is a function of other state: `State.computed(function() return Round:get() == "Playing" and Timer:get() > 0 end)`. It depends on whatever it read, through other computed state too, and is never sent: each client computes it from its replicas. It must not yield.
- Messages are validated on the client like any server event, and go through middleware: `GameState.Round.event` is the underlying `serverEvent`, and `Hydrogen.logger()` shows `State/Round`. With `App.new({ batching = true })` state messages are batched like any other event.
- **Under `Hydrogen.loopback`**, each fake client has its own replica: code inside `net:as(player, fn)` reads that client's copy, and code outside reads the server's. `State.reset()` puts every state back to its initial value and drops observers; call it between tests.

For other kit modules: per-player state is the layer PlayerState-style modules sit on. Create a `playerValue`, `playerMap` or `playerList` per field from a shared module, choose `visibleTo` per field, and write to it as the data changes; State handles snapshots, diffs and departures. On the client, `observeAll` gives a per-field changed signal across players.

#### Meters: stamina, mana, hunger, heat

A meter is a number that moves at a steady rate between a min and a max. Instead of sending the value every tick, the server sends a segment, the value at a server time and its rate, only when something jumps: `set`, `add`, `setRate` or `setRange`. Each side works out the value now in `get()` from `Hydrogen.Clock.serverNow()`, clamped to the range. Time passing costs nothing and sends nothing.

```luau
-- shared
local Movement = {
	Stamina = State.playerMeter("Stamina", { max = 100, rate = 10, predict = true }), -- refills 10/s
	Sprint = Hydrogen.clientEvent("Sprint", gt.boolean()),
}

-- server
Movement.Sprint:On(function(player, sprinting)
	Movement.Stamina:setRate(player, if sprinting then -25 else 10) -- one message, however long they sprint
end)
Movement.Stamina:onLimit(player, function(limit)
	if limit == "min" then
		Movement.Stamina:setRate(player, 10) -- out of stamina: one timer, no polling
	end
end)
Movement.Stamina:add(player, -30) -- a dodge costs 30 at once

-- client
Movement.Stamina:predictRate(Players.LocalPlayer, -25) -- shows at once...
Movement.Sprint:Fire(true)                              -- ...and the server makes it real
RunService.RenderStepped:Connect(function()
	bar.Size = UDim2.fromScale(Movement.Stamina:get(Players.LocalPlayer) / 100, 1)
end)
```

- Options: `min` (default 0), `max` (required), `value` (initial, default `max`), `rate` (initial units per second, default 0), `history` (seconds of past values kept for `getAt`, off by default), and for `playerMeter` `visibleTo`, `predict` and `predictTimeout` (seconds, default 1). The initial rate starts when the player joins, or when the server first uses the meter.
- **Observers fire on changes, not as time passes.** `observe(function(value, rate) end)` is for things that happen on a change; a bar that moves smoothly reads `get()` every frame.
- **`onLimit(function(limit) end)`** is called with `"min"` or `"max"` when the value gets there, on time, from a single `Clock.delay` rescheduled on each change. A listener costs nothing until connected.
- **Prediction** is for the owning client and opt-in (`predict = true`). `predictRate` and `predictAdd` change only that client's view, from its `Clock.serverNow()`. The next update from the server replaces the prediction, confirming or correcting it; without one it is dropped after `predictTimeout`. The server never sees it, so pair it with a `clientEvent`, and call `sync(player)` when you turn a request down so the client is corrected at once.
- A client whose clock is behind the server's holds the value until it catches up rather than running it backwards. Under `Hydrogen.test`, `t:advance` moves meters on every side and `t.clock:setServerOffset(seconds, player)` skews one client.
- Values are numbers checked to be finite: NaN or infinity in a write, or `min > max`, errors at your line. Writes outside the range are clamped.

**Judging an action at the moment the player acted.** Say a spell casts only while mana is between 85 and 95. The client sees 94 and casts, but by the time the request arrives the server's `get()` has charged on to 97. A flat tolerance is too loose for slow meters and too tight at high ping. Instead, give the meter `history` and judge the value at the client's stamp:

```luau
-- shared
local Mana = State.playerMeter("Mana", { max = 100, rate = 8, history = 1.5 }) -- the server keeps 1.5 s of past values
local CastFulgur = Hydrogen.clientEvent("CastFulgur", gt.number())

-- client
CastFulgur:Fire(Hydrogen.Clock.serverNow()) -- when the player pressed

-- server
CastFulgur:Use(Hydrogen.Guards.timestamp()) -- no stamps from the future or older than ping (max 1 s) + 0.2 s
CastFulgur:On(function(player, castAt)
	local mana = Mana:getAt(player, castAt) -- what the player saw; nil if older than history
	if mana and mana >= 85 and mana <= 95 then
		Mana:add(player, -40)
	end
end)
```

- `getAt(player, serverTime)` (`getAt(serverTime)` on a global meter) runs on the server only, and needs `history`; without it, it errors and says what to set. It returns the value from the segment that was in force at that time, clamped to its range. A time after the last write, such as a stamp slightly ahead of the server's clock, extrapolates like `get()`. It returns `nil` for a time more than `history` seconds ago.
- History costs nothing until you set it. With it, each server write keeps the segment it replaced and drops those that ended more than `history` seconds ago, at most 128 per meter per player. Nothing runs while time passes. A player leaving drops their meter's past.
- Make `history` at least the oldest stamp `Guards.timestamp()` lets through: ping (capped at `maxPing`, 1 s) plus `tolerance` (0.2 s), so `history = 1.5` covers the defaults.
- `getAt` reads the past before any later write, so a cost paid now doesn't show at an earlier stamp. When one action spends what the next one checks, refuse stamps older than the last accepted action. `docs/ai/state.md` has the full recipe.

#### Why it's designed this way

- **One network event per state**, not one channel for everything: each state gets its own GreenTea schema, so the client validates what it receives, `:Encode()` and middleware apply per state, and the logger shows the state's name. Ids come from the same sorted-name rule as every other network object.
- **Meters send segments, not values.** A value with a rate is fully described by where it was, when, and how fast it moves, so both sides can compute it at any moment. That removes per-tick traffic and the lag of waiting for the next tick; the cost is that clients must share a clock, which `Clock.serverNow()` (`workspace:GetServerTimeNow()`) provides. Prediction is a local overlay replaced by the next update rather than a rollback system, which is enough for one owner changing one rate.
- **Collections send operations, values send values.** A map diff carries parallel key and value arrays rather than a table keyed by your keys, because remotes mangle tables with non-string keys. A list diff carries the operations in order; it falls back to the whole list once a frame has more operations than the list has items.
- **Flushing at the end of the frame** keeps a loop of 100 writes to one message. Unlike sending immediately, an event fired right after a write can arrive first; that is what `State.flush()` is for.
- **No system to add.** Replication starts the first time state is used on the server, so a game that never uses State pays nothing (no connections, no per-frame work), and one that does can't forget to add it.
- **Server per-player state is held weakly by `Player`** rather than deleted on leave, so systems that save in `playerRemoving` still read it, without State having to know when the last hook finished.
- Compared with Charm/charm-sync and Reflex, there is no single store to slice and diff each frame: each state tracks its own changes as they are written, so an idle game does no work. Compared with ReplicaService, there is no replica object to create and destroy per player: per-player state is created the first time it is written.

### Testing your systems

`Hydrogen.test` runs a test of your systems in one call. It opens a loopback network (one VM plays the server and fake clients), installs a fake clock, builds and starts an app with your systems and fakes, and joins players. Then it runs your test function and tears everything down afterwards, even when the test errors. It works under [Lune](https://lune-org.github.io/docs) and in Studio, inside any test framework (frktest, TestEZ, Jest-Lua) or none: a failed expectation is an error. `test/Testing.luau` in this repository has runnable examples.

```luau
local Remotes = require(ReplicatedStorage.Network.Shop)
local Shop = require(ServerScriptService.Systems.Shop) -- does `local Data = use(DataSystem)`
local DataSystem = require(ServerScriptService.Systems.Data)

Hydrogen.test({
	systems = { Shop },
	replace = { [DataSystem] = { getCoins = function() return 500 end } },
	players = { "Alice", "Bob" },
}, function(t, alice, bob)
	t:as(alice, function()
		Remotes.Buy:Fire("sword")
	end)

	t:expect(Remotes.Buy):firedBy(alice, "sword")
	t:expect(Remotes.Bought):firedTo(alice, "sword", 500)
	t:expect(Remotes.Bought):notFired(bob)
end)
```

In TestEZ or Jest-Lua, call it inside `it(...)`; in frktest, inside `test.case(...)`. Without options it is `Hydrogen.test(function(t) ... end)`.

Options, all optional:

| Option | What it does |
| --- | --- |
| `systems` | Systems to add to the app. |
| `replace` | Fakes as `{ [Original] = fake }`, applied with [`app:replace`](#faking-a-dependency-with-appreplace). |
| `players` | Fake clients joined before the app starts: names (`{ "Alice", "Bob" }`) or a count. The test function gets them after `t`. |
| `start` | The app is started before your function runs. Pass `false` to set up with `t:add`, `t:replace` and `t:join` first, then call `t:start()`. |
| `app` | Options for `App.new`, e.g. `{ debug = true }`. |
| `clock` | `false` keeps real time. A table such as `{ now = 0, time = 1700000000 }` sets where the fake clock starts. |

The harness `t` has:

- `t:add(...)`, `t:replace(original, fake)` and `t:start()`, for setup with `start = false`. Systems added after the start boot right away.
- `t:join(name?)`, `t:leave(player)`, `t:as(player, fn, ...)`, `t:player(name)` and `t:players()`, which work as on [the loopback](#client-and-server-in-one-vm-with-hydrogenloopback).
- `t:spawnCharacter(player, model?)`, `t:removeCharacter(player)` and `t:streamCharacter(player, streamedIn)`, which give a fake player a character (as `LoadCharacter` would), remove it, or stream it out and back in, running the [character hooks](#character-hooks). Without a model, `spawnCharacter` builds one with a `Humanoid` and `HumanoidRootPart`; the harness destroys it at the end. With a bare `Hydrogen.loopback()`, use `Hydrogen.Character.spawnFake`, `removeFake` and `streamFake`.
- `t:advance(seconds)`, which moves the [fake clock](#time-and-the-fake-clock).
- the expectations below, and `t:clear()`, which forgets what was delivered so far (e.g. after setup).
- `t.app`, `t.net` and `t.clock`: the app, the loopback and the fake clock themselves.
- `t:close()`, the teardown. `Hydrogen.test` calls it for you.

For frameworks that split setup and teardown into hooks, `Hydrogen.harness(options?)` returns the same `t` without running a function. Call `t:close()` in `afterEach`. If a harness is still open when the next one opens, it is closed first with a warning, so one forgotten `close` can't break the tests after it.

#### Expectations

`t:expect(object)` checks what a network object **delivered**: what the receiving listeners or handler got.

| Method | Passes when |
| --- | --- |
| `:fired(...)` | The event was delivered at least once, to or from anyone. |
| `:firedTo(player, ...)` | A server event reached that client. |
| `:firedBy(player, ...)` | The server received a client event from that client. |
| `:notFired(player?)` | It was never delivered (to or from `player`, if given). |
| `:firedTimes(n)` | It was delivered exactly `n` times. `FireAll` to three clients counts three. |
| `:called(...)` | A function's handler ran with these arguments. |
| `:calledBy(player, ...)` | A client function was called by `player`, or a server function was answered by `player`. |
| `:returned(...)` | Some call returned exactly these values. |
| `:notCalled()`, `:calledTimes(n)` | Never called, or called exactly `n` times. |
| `:deliveries()` | Returns the deliveries, oldest first, for checks of your own. |

On the harness itself: `t:expectNothingFired()` (no event or call at all), `t:expectWarning(text)`, `t:expectNoWarnings()`, `t:warnings()` and `t:deliveries(object?)`.

- Arguments are optional. Without them, any arguments match. With them, the count must match, tables compare by value, and players compare by identity. `t.any` matches any one value: `firedTo(alice, "sword", t.any)`.
- Expectations chain: `t:expect(Remotes.Bought):firedTo(alice):firedTimes(1)`.
- Loopback delivers immediately, so expect right after firing. A message that middleware, the rate limiter or validation dropped was not delivered and doesn't count. Neither does a send to a player who left.
- Recorded arguments are copies, so a listener that changes a table it received doesn't change what the test sees.
- A failure errors at the line of the expectation and says what happened instead:

```
[HYDROGEN] Expected Bought to be fired to Alice with ("sword", 500), but it was fired 1 time:
  to Bob: ("sword", 500)
```

- Using the wrong method for the kind of object errors with the right one, e.g. `firedTo is for serverEvents; Buy is a clientEvent, use firedBy`.

#### Warnings

While a test runs, its warnings are captured instead of printed. `t:expectWarning(text)` passes when a warning contains `text` (plain text, not a pattern) and marks every such warning as expected. `t:expectNoWarnings()` fails on any warning that isn't expected. Unexpected warnings are printed when the test ends, so nothing is hidden, and expected ones don't clutter the output.

Under [Hydrogen's Lune runtime](#running-tests-under-lune) every `warn()` is captured, your systems' included. In Studio the harness captures the warnings Hydrogen and its kit modules emit (dropped payloads, unknown ids, mismatches, failed saves) and `Hydrogen.Log` warn and error lines; other `warn()` calls print as usual.

`t:expectLog(level, text)` checks any [`Hydrogen.Log`](#logging-with-hydrogenlog) line, e.g. `t:expectLog("info", "bought item=sword")`, and `t:logs(level?)` returns them with their fields. Pass `logLevel = "debug"` in the options to see debug lines.

#### Time and the fake clock

Hydrogen reads time through `Hydrogen.Clock`, and so can your systems. The harness installs a fake clock, so timers only move when the test says so:

```luau
-- In a system: Scheduler runs on Hydrogen.Clock, and the timer stops with the system
function Autosave:start()
	Hydrogen.Scheduler.every(60, function()
		Data:saveAll()
	end):bind(self)
end

-- In a test: five saves, instantly
Hydrogen.test({ systems = { Autosave, Data } }, function(t)
	t:advance(5 * 60)
end)
```

| `Hydrogen.Clock` | Same as |
| --- | --- |
| `Clock.now()` | `os.clock()`: seconds, for durations and cooldowns |
| `Clock.time()` | `os.time()`: Unix seconds, for saved timestamps |
| `Clock.serverNow()` | `workspace:GetServerTimeNow()`: the server's clock, shared by the server and every client |
| `Clock.wait(seconds?)` | `task.wait`; no argument waits for the next frame |
| `Clock.delay(seconds, fn, ...)` | `task.delay`; `fn` can be a thread |
| `Clock.cancel(thread)` | `task.cancel` |
| `Clock.heartbeat(fn)` | `RunService.Heartbeat:Connect(fn)`, returning a function that disconnects it |

- In a game each field is the built-in itself, so `Clock.now()` costs what `os.clock()` does.
- Look the field up when you call it (`Clock.now()`). Don't keep a copy (`local now = Clock.now`): the fake clock replaces the fields, and a copy would keep real time.
- Hydrogen uses it for the server function timeout, the rate limiter's refill and the batching flush. Code that calls `task.wait` or `os.clock` directly keeps real time.
- `t:advance(seconds)` runs every timer due by then, in the order they are due (ties in the order they were scheduled). While a timer runs, `Clock.now()` reads that timer's due time. Then heartbeat fires once with `dt = seconds`, and threads waiting for the next frame resume. A loop that waits 60 seconds runs five times in `t:advance(300)`, and `t:advance(0)` steps one frame. To step frame by frame, loop over `t:advance(1 / 60)`.
- A server function whose client never answers: call `Fire` in `task.spawn`, then `t:advance(10)`.
- When the test ends, threads still waiting on the fake clock are never resumed. The exception is teardown itself: `playerRemoving` and `stop` hooks waiting on the fake clock are stepped until they finish (for up to 5 real seconds), so a save with a retry delay still completes.
- `Clock.serverNow()` is for timestamps one side sends and the other compares, such as when a cast ends: `CastEnds:FireAll(Clock.serverNow() + 2)`, and each client draws the bar from `endsAt - Clock.serverNow()` with no more traffic. Never send `Clock.now()` across; it is per machine. Under the fake clock it starts at the `serverNow` option (default: the `time` option) and moves with `t:advance`. `t.clock:setServerOffset(seconds, player?)` skews it for one fake client, or every client, to test latency: the offset applies inside `t:as(player, fn)` and that client's listeners.
- Outside the harness: `local clock = Hydrogen.Clock.fake({ now = 0 })`, then `clock:advance(seconds)`, `clock:next()` (jump to the next timer), `clock:pending()` and `clock:restore()`. Only one fake clock can be installed at a time.

#### Where Lune differs from Roblox

Lune's Instances aren't the engine's, and mistakes there often surface only as "error in error handling". Hydrogen's Lune runtime and the generated `test/Roblox.luau` install a correct `CFrame.lookAt` (Lune's faces the wrong way for targets with a Z component), and fake characters get Roblox's `Humanoid` defaults. The rest to write around: a `Part`'s `Position` is unreadable until set, so use `CFrame`; real Instances have no `WaitForChild`, `Model:GetPivot` or `Attachment.WorldPosition`; an Attachment's `Position` doesn't update its `CFrame`; one Instance can arrive as different userdata (equal with `==`, missing as a table key); and methods on destroyed Instances error. `docs/ai/testing.md` has the table.

#### Hit detection without spatial queries

`workspace:GetPartBoundsInBox`, raycasts and other spatial queries don't exist under Lune. Put them behind one small system (say `Spatial`, with `charactersInBox(cframe, size, ignore)`), keep the rules in systems that `use` it, and pass `replace = { [Spatial] = fake }` to `Hydrogen.test` so the fake decides what overlaps. Geometry math over `CFrame` and `Vector3` stays in pure functions, which run under Lune as they are. The test then covers the rules (the attacker isn't hit, a blocked hit does nothing); a Studio playtest covers the physics. `docs/ai/testing.md` has the full recipe.

#### Running tests under Lune

Hydrogen ships the runtime its own tests run on, `src/Testing/Lune.luau`. It sets the Roblox globals: `game` with the usual services and a `RunService` stub, `Instance` and the datatypes from `@lune/roblox`, `task`, and a `warn` the harness can capture. It loads modules with a `require` that understands Roblox code: relative and `@self` paths, `.luaurc` aliases, pesde's package links and `require(script.Parent.Module)`. Modules get Roblox-style names such as `src.Systems.Shop`, so a system defined without an id gets the same id as in Studio.

```luau
-- test/run.luau, run with: lune run test/run
local Lune = require("../roblox_packages/.pesde/atk422+hydrogen/<version>/hydrogen/src/Testing/Lune")
Lune.install()

local function require(path: string): any
	return Lune.require(path) -- resolves from this file, like require
end

require("./Shop.spec")
```

- Load it with Lune's own `require`, before any game code.
- `RunService:IsServer()` and `IsClient()` return `false`, so Hydrogen leaves the `Players` service and `BindToClose` alone, and the harness supplies players. Heartbeat never fires: use the fake clock.
- Lune can't run a ModuleScript Instance. Register what one returns with `Lune.modules[moduleScript] = value` (also `_G.instanceModules`); requiring an unregistered one errors.
- Nothing in a game requires this module, so it costs nothing there.

#### Design: why one call

- **Teardown is what tests forget**, and a test that leaks a running network, a loopback or a fake clock breaks the next test, far from the cause. A function scope makes cleanup unconditional. `Hydrogen.harness` covers frameworks that need setup and teardown in hooks, and closes a harness someone forgot.
- **Expectations record deliveries, not `Fire` calls**, because a delivery is what the game sees: middleware, the rate limiter, validation, departed players and the handshake queue all apply. Recording happens in the network runtime behind one nil check per message. A global middleware would have seen data before validation, and would make every message allocate a context and clone its middleware chains.
- **Expectations error** instead of returning booleans, so they work in every framework and in none, and each failure lists what did happen.
- **The fake clock is on by default**, because a test that depends on real time is slow or flaky. Its fields replace the built-ins on the `Clock` table, rather than one wrapper checking a flag, so a game pays nothing. One heartbeat per `advance` keeps `t:advance(3600)` instant; a test that cares about frames steps them itself.

#### The tools underneath

`Hydrogen.test` is built on two tools you can also use on their own: `app:replace` swaps a dependency for a fake, and `Hydrogen.loopback()` stands in for the remotes so client and server systems can talk in one VM. Both work under Lune and in Studio. Used directly, they leave teardown to you.

#### Faking a dependency with `app:replace`

```luau
local Shop = require(Systems.Shop) -- Shop does `local Data = use(DataSystem)`
local DataSystem = require(Systems.Data)

local fakeData = {
	getCoins = function(player)
		return 500
	end,
}

local net = Hydrogen.loopback() -- see below; gives the test players and a fresh network
local app = Hydrogen.App.new()
app:addSystem(Shop)
app:replace(DataSystem, fakeData)
app:start()

-- ... exercise Shop; every Data.getCoins call it makes reaches fakeData ...

app:stop()
net:close()
```

What `replace` does:

- It must be called before `app:start()`. The original is added to the app if it wasn't already.
- The fake takes the original's place in the boot order: its `init`, `start`, `playerAdded`, `playerRemoving` and `stop` run where the original's would have, and the original's hooks don't run. The order comes from the original's dependencies; a fake's own `use` calls don't move it. Errors from the fake's hooks name it `<original> (replaced)`.
- While the app runs, **the original table forwards to the fake**. Dependents keep the table `use` gave them at require time, so `Data.getCoins(...)` and `Data:save(...)` reach the fake. Reads and writes through it (including `self.x = ...` inside the fake's methods) go to the fake. Plain modules that `require` the original directly see the fake too.
- `app:stop()` puts the original back, and so does a boot that errors. Stop each app at the end of the test.
- Only one running app can replace a given system at a time; a second errors with `already replaced by a running app`.
- Don't copy a field out of a dependency in the constructor (`local getCoins = use(Data).getCoins`): that keeps the original function, which a later `replace` can't reach. Keep the table and look fields up when you call them.
- A system whose table is frozen (`table.freeze`) or has a locked metatable can't be replaced.

#### Client and server in one VM with `Hydrogen.loopback`

`Hydrogen.loopback()` replaces the remotes with in-memory ones, so one VM acts as the server and as every client. Open it before `app:start()`, then add both sides' systems, to one app or to a server app and a client app:

```luau
local net = Hydrogen.loopback()
local alice = net:join("Alice")

local app = Hydrogen.App.new()
app:addSystems({ ShopServer, ShopClient })
app:start() -- ShopClient's Buy:Fire("sword") reaches ShopServer as coming from alice

local bob = net:join("Bob")
net:as(bob, function()
	Remotes.Buy:Fire("shield") -- with two clients, say which one is sending
end)

app:stop()
net:close()
```

Loopback methods:

- `net:join(name?)`: add a fake client and return its player. Apps run `playerAdded` for it. Once the network runs, the client does its ready handshake, so events the server sent it before then are delivered, as in a real game.
- `net:leave(player)`: the player leaves. Apps run `playerRemoving`; later sends to the player are dropped.
- `net:players()`: the players still in. `serverEvent:FireAll` and `FireExcept` send to these.
- `net:as(player, fn, ...)`: run `fn` as that client. Client events and functions fired inside it come from `player`. With exactly one client you don't need `as`; with several, a client send outside `as` errors.
- `net:client()`: the client the running code acts as, inside `as` or inside a server event or function handler running on that client. Every fake client shares the same client-side listeners, so this is how a test tells them apart. While the server handles a client's message, it is `nil`: that code runs as the server.
- `net:close()`: everyone leaves, listeners and middleware added since the loopback opened are removed, and the network stops so the next test can start it again. Network names stay registered.

How it differs from real remotes:

- Messages still go through ids, middleware in both directions, schema validation, and the queue and handshake rules above. An invalid payload is dropped with the same warning.
- Delivery is immediate: when `Fire` returns, listeners have already run up to their first yield. Each event handler gets its own thread, so its errors are reported as `[HYDROGEN] Loopback event handler failed` instead of reaching the sender. Function errors reach the caller, as with `InvokeServer`.
- Tables are copied and lose their metatables, as remotes do. Unreliable events are delivered reliably.
- Fake players are tables with `Name`, `DisplayName`, `UserId` (negative), `Parent` and `Kick` (which makes them leave). They aren't Instances, so `player:IsA(...)` and other Instance methods don't exist on them.
- `RunService:IsServer()` and `IsClient()` still return what the host says, so systems that branch on them see the same answer on both sides.
- Opening a loopback starts from an empty network: events queued before it opened, by an earlier test or an app started without a loopback, are dropped. In Studio, open the loopback before any app starts.

Systems are still module singletons: state a system keeps in its own tables lives across tests in the same VM. Reset it in `init`, or use one test file per scenario.

#### Design: why `replace` redirects the original

`use(Other)` runs once, when the dependent module is required, and returns the `Other` table. By the time a test calls `replace`, every dependent already holds that table. Two ways to make them reach a fake were considered:

- **`use` returns a forwarding proxy** whose target can be swapped. Dependents would reach the fake without the original being touched. But every field access from a dependent would go through a metatable in every game, test or not. `self` inside the original's methods would be the proxy, so `self == Data` breaks and writes need forwarding too. And modules that `require` a system without `use` would still see the original.
- **`replace` redirects the original table** (chosen). While the app runs, the original is emptied and given a metatable that forwards reads and writes to the fake; `stop` restores its fields and metatable. Games that never call `replace` pay nothing, and every holder of the table reaches the fake, whether it got it from `use` or `require`. The costs: the original is mutated while the app runs, frozen tables and locked metatables can't be replaced, and functions copied out of a dependency before the swap keep pointing at the original.

**Replacements belong to an app, but act on the whole VM while that app runs.** Systems are constructed once per VM, at require time, so every app shares one `Data` table; a swap can't be visible to one app and not another. An app records its replacements, applies them at `start` and undoes them at `stop`, and two running apps can't replace the same system.

**The dependency graph and network runtime stay module-global.** Moving them into each app wouldn't isolate apps, because the systems and network objects themselves are module singletons. Real isolation would need `define` to build a fresh system per app, so `require(DataSystem)` would return a definition instead of the system, which breaks every game that calls systems directly. For tests, `app:stop()` and `loopback:close()` undo what a test changes instead.

### Receipts

`Hydrogen.Receipts` sets `MarketplaceService.ProcessReceipt` for you and sends each developer product purchase to the handler registered for its product. It grants every purchase once, and answers Roblox `PurchaseGranted` only after the grant is saved. It also handles game pass ownership.

```luau
-- ServerScriptService/Main.server.luau
local app = Hydrogen.App.new()
app:addSystemsFolders(ServerScriptService.Systems)
app:addSystem(Hydrogen.Receipts) -- after the system that saves player data
app:start()
```

```luau
-- ServerScriptService/Systems/Shop.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local DataSystem = require(script.Parent.Data)

local VIP_PASS = 7654321

return Hydrogen.define(function(use)
	local Receipts = use(Hydrogen.Receipts)
	local Data = use(DataSystem)

	Receipts.products({
		[1234567] = function(player, receipt)
			Data.addCoins(player, 100)
		end,
		[1234568] = function(player, receipt)
			if Data.inventoryFull(player) then
				return false -- not now: Roblox offers the receipt again later
			end
			Data.giveItem(player, "Sword")
		end,
	})

	-- Runs once per session for each player who owns the pass: on join, or when they buy it.
	Receipts.gamePass(VIP_PASS, function(player)
		Data.setVip(player, true)
	end)

	local Shop = {}

	function Shop.buyCoins(player: Player)
		Receipts.promptProduct(player, 1234567)
	end

	function Shop.isVip(player: Player): boolean
		return Receipts.owns(player, VIP_PASS) -- yields the first time, then cached
	end

	return Shop
end)
```

What happens to each receipt:

1. Receipts waits until the player is in the server and their purchase record is loaded (up to `loadTimeout`, 30 seconds by default). Receipts usually arrive as a player joins, while their data is still loading.
2. It asks the store whether this purchase was granted before. If it was, it makes sure that grant is saved and answers `PurchaseGranted` without granting again.
3. It calls the product's handler through the store, which records the purchase id in the same save as the grant and returns once that save succeeded. Then it answers `PurchaseGranted` and calls `onGranted` listeners.

It answers `NotProcessedYet` instead, and Roblox offers the receipt again later (usually when the player next joins a server), when:

- the player leaves, isn't loaded within `loadTimeout`, or their record fails to load;
- the handler errors (warned with the traceback) or returns `false` (silently);
- no handler is registered for the product (warned once per purchase). Add the handler and the purchase is granted on the next try;
- the store can't tell whether the purchase was granted;
- the grant's save fails. Receipts retries the save twice first. The purchase stays recorded, so a later try only saves it and never grants it again;
- the server is shutting down.

Rules:

- **Add `Hydrogen.Receipts` to the app**, as with any system you `use`. On the client it binds nothing.
- **One handler per developer product.** Registering a second errors. `product` and `products` return a function that removes the handlers again. Handlers can be registered at any time, usually in the system's constructor.
- **Handlers grant; they don't save.** Change the player's data and return. Saving is the store's job, and the store decides when the purchase counts as granted. Return `false` to decline for now; an error does the same, with a warning. A store backed by your data system can hand the handler the player's data: whatever it passes to `grant(...)` arrives after `receipt`.
- **One receipt at a time per player.** A second receipt for the same player waits for the first. If Roblox offers the same receipt again while the first call is still running, the second call waits for the first and returns its answer.
- **A leaving player's grant in progress finishes first.** Receipts' `playerRemoving` waits (up to 15 seconds) for a grant that has already started, so a system whose `playerRemoving` runs after Receipts' saves data that includes it. `playerRemoving` runs in reverse order, and systems with no dependency between them run in the order they were added, so add `Hydrogen.Receipts` after the system that saves player data.
- **Shutdown** (`app:stop()`, bound to `BindToClose`): receipts that haven't started granting answer `NotProcessedYet`, and grants in progress finish first. Afterwards `ProcessReceipt` stays bound and answers `NotProcessedYet`, so another server grants them.
- **Configure before Receipts starts**, from your main script or a system's `init`. `Receipts.configure(options)` replaces all options:
  - `store`: where granted purchases are recorded. Defaults to `Receipts.dataStore()`.
  - `marketplace`: stands in for `MarketplaceService`, such as `Receipts.fakeMarketplace()` in tests.
  - `loadTimeout`: seconds a receipt waits for its player. Defaults to 30.
- `Receipts.onGranted(function(player, receipt) ... end)` runs after each purchase this server grants, for purchase history or analytics. It runs in its own thread and doesn't affect the answer. It isn't called again when a duplicate receipt is confirmed.

Game passes:

- `Receipts.owns(player, passId)` asks `UserOwnsGamePassAsync` once per player and pass, retrying twice on errors, and caches the answer for the session. An in-game purchase (`PromptGamePassPurchaseFinished`) sets it to `true` without asking. If Roblox can't be reached it returns `false` without caching, so the next call asks again.
- `Receipts.gamePass(passId, handler)` runs the handler for each owner once per session: when they join (checked in the background) or when they buy the pass in game. A pass can have several handlers. `Receipts.gamePasses({ [passId] = handler })` registers several.
- `Receipts.promptProduct(player, productId)` and `Receipts.promptGamePass(player, passId)` show the purchase prompt.

#### Stores

The store is where Receipts records that a purchase was granted. A purchase is granted exactly once only if that record is saved **together with** the grant: both saved, or neither. Saved separately, a crash between the two saves either grants the purchase twice or loses it.

- **`Receipts.dataStore(name?)`** (the default, named `HydrogenReceipts`): one DataStore key per purchase id, written after the handler returns and tagged with the player's UserId. Players who never buy anything cost no requests. Reads and writes are retried twice, and a record still unsaved is tried once more when the player leaves. Because it can't share a save with your game's data, a crash or failed save between your data and this record can grant a purchase twice (your data saved, the record didn't) or lose it (the other way round). Use it when your data lives somewhere Receipts can't reach.
- **`Receipts.fromData(PlayerData)`** (recommended with `Hydrogen.Data`): records the purchase id with the grant through `PlayerData:updateOnce`, so both are in one save. Handlers get the player's draft data after the receipt and change it: `Receipts.product(id, function(player, receipt, data) data.coins += 100 end)`. Configure it with `Hydrogen.Receipts.configure({ store = Hydrogen.Receipts.fromData(PlayerData) })` and add the store to the app.
- **Another data system as the store**: implement `Hydrogen.ReceiptStore` on top of your player data, keeping the processed purchase ids in the player's profile. Keep that list bounded (the last few hundred ids is plenty), and don't let a save go out while `record` is between `grant()` and adding the id. If your data system already has an apply-once update (run a change and record an id in one commit, then save), `record` can wrap it and `isGranted` can return `false`. Return from `record` without calling `grant` when the update reports a duplicate. `save` must still save the player's data and error on failure, because Receipts retries through it when the update's change was committed but its save failed.

```luau
export type ReceiptStore = {
	-- Optional. Yield until the player's record can be read; return false if it failed to load.
	load: ((self, player: Player) -> boolean?)?,
	-- Was this purchase granted already (saved or not)? Error if you can't tell.
	isGranted: (self, player: Player, receipt: Receipt) -> boolean,
	-- Call grant(...), add receipt.PurchaseId to the profile in the same save, and return once
	-- that save succeeded. If grant errors, record nothing and let the error through.
	-- Error if the save fails. Arguments to grant(...) reach the handler after the receipt.
	-- Already recorded and saved? Return without calling grant: Receipts answers PurchaseGranted.
	record: (self, player: Player, receipt: Receipt, grant: (...any) -> ()) -> (),
	-- Make sure an already recorded purchase is saved; return at once if it is. Error if the save fails.
	save: (self, player: Player, receipt: Receipt) -> (),
	-- Optional. The player left and their receipts are done.
	release: ((self, player: Player) -> ())?,
}
```

- **`Receipts.memoryStore()`** keeps records in memory, for tests. `store:failSaves(count)` makes the next saves fail; `store:isSaved(purchaseId)` and `store:savedCount()` let a test check what was recorded.

#### Testing purchases

`Receipts.fakeMarketplace()` stands in for `MarketplaceService` and plays Roblox's part, so purchases can be tested under Lune or in Studio without spending Robux:

```luau
local market = Hydrogen.Receipts.fakeMarketplace()
local store = Hydrogen.Receipts.memoryStore()
Hydrogen.Receipts.configure({ marketplace = market, store = store })

local net = Hydrogen.loopback()
local alice = net:join("Alice")
local app = Hydrogen.App.new()
app:addSystems({ Shop, Hydrogen.Receipts })
app:start()

local decision, receipt = market:purchase(alice, 1234567) -- "PurchaseGranted"
market:deliver(receipt)         -- the same receipt again: answered, not granted twice
store:failSaves(10)
market:purchase(alice, 1234567) -- "NotProcessedYet", and it stays pending
store:failSaves(0)
market:retryPending(alice)      -- what Roblox does when Alice rejoins
market:buyGamePass(alice, VIP_PASS)
```

The fake also has `pending(player?)`, `setOwnsGamePass(player, passId, owns)`, `failOwnershipChecks(count)`, `ownershipChecks` (a count) and `prompts` (every prompt shown). With an injected marketplace, `ProcessReceipt` returns the strings `"PurchaseGranted"` and `"NotProcessedYet"`; the real `MarketplaceService` gets the `Enum.ProductPurchaseDecision` items.

To fake Receipts itself in a system's test, use `app:replace(Hydrogen.Receipts, fake)` like any other system.

#### Why it's designed this way

- **A system, not a function you call.** `ProcessReceipt` can be set only once per server, but many systems sell things. Receipts owns the callback and systems register handlers. Being a system also gives it the player and shutdown hooks it needs to wait for loading and to finish grants before data is saved.
- **The store decides when a purchase is granted.** Recording a purchase id anywhere other than with the grant leaves a window where one is saved and the other isn't. Only your data system can save both together, so Receipts hands it the grant to run instead of granting first and recording afterwards. The DataStore default exists so Receipts works with no setup, and its limits are stated above.
- **When unsure, `NotProcessedYet`.** Roblox keeps offering an unacknowledged receipt, so `NotProcessedYet` only delays a purchase, while a wrong `PurchaseGranted` loses it. Because the store keeps the record, a later try can't grant twice.
- **Waiting, not refusing, while the player loads.** Pending receipts are offered as the player joins, exactly when their data is still loading. Refusing them would leave the purchase until the player's next visit.
- **One receipt per player at a time.** Grants for the same player can't interleave with each other's saves, so the reasoning above holds for each receipt.

### Logging with `Hydrogen.Log`

`Hydrogen.Log.of(system)` gives a system a logger. Its lines carry the system's name and optional fields:

```luau
return Hydrogen.define(function()
	local Shop = {}
	local log = Hydrogen.Log.of(Shop) -- named after the system's id, "Shop"

	function Shop.buy(player: Player, item: string, price: number)
		log:info("bought", { player = player.Name, item = item, price = price })
	end

	return Shop
end)
```

```
[Shop] bought item=sword player=Alice price=50
```

Loggers have `debug`, `info`, `warn` and `error`. `error` only logs; it doesn't throw. Debug and info lines go to `print`, warn and error lines to `warn`. Debug and error lines say so (`[Shop] debug: ...`, `[Shop] error: ...`). Fields are sorted and written as `key=value`, with strings quoted only when they contain spaces.

- `Hydrogen.Log.of("Matchmaking")` names a logger without a system. The same name or system always gives the same logger.
- `Hydrogen.Log.of(Shop, player)` adds `player=<Name>` to every line, and `log:with({ round = 3 })` adds any fields you like. Both share the parent's name and level.
- `log:enabled("debug")` tells you whether a line would be emitted.

#### Levels

The levels are `debug`, `info`, `warn` and `error`, plus `"off"`. By default Studio shows everything from `debug` up and live servers from `info` up. Change the global level, or one name's:

```luau
Hydrogen.Log.setLevel("warn")                 -- everything: warnings and errors only
Hydrogen.Log.setLevel("debug", "Matchmaking") -- except this name
Hydrogen.Log.setLevel(nil, "Matchmaking")     -- back to the global level
log:setLevel("debug")                         -- the same, from a logger
```

A filtered-out line costs one comparison. Luau still evaluates the arguments, though, so keep expensive work out of them. Pass a function and it runs only if the line is emitted, or guard per-frame code with `enabled`:

```luau
log:debug(function()
	return `path recomputed`, { nodes = #path, cost = pathCost(path) }
end)

if log:enabled("debug") then
	log:debug("tick", { dt = dt })
end
```

#### Sinks

Every emitted line goes to each sink as a frozen table: `level`, `tag`, `message`, `fields`, `text` (exactly what the console prints) and `at` (`Hydrogen.Clock.now()`).

- `Hydrogen.Log.console` is the default sink. Remove it with `Hydrogen.Log.removeSink(Hydrogen.Log.console)` to send lines only to your own sinks.
- `Hydrogen.Log.buffer(capacity?)` keeps the last 200 lines (or `capacity`) for a debug overlay: `buffer:lines(minLevel?)`, `buffer:total()`, `buffer:clear()`, `buffer:stop()`.
- `Hydrogen.Log.addSink(function(line) ... end)` sends lines anywhere, e.g. queued for an analytics or HTTP endpoint your game controls. It returns a function that removes the sink.

A sink that errors is reported once, as `[HYDROGEN] A log sink failed ...`, and keeps receiving lines; logging carries on for every other sink. Your sinks run in their own thread, so one that yields doesn't hold up the code that logged. Still, queue lines and send them from your own loop rather than making a request per line.

Hydrogen's own `[HYDROGEN]` warnings and the `Hydrogen.logger()` traffic lines go through the same sinks, with the tag `HYDROGEN`.

#### Rate limiting

```luau
Hydrogen.Log.rateLimit({ burst = 5, window = 10 })
```

With it on, identical lines (same level and text) beyond `burst` in `window` seconds are dropped. When the window ends, one summary line follows, e.g. `[Physics] part fell out of the world (repeated 595 more times in 10s)`. It's off by default; `Hydrogen.Log.rateLimit(false)` turns it off again.

#### In tests

`Hydrogen.test` records every line. `t:expectLog(level, text)` passes when a line at that level contains `text`, and `t:logs(level?)` returns the lines. Warn and error lines count as warnings for `t:expectWarning` and `t:expectNoWarnings`. Lune runs as a live server, so debug lines are off by default. Pass `logLevel = "debug"` in the test options to see them. Levels, sinks and the rate limit are put back when the test ends.

#### Why it's designed this way

- **`Log.of(system)`, like `Scope.of(system)`.** A system's name is already its id, so there's nothing to type twice. The name is looked up on the first line, so you can make the logger inside the constructor, before `define` returns. (`for` is a Luau keyword, so the function can't be called `Log.for`.)
- **The cost check is one comparison.** Each logger caches the lowest level it emits. Changing a level clears those caches, and each logger works its threshold out again on its next line. Levels change rarely and lines are logged often, so the work goes on the rare side.
- **Laziness through functions, not format strings.** A `printf`-style API would also defer formatting. It would split the message from the values, though, and couldn't defer computing them. A function defers everything, and `enabled` covers the per-frame case where even a closure is too much.
- **`key=value` fields instead of interpolation.** Fields stay structured for sinks (an overlay can filter by `player`, analytics can count `item`), and the printed form is still one readable line.
- **Sinks can't break the caller.** Logging is called from everywhere, including error paths. A sink that throws or yields would turn a log line into a new bug at the worst moment, so each sink is isolated and reported once.
- **Rate limiting is opt-in.** Dropping lines hides information, so you decide when the trade is worth it. When it's on, the summary line keeps the count honest.
### Components

`Hydrogen.Component` binds code to instances with a CollectionService tag. A component constructs one object, with its own scope, for every tagged instance in the game. It destroys the object when the instance is untagged, destroyed or streamed out. Tag parts in Studio and the code finds them wherever they are.

```luau
-- ServerScriptService/Systems/Coin.luau
local Players = game:GetService("Players")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local WalletSystem = require(script.Parent.Wallet)
local gt = Hydrogen.gt

return Hydrogen.Component.new("Coin", function(use)
	local Wallet = use(WalletSystem)

	return {
		ancestors = { workspace },                     -- leave the template in ReplicatedStorage alone
		attributes = gt.table({ Value = gt.number() }), -- typed, and waited for
		construct = function(coin: BasePart, scope: Hydrogen.Scope, attributes)
			scope:connect(coin.Touched, function(hit: BasePart)
				local player = hit.Parent and Players:GetPlayerFromCharacter(hit.Parent)
				if player then
					Wallet.give(player, attributes.Value)
					coin:Destroy()
				end
			end)
			return { value = attributes.Value } -- the object: Coin:get(coin)
		end,
	}
end)
```

A component is a system, so the systems folder picks it up like any other (`app:addSystemsFolders(ServerScriptService.Systems)`). Its id, which every `[HYDROGEN]` message about it uses, is `"Coin component"` when the module is named after the tag, and `"<Module> (<tag> component)"` otherwise, so two components on one tag can be told apart. Pass `{ id = "CoinVfx" }` as a third argument to name it yourself. Other systems `use` it and look objects up:

```luau
Coin:get(instance)          -- the object, or nil
Coin:has(instance)          -- constructed?
Coin:all()                  -- every object
Coin:instances()            -- every instance with an object
Coin:wait(instance, 5)      -- yields until constructed, or nil after 5 seconds
```

Options:

- `construct(instance, scope, attributes)` (required) runs for each instance, in its own thread, so it may yield. Add cleanup to `scope`. What it returns is the object. If it returns nothing, the instance is the object.
- `destroy(object, instance)` runs before the scope is destroyed, for objects whose `construct` returned. Use it for work that needs the object, such as saving its state. It must not yield.
- `ancestors = { workspace }` binds only instances under one of these. It is checked again when an instance moves.
- `children = { "Hitbox" }` or `{ Hitbox = "BasePart" }` waits for these direct children before constructing.
- `attributes = gt.table({ ... })` (or the plain table `{ Value = gt.number() }`) waits until the attributes match a GreenTea schema. `construct` gets them typed, and the table stays current while the object exists.
- `timeout` sets the seconds to wait for children or attributes before warning (default 5). Waiting goes on after the warning.

Rules:

- **An object exists exactly while** the instance has the tag, is in the DataModel, is under `ancestors`, has its required children and has valid attributes. When any of those stops, the object is destroyed (its `destroy`, then its scope). When they all hold again, `construct` makes a new object with a new scope. Objects are never reused.
- **Streaming:** streaming out parents the instance to nil, which destroys its object. Streaming back in constructs a new one, so a part can be constructed many times in a session. Keep state that must survive on the server or in attributes. For models with required children, use `ModelStreamingMode` `Atomic` or `Persistent`.
- **Lifecycle:** a component binds during its own `start`, after the systems it `use`s have started, and before the systems that use it start. `app:stop()` destroys every object (in the component's `stop` hook) and stops listening. A failed boot does too.
- **Errors stay contained.** A `construct` that errors is warned with the instance's full name. Its scope is cleaned, and every other instance and component carries on. It is tried again when the instance re-qualifies (retagged, streamed back in). If an instance leaves while its `construct` is still yielding, the thread is cancelled and `destroy` isn't called.
- **Signal order doesn't matter:** every signal re-checks the instance from scratch, so deferred signals and tags or parents changing in any order end in the right state.
- **Either side, or both.** A component runs in the app you add it to. Put client visuals in the client's systems and server logic in the server's. Several components can share a tag.
- **Cost:** CollectionService signals, plus per-instance connections only for the options you use (`AncestryChanged`, `ChildAdded`/`ChildRemoved`, `AttributeChanged`). There is no per-frame work.
- **Testing:** under `Hydrogen.test` components don't use signals. They re-check tagged instances at the end of every `t:advance`, so tag, parent and attribute changes are seen deterministically in Studio and under Lune. Use the real Instance API, then `t:advance(0)`. Lune's Instances have tags and attributes but no events (`Touched` and so on), so test event-driven `construct` code in Studio.

#### Why it's designed this way

- **A component is a system.** It gets the app's lifecycle with nothing new to learn. It starts after what it uses, is torn down on `app:stop()`, is collected from systems folders, and can be faked with `replace`. Dependencies come through `use`, as everywhere else in Hydrogen.
- **Functions, not classes.** `construct` returns whatever object you want, so its type is inferred, with no `self` annotations or metatables to set up. The scope replaces the cleanup boilerplate that class-based components usually need.
- **One rule for when an object exists.** Tags, parents, streaming, children and attributes all feed the same check. "Exists while all conditions hold, new object every time" covers churn, streaming and partial loads without special cases. Re-checking from scratch on every signal makes deferred signal ordering irrelevant.
- **Warn, don't give up.** A missing child is usually a slow stream or a broken template. Warning after the timeout points at the problem, and waiting on means a late arrival still works.
- **Polling in tests.** Lune's Instances have no signals, and Studio's are deferred. Re-checking on `t:advance` makes component tests deterministic in both, while a game pays only for signals.

### Input

`Hydrogen.Input` maps keys to actions on the client. You declare each action once, with its bindings for keyboard and mouse, gamepad and touch. Game code then reacts to `Jump` or `Move`, never to `Enum.KeyCode.Space`.

```luau
-- ReplicatedStorage/Client/Controls.luau (required by client systems)
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Input = Hydrogen.Input
local Key = Enum.KeyCode

local Gameplay = Input.context("Gameplay")
local Menu = Input.context("Menu", { priority = 10, sink = true, enabled = false })

return {
	Gameplay = Gameplay,
	Menu = Menu,
	Jump = Gameplay:button("Jump", { Key.Space, Key.ButtonA }),
	Sprint = Gameplay:button("Sprint", { Key.LeftShift, Key.ButtonL3 }),
	Interact = Gameplay:button("Interact", { Key.E, Key.ButtonX }, { touch = true }),
	Ability1 = Gameplay:button("Ability1", { Key.Q, Key.ButtonL1 }, { touch = { text = "Dash" } }),
	Move = Gameplay:vector2("Move", { { up = Key.W, down = Key.S, left = Key.A, right = Key.D }, Key.Thumbstick1 }),
	Aim = Gameplay:vector2("Aim", { Enum.UserInputType.MouseMovement, Key.Thumbstick2 }),
	Zoom = Gameplay:axis("Zoom", { Enum.UserInputType.MouseWheel, { positive = Key.I, negative = Key.O } }),
	Close = Menu:button("Close", { Key.Backspace, Key.ButtonB }),
}
```

```luau
-- A client system
local Controls = require(ReplicatedStorage.Client.Controls)

function Movement:start()
	local scope = Hydrogen.Scope.of(self)
	scope:add(Controls.Jump:onBegan(function()
		humanoid.Jump = true
	end))
	scope:add(Controls.Interact:onHold(0.5, openDoor))
	scope:connect(RunService.RenderStepped, function(dt)
		local walkSpeed = if Controls.Sprint:held() then 24 else 16
		local move: Vector2 = Controls.Move:value()
		-- ...
	end)
end
```

Action kinds:

| Kind | `value()` | Binds |
| --- | --- | --- |
| `button` | `boolean` | Keys, mouse buttons, gamepad buttons and triggers. `{ key = S, modifiers = { LeftControl } }` for a combination. |
| `axis` | `number`, -1 to 1 (0 to 1 from a trigger) | Keys (1 while held), `{ positive = E, negative = Q }`, triggers, a stick axis `{ key = Thumbstick2, axis = "y" }`, `MouseWheel` |
| `vector2` | `Vector2`, up to length 1 | `{ up, down, left, right }`, thumbsticks, `MouseMovement` (a delta) |

`Input.button`, `Input.axis` and `Input.vector2` put an action in the default context (priority 0, always enabled), for games that don't need contexts. Any binding takes `scale` (for example `-1` to invert).

Every action has the same events, and each returns a disconnect function for `scope:add`:

| Method | Does |
| --- | --- |
| `onBegan(fn(value))` | A press starts, or the value leaves zero. |
| `onEnded(fn())` | The last press is released, or the value returns to zero. |
| `onChanged(fn(value, previous))` | Every change of `value()`, including the begin and the end. |
| `onHold(seconds, fn())` | Once per press, after it has been held for `seconds`. |
| `value()`, `held()` | Current value, and whether it is pressed or non-zero. |

#### Contexts

A context groups actions that are enabled together: gameplay, a menu, a vehicle. When a key is pressed, enabled contexts see it from the highest priority down. A context with `sink = true` keeps the keys it binds from reaching lower-priority contexts. Contexts with the same priority all receive a key.

```luau
function Inventory:open()
	local scope = Hydrogen.Scope.new("Inventory")
	Controls.Menu:enableFor(scope)
	Controls.Gameplay:disableFor(scope) -- no walking while the inventory is open
	self.scope = scope
end

function Inventory:close()
	self.scope:destroy() -- both undone
end
```

`enable()`, `disable()` and `setEnabled(on)` set a context's own state. `enableFor(scope?)` and `disableFor(scope?)` are counted: two open menus keep `Menu` enabled until both close. A `disableFor` that is still open wins over everything else. Each returns its undo function, which also runs when the scope is destroyed.

#### Rebinding and saving

```luau
local ok, conflicts = Controls.Jump:rebind(Enum.KeyCode.F)
if not ok then
	-- conflicts[1].action.name == "Interact": ask the player, then:
	Controls.Jump:rebind(Enum.KeyCode.F, { conflict = "swap" })
end

-- "Press a key" prompt: the next keyboard press is taken, and no action sees it.
Input.captureKey(function(key)
	Controls.Sprint:rebind(key, { conflict = "swap" })
end, "keyboard")

-- Save and load (where to store them is up to you, e.g. a Hydrogen.Data field via a clientEvent).
Input.onBindingsChanged(function()
	Remotes.SaveBindings:Fire(Input.saveBindings())
end)
Input.loadBindings(savedFromServer)
```

- `rebind(binding, { slot?, conflict? })` replaces the `slot`-th binding (1 by default) of the binding's device (keyboard or gamepad). A slot past the end adds a binding. If another action would fire from the same press, `conflict` decides what happens: `"reject"` (the default) changes nothing and returns `false` with the conflicts, `"swap"` gives the other action the old binding, `"unbind"` removes the other action's binding, and `"allow"` keeps both. In a composite such as WASD, only the clashing direction changes: `"swap"` puts the old key there, and `"unbind"` removes just that direction. If the other action can't use the old binding, `"swap"` removes the clashing binding instead.
- Two bindings conflict when one press would trigger both: the same key and the same modifiers, or a key that is part of a composite. Contexts count when both could be enabled at once and neither sinks the other. A disabled context still counts, because it can be enabled later.
- `conflicts(binding, slot?)` returns those conflicts without changing anything, for marking clashes in a settings menu. `unbind(device, slot?)` and `resetBindings()` (or `Input.resetBindings()` for every action) do what their names say.
- `Input.saveBindings()` returns only the actions the player changed: `{ Jump = { keyboard = { "F" } } }`. Keys are saved as names, so the table can go straight into a DataStore. Players who never rebound an action get new defaults from game updates.
- `Input.loadBindings(saved)` resets everything to the defaults, then applies `saved`. It skips actions that no longer exist without a warning. It skips invalid bindings, and bindings saved under the wrong device, with a warning. If none of a device's saved bindings are valid, that device keeps its defaults. An empty list means the player unbound the device.

#### Devices, glyphs and touch

```luau
Input.device() -- "keyboard" (keyboard and mouse), "gamepad" or "touch": whatever the player used last
Input.onDeviceChanged(function(device, previous) end)

-- A prompt that always shows the right key: called now, and again on device switch or rebind.
scope:add(Controls.Interact:observeGlyph(function(glyph)
	label.Text = if glyph then glyph.text else ""
	icon.Image = if glyph and glyph.image then glyph.image else ""
end))

-- Your own icon set: return a Glyph, or nil for Hydrogen's.
Input.glyphs(function(key, device)
	local image = MyIcons[device][key]
	return if image then { key = key, device = device, text = key, image = image } else nil
end)
```

A glyph is `{ key, device, text, image? }` for the action's first binding on the device. `text` is readable: `"E"`, `"Shift"`, `"Ctrl+S"`, `"W/S/A/D"`, `"LMB"`. In a game, letter keys follow the player's keyboard layout, and gamepad buttons get the platform's button images (`UserInputService:GetImageForKeyCode`). On touch, a glyph describes the action's on-screen button, or is `nil` if it has none.

Touch:

- `touch = true` on a button action gives it an on-screen button. The button is made the first time the player uses touch. It sits in a grid above Roblox's jump button, and shows only while its context is enabled. `touch = { text, image, position, size }` styles it, and setting `position` or `size` takes it out of the grid.
- `action:touchButton()` returns the made button, so you can restyle or reparent it.
- For full control, make your own `GuiButton` and call `Input.bindButton(action, button, scope?)`. The action stays pressed while any finger is on the button, including a finger that slid off before lifting.
- For a custom joystick or any other control, `Input.source(action)` returns a handle with `set(value)`, `press()`, `release()` and `destroy()`.

#### Input buffering

In combo combat, a press that lands during an attack's recovery should fire when the recovery ends instead of being lost. Give the button a `buffer` in seconds, and ask for the press with `consumeBuffered()` when the action is ready:

```luau
local M1 = Gameplay:button("M1", { Enum.UserInputType.MouseButton1, Key.ButtonR1 }, { buffer = 0.15 })

local recovering = false
local function tryAttack()
	if recovering or not M1:consumeBuffered() then
		return -- busy: a press now stays usable for 0.15 s
	end
	recovering = true
	swing()
	Hydrogen.Clock.delay(0.4, function()
		recovering = false
		tryAttack() -- takes a press made in the last 0.15 s of recovery
	end)
end
scope:add(M1:onBegan(tryAttack))
```

- Each press that begins the action is remembered with `Hydrogen.Clock.now()`, so the fake clock drives it in tests. A newer press replaces an older one.
- `consumeBuffered()` returns `true` if that press is at most `buffer` seconds old and nobody has taken it, and clears it either way. It fires nothing and nothing runs per frame.
- The press is remembered before `onBegan` listeners run. Call one function from both `onBegan` and the end of recovery, as above, so the press that started an attack is taken and doesn't fire a second one.
- Only presses that reach the action count: presses sunk by a higher-priority context, presses while its context is disabled, holding the button and typing in a TextBox are not buffered. Disabling the action's context clears its buffered press, so a click from before a menu opened doesn't attack when it closes.
- Only buttons take `buffer`. `consumeBuffered()` on an action defined without one errors and says to add it.

#### Rules

- **Client only.** `Hydrogen.Input` listens to `UserInputService` once the first action is defined on a client. On the server, definitions work, so a shared module can define them, but nothing fires. The first listener registered on the server warns.
- **Typing and UI don't trigger actions.** Presses that Roblox marks as game-processed (typing in a TextBox, clicking a GuiButton) begin nothing. Releases always count, so nothing stays stuck. A stick that steers UI selection reads as zero. When the window loses focus, every key and stick is released.
- **Disabling a context, or sinking its keys, ends its held actions.** Re-enabling doesn't press a button that is still held, so closing a menu with Space held doesn't jump. Axes resume from what is held, so walking continues when a menu closes over a held W.
- **Modifiers:** `Ctrl+S` fires only the binding with the most modifiers held, not a plain `S` button binding. Either Ctrl, Shift or Alt counts. Releasing the modifier first keeps the action held until its key is released. Composites ignore modifiers, so Ctrl+S still moves backwards.
- **Mouse deltas** (`MouseMovement`, `MouseWheel`) last until the end of the frame they arrived in. Read them in `onChanged`, or before Heartbeat (RenderStepped, `BindToRenderStep`).
- **Names are unique** across contexts, because saved bindings use them. `"Default"` is taken by the default context.
- **Roblox's own controls are separate.** Sinking a key stops Hydrogen actions only. To stop the default character controls while a menu is open, disable them through the PlayerModule.
- Thumbsticks use a radial dead zone (0.15, rescaled so movement starts smoothly). `Input.configure({ deadzone = 0.2 })` changes it everywhere, and `{ deadzone = ... }` on an axis or vector2 changes it for one action.
- Listeners run in order of context priority, then definition. A listener that errors is warned about, and one that yields doesn't hold up the others.

#### Testing input

`Input.simulate` produces input the way a device would, and it goes through contexts, sinking and bindings like real input. `Hydrogen.test` calls `Input.reset()` when a test ends.

```luau
Hydrogen.test({ systems = { Movement } }, function(t)
	Input.simulate.press(Enum.KeyCode.LeftShift)
	Input.simulate.move(Enum.KeyCode.Thumbstick1, Vector2.new(0, 1)) -- also switches the device to gamepad
	t:advance(0.1)
	-- assert on your system...
	Input.simulate.release(Enum.KeyCode.LeftShift)
	Input.simulate.tap(Enum.KeyCode.E)
	Input.simulate.move(Enum.UserInputType.MouseMovement, Vector2.new(5, 0)) -- gone after t:advance(0)
	Input.simulate.device("touch")
end)
```

`Input.reset()` releases everything, restores every default binding and every context's starting state, sets the device back to `"keyboard"`, and drops listeners and touch buttons. It keeps the definitions, like `State.reset()`. To test touch buttons under Lune, call `Input.configure({ touchParent = Instance.new("Folder") })`: the buttons are made there, though Lune's Instances can't fire their events. Drive `Input.bindButton` with a fake button instead.

#### Why it's designed this way

- **Hydrogen routes input itself, on top of `UserInputService`, instead of building on the Input Action System.** Roblox's `InputContext` / `InputAction` / `InputBinding` instances bring priorities, sinking and touch `UIButton`s, but they don't cover everything this API needs. `InputBinding:Fire` can simulate input inside Roblox, but Lune can't run the engine side at all, so headless tests would have nothing to drive. They have no conflict detection, no saved binding format, and no defined behavior for a key held while its context changes. With them, the code that decides which action fires would only run inside Roblox, so tests would check a stand-in instead. With one router in Luau, the same code runs live and under `Input.simulate`, and every rule above is tested. ContextActionService was ruled out for the same reasons, and because its touch buttons are hard to style. The raw input source sits behind three calls (`press`, `release`, `move`), so a backend for the Input Action System can be added later without changing the API. The cost is that sinking doesn't reach Roblox's default controls (see Rules).
- **Actions belong to one context, and names are global.** A binding table keyed by action name serializes without ids. A conflict is then always between two named actions the player can see.
- **Counted `enableFor` / `disableFor` next to plain `enable` / `disable`.** Overlapping UIs that toggle a shared context are the usual source of "controls stuck off" bugs. Counting fixes that, and tying the count to a scope makes it impossible to forget to undo. The plain methods stay simple for games with one menu.
- **Buttons don't re-press on re-enable, but axes resume.** A jump or a shot fired by closing a menu is a bug. Stopping while you hold W is one too.
- **Saved bindings are a diff, as plain data.** Saving only what the player changed means fixing a default reaches everyone who didn't rebind it. Names instead of EnumItems fit in a DataStore as they are.
- **Touch buttons are made on first touch.** Keyboard and gamepad players never pay for them. The default grid is one line of code, `touchButton()` gives access to the made button, and `bindButton` / `source` give full control.
- **No per-frame work when idle.** Keys are routed when they change, through a per-key cache cleared on context or binding changes. The only frame callback runs while the mouse is moving, to clear deltas.

### Guards

`Hydrogen.rateLimit` limits how much a player sends. `Hydrogen.Guards` enforces game rules on what they send: cooldowns, roles and permissions, range checks and your own predicates. Each guard is an ordinary middleware, so it goes on an object with `:Use()` or `:UseRequest()`, or on everything with `Hydrogen.useMiddleware`. A rejected event is dropped. A rejected function request errors back to the client with the reason.

```luau
-- ReplicatedStorage/Network/Combat.luau (shared)
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Fireball = Hydrogen.clientEvent("Fireball", gt.Vector3()),
	Ban = Hydrogen.clientFunction("Ban", gt.args(gt.number()), gt.returns(gt.boolean())),
}
```

```luau
-- ServerScriptService/Systems/Combat.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Combat = require(ReplicatedStorage.Network.Combat)
local Guards = Hydrogen.Guards

-- Roles are defined once, at module top level.
Guards.defineRole("admin", Guards.userIds({ 12345, 67890 }))
Guards.defineRole("mod", Guards.groupRank(4242, 200), "admin") -- rank 200+, or any admin
Guards.definePermission("ban", { "admin", "mod" })

local fireballCooldown = Guards.cooldown(5, { name = "Fireball", charges = 2 })

return Hydrogen.define(function()
	local CombatSystem = {}

	function CombatSystem:init()
		Combat.Fireball:Use(Guards.all(
			Guards.range(60),             -- the target is within 60 studs (plus slack)
			fireballCooldown:guard()      -- 2 charges, each back 5 s after it's used
		))
		Combat.Fireball:On(function(player, target)
			-- only runs for fireballs that passed every guard
		end)

		Combat.Ban:UseRequest(Guards.permission("ban", {
			onReject = function(context, reason)
				warn(`{context.player} tried to ban: {reason}`)
			end,
		}))
		Combat.Ban:On(function(player, userId)
			return true
		end)
	end

	return CombatSystem
end)
```

A client that calls `Ban` without the permission gets the error `[HYDROGEN] Ban request rejected: missing permission "ban"`.

#### Cooldowns

`Guards.cooldown(seconds, options?)` makes a per-player cooldown. Options:

- `name: string?`: shown in reasons, e.g. `Fireball is on cooldown (2.5s left)`.
- `charges: number?`: uses that can be stored up. Each comes back `seconds` after it was used, one at a time. Defaults to 1.
- `gap: number?`: the shortest time between two uses, even with charges left.
- `group: { Cooldown }?`: other cooldowns this one also needs ready and also uses. Give every ability the same global cooldown, or make potions share one.

`cooldown:guard(options?)` is the middleware. Game code can use the same cooldown outside middleware, on the server or to predict on the client:

```luau
local global = Guards.cooldown(1)
local potion = Guards.cooldown(30, { name = "Potion", group = { global } })

if potion:use(player) then       -- uses it if ready; false and no change otherwise
	heal(player)
end
potion:ready(player)              -- boolean
potion:remaining(player)          -- seconds until ready, 0 when ready
potion:charges(player)            -- charges left (this cooldown only)
potion:reset(player)              -- every charge back; reset() for everyone
```

A player's cooldowns are cleared when they leave.

#### Roles and permissions

A role is one or more sources, and a player has it when any source says so:

- `Guards.userIds({ ... })`: these UserIds.
- `Guards.groupRank(groupId, minRank)`: rank `minRank` or higher in the group.
- `Guards.gamePass(passId)`: owns the game pass, through `Hydrogen.Receipts.owns`. Add `Hydrogen.Receipts` to the app so ownership is cached and in-game purchases count straight away.
- A function `(player) -> boolean?`. Return `nil` to mean "no, but ask again next time".
- Another role's name, e.g. `"admin"` above, so admins are mods too.

`Guards.hasRole(player, role)`, `Guards.can(player, permission)` and `Guards.rolesOf(player)` work anywhere on the server. The first check for a player and role can yield, for a group rank or a game pass. The answer is then cached for the session, and checks made while it resolves wait for the same answer. When something changes, call `Guards.invalidate(player)`, or `Guards.invalidate()` for everyone. A resolver that errors is warned about and counts as no. That answer isn't cached. Cached answers are dropped when the player leaves.

#### Range checks

`Guards.range(studs, options?)` drops a message when its target is more than `studs` from the sender's character. The target is argument `arg` (default 1), or what `target = function(player, ...) ... end` returns. It can be a `Vector3`, `CFrame`, `BasePart`, `Model`, `Attachment` or `Player`. Anything else is rejected as an invalid target, including NaN and infinite positions. A player without a character is rejected too.

Positions on the server lag behind what the client saw, so every check allows `slack` extra studs, 4 by default (a quarter second at the default WalkSpeed). Set it per guard with `slack`, or for every guard with `Guards.configure({ slack = 6 })`. `Guards.inRange(player, target, studs, slack?)` and `Guards.distance(player, target)` do the same check from game code. The character's position comes from its `HumanoidRootPart`, or its `PrimaryPart`. `Guards.configure({ position = function(player) ... end })` replaces that lookup, e.g. for a custom character or in tests.

#### Timestamps

When a client stamps an action with `Hydrogen.Clock.serverNow()` and the server uses the stamp to settle a contested moment (who blocked first), a cheating client could backdate it. `Guards.timestamp(options?)` drops a message whose stamp (argument `arg`, default 1, or what `timestamp = function(player, ...) ... end` returns) is in the future by more than `future` (0.05 s), or older than the sender's ping plus `tolerance` (0.2 s). The ping comes from `Player:GetNetworkPing()` and is capped at `maxPing`, 1 second by default, so lagging on purpose can't widen the window further. Set the cap per guard with `maxPing`, or for every timestamp guard with `Guards.configure({ maxPing = 0.5 })`. `Guards.configure({ ping = function(player) ... end })` replaces the ping source, for example in tests, and `Guards.ping(player)` reads it. Test with a skewed fake client: `t.clock:setServerOffset(-1, player)` makes that player's stamps a second old.

#### Custom checks and combining guards

`Guards.check(function(player, ...) return ok, reason end)` makes a guard from a function. It gets the raw arguments, before schema validation, so check types before using them. An error in it counts as a rejection and is warned about.

`Guards.all(a, b, ...)` passes when every guard passes, and only uses its cooldowns once everything else passed, so a failed role check doesn't cost a charge. `Guards.any(a, b, ...)` passes when any guard does. `Guards.any(Guards.role("admin"), cooldown:guard())` lets admins skip a cooldown.

Every guard takes `{ reason = "...", onReject = function(context, reason) end }`. `reason` replaces the text the client gets. `onReject` runs for each message it rejects, in its own thread, e.g. to log or kick. `Guards.onReject(fn)` runs for every rejection, from any guard, and returns a function that removes it.

#### Testing guards

Guards read time through `Hydrogen.Clock`, so `Hydrogen.test`'s `t:advance` runs cooldowns out. Fake players have no `GetRankInGroup` and no character. Use function roles or set `GetRankInGroup` on the fake player, and point `Guards.configure({ position = ... })` at a table. Call `Guards.resetConfiguration()` afterwards.

```luau
Hydrogen.test({ systems = { CombatSystem }, players = { "Alice" } }, function(t, alice)
	Guards.configure({ position = function() return Vector3.zero end })
	Combat.Fireball:Fire(Vector3.new(10, 0, 0))
	Combat.Fireball:Fire(Vector3.new(10, 0, 0))
	Combat.Fireball:Fire(Vector3.new(10, 0, 0)) -- no charge left: dropped
	t:expect(Combat.Fireball):firedTimes(2)
	t:advance(5)
	Combat.Fireball:Fire(Vector3.new(10, 0, 0))
	t:expect(Combat.Fireball):firedTimes(3)
end)
Guards.resetConfiguration()
```

#### Why it's designed this way

- **Guards are plain middleware.** They use the same `:Use` / `:UseRequest` / `useMiddleware` as everything else, so there's nothing new to wire up, and onion ordering works the same way. `Guards.all` and `Guards.any` find each guard's rules through a weak table keyed by the function.
- **Server-side, incoming only.** Guards act on what the server receives from a player and pass everything else through, so putting one on a shared object, or globally, is safe.
- **Reasons for functions, silence for events.** A function caller is waiting, so it gets a clear error rather than a timeout. An event has no reply, so it's dropped.
- **Cooldowns are used last, and all at once.** Every other check runs first. Then every cooldown is checked and used in one step that can't yield, so a failing role check costs nothing and two messages can't take the last charge.
- **Fail closed.** A predicate or resolver that errors denies the message, and a role answer that couldn't be worked out isn't cached.
- **Cheap on hot paths.** A cooldown is one number per player. A cached role check is two table lookups. Nothing allocates per message unless it's rejected. Leave tracking starts the first time a guard stores something for a player, so a game that never uses Guards pays nothing.

### Commands

`Hydrogen.Commands` gives the game in-game commands: `give me sword 5`, `kick bob`, `/team red`. Each system registers its commands next to its own code. The server parses the arguments, checks permissions and runs the command, and the output goes back to whoever typed it. On the client there's an optional console (F2, or a button on touch screens) with history and autocomplete, and every command also works from the chat bar.

Add the server system and the client system:

```luau
-- ServerScriptService/Main.server.luau
app:addSystem(Hydrogen.Commands)
Hydrogen.Commands.configure({ admins = { 12345678 } }) -- in Studio, everyone may run everything
app:start()

-- StarterPlayerScripts/Main.client.luau
app:addSystem(Hydrogen.Commands.Client)
app:start()
```

Register commands where the behaviour lives:

```luau
-- ServerScriptService/Systems/Inventory.luau
return Hydrogen.define(function(use)
	local Commands = use(Hydrogen.Commands)
	local Inventory = {}

	Commands.register("give", {
		description = "Give items to a player",
		args = { Commands.player(), gt.string(), gt.number({ integer = true, range = "[1, 999]" }) },
		permission = "admin",
		run = function(ctx, target: Player, item: string, count: number)
			Inventory.give(target, item, count)
			return `Gave {count} {item} to {target.Name}` -- sent back to ctx.player
		end,
	})

	return Inventory
end)
```

Typing `give al sword 5` gives Alice five swords. `al` matches the start of a name or display name; `me` is you. Mistakes get answers that say what to fix:

```
gvie al sword 5      -> Unknown command "gvie". Did you mean "give"? Type "help" for a list.
give al sword lots   -> Bad argument 3 (integer) for give: expected a whole number from 1 to 999, got "lots". Usage: give <player> <string> <integer>
give a sword 5       -> Bad argument 1 (player) for give: "a" matches Alice, Alan; type more of the name. Usage: ...
```

Arguments can be any GreenTea schema, or one of the built-in types: `Commands.player()`, `Commands.players()` (adds `all`, `others` and `me,bob` lists), `Commands.number({ min, max, integer })`, `Commands.integer()`, `Commands.string()`, `Commands.boolean()`, `Commands.enum({ "easy", "hard" })` (or a Roblox `Enum`), and `Commands.text()` for the rest of the line. Wrap one in `Commands.optional(arg, default)`, `Commands.rest(arg)` (every remaining word, as a list) or `Commands.named("count", arg)`, or make your own with `Commands.arg({ name, parse })`. Inside `run`, `ctx:reply(text)` sends a line and `ctx:fail(text)` sends an error and stops.

Permissions are pluggable. A command's `permission` is a string your resolver checks, or a function of the player. By default, the UserIds in `admins` hold every permission; then, if you defined a `Hydrogen.Guards` permission or role with that name, Guards answers; and in Studio everyone holds every permission. So with Guards there's nothing to configure:

```luau
Hydrogen.Guards.defineRole("mod", Hydrogen.Guards.groupRank(1234567, 200))
Hydrogen.Guards.definePermission("ban", { "mod" })
Hydrogen.Commands.register("ban", { permission = "ban", args = { Hydrogen.Commands.player() }, run = function(ctx, target) end })
Hydrogen.Guards.invalidate(player) -- after granting roles at runtime; also resends the player's command list
```

To use another role system:

```luau
Hydrogen.Commands.configure({
	permissions = function(player, permission, command)
		return Roles.has(player, permission)
	end,
})
Hydrogen.Commands.refresh(player) -- after a player's roles change
```

Built-in commands: `help [command]` for everyone, and `kick <players> [reason]` with the `admin` permission. Your own command with the same name replaces a built-in; `configure({ help = false, kick = false })` turns them off. To make your own console, pass `Hydrogen.Commands.Client.configure({ console = false })` and use `Client.run(text)`, `Client.onOutput(fn)` and `Client.complete(text)`.

In tests, `Hydrogen.Commands.execute(player, text)` runs a line with every check and returns `{ ok, status, output }`:

```luau
Hydrogen.test({ systems = { Hydrogen.Commands, Inventory }, players = { "Alice", "Bob" } }, function(t, alice, bob)
	Hydrogen.Commands.configure({ admins = { alice.UserId } })
	assert(Hydrogen.Commands.execute(alice, "give bob sword 5").ok)
	assert(Hydrogen.Commands.execute(bob, "give bob sword 5").status == "denied")
end)
```

Rules:

- Add **both** `Hydrogen.Commands` (server) and `Hydrogen.Commands.Client` (every client) before `app:start()`. Each registers the same three network names, so one without the other is a `NETWORK MISMATCH`. A game that adds neither registers nothing.
- Register each command once: in the system's constructor, or keep the function `register` returns and call it to remove the command.
- The client only sends the typed line. The server rate-limits it (3 per second, bursts of 6, set with `rateLimit`), caps its length (`maxLength`, 500), then parses, checks the permission and runs it.
- A permission resolver that errors denies and warns. An error in `run` is warned with a traceback; the player sees `give failed with an error.`
- Commands appear in each player's `help`, autocomplete and chat bar only if that player may run them. `hidden = true` keeps one out of all three.
- In the chat bar, a command is `/name`, using names Roblox doesn't already use (Roblox owns `/help`, so it's `/commands` there). The game needs TextChatService. The console and chat commands are built only in a real client.

#### Why it's designed this way

- **Commands live with their system.** A `give` command next to the inventory code stays in sync with it, and `use(Hydrogen.Commands)` keeps the boot order right. One central admin script ends up importing everything.
- **The client sends text and nothing else.** Exploiters control the client, so parsing, permission checks and the rate limit all happen on the server. The client knows only which commands to suggest.
- **Errors say which argument and why, plus the usage.** Commands are typed by hand and often on a phone. A reply that names the problem saves the second try.
- **Permissions are a function, not a role system.** Games already have ranks, groups or a role registry. A single resolver adapts to any of them, and `refresh` keeps the clients' lists right. The default covers the common start: you, plus everyone in Studio.
- **Two systems, opt-in.** Commands needs network names on both sides, and Hydrogen registers names only for the systems you add. That way a game without commands has no remotes, listeners or UI for them.
- **Chat commands are made per client.** A `TextChatCommand` created on the server would show every player's chat autocomplete the admin commands. Created on the client, each player sees their own.
### Config and feature flags

`Hydrogen.Config` holds your game's tunable values and feature flags. Declare them once in a shared module. Read values as plain table lookups, turn features on for some players, override anything per environment, and optionally take live values from Roblox Experience Configs without a deploy.

```luau
-- ReplicatedStorage/Shared/GameConfig.luau (required on both sides before app:start)
local Config, gt = Hydrogen.Config, Hydrogen.gt

return Config.define("Game", {
	values = {
		RoundLength = Config.value(gt.number(), 180),                   -- server only (the default)
		WebhookUrl = Config.value(gt.string(), ""),                     -- server only; fill it from ServerStorage
		MaxCoins = Config.shared(gt.number({ integer = true }), 1000),  -- replicated to clients
	},
	segments = {
		Staff = { groups = { 1234567 }, minRank = 200 },
	},
	flags = {
		NewShop = Config.flag({ percent = 10, segments = { "Staff" } }), -- 10% of players, plus staff
		Holiday = Config.flag(false),
	},
	environments = {
		studio = { RoundLength = 20, Holiday = true },
		private = { RoundLength = 60 },
		places = { [123456789] = { MaxCoins = 5000 } },
	},
	source = Config.experienceConfigs(), -- optional live values
})
```

```luau
-- server boot: the config is a system
app:addSystem(GameConfig)

-- a server system (use(GameConfig) so flags are evaluated before its playerAdded)
if GameConfig.flags.NewShop:enabled(player) then openNewShop(player) end
local length = GameConfig.values.RoundLength
GameConfig:observe("RoundLength", function(seconds) timer:setLength(seconds) end)

-- client
GameConfig.flags.NewShop:observe(Players.LocalPlayer, function(enabled)
	shopButton.Visible = enabled
end)
print(GameConfig.values.MaxCoins) -- shared values only; RoundLength errors here
```

| Declare | What it is |
| --- | --- |
| `Config.value(schema, default)` | A value only the server can read. It is never sent to clients. |
| `Config.shared(schema, default)` | A value the server sends to every client. |
| `Config.flag(true \| false \| rule)` | A feature flag. A rule has `enabled` (a kill switch), `percent` (0 to 100), `users` (UserIds), `groups` (group ids), `segments` (names) and `when` (a custom check, `function(player) -> boolean`). It is on for a player who matches any of them, and on for everyone when it has none. |
| `segments = { Name = ... }` | A named group of players: `{ users, groups, minRank, when }` or a function. |
| `environments = { studio, private, reserved, live, places }` | Overrides for the matching environment, and per place id on top of that. |
| `source = Config.experienceConfigs() \| Config.dataStore(name, { topic }) \| Config.memory()` | Live values, fetched every `refresh` seconds (default 60) and when the source pushes. |

On the server, `GameConfig:override({ Name = value })` sets values or flag rules from code, above everything else, and `clearOverrides()` removes them. `Config.reevaluate(player)` evaluates flags again after something a `when` check reads has changed. `Config.getFlag(name)` and `Config.findFlag(name)` find a flag by name, for libraries that gate on a flag the game declared.

Rules worth knowing:

- **Values are layered.** From highest to lowest: `override`, then the live source, then `places[placeId]`, then the environment kind, then the declared default. The kind is `studio` in Studio, `private` on a private (VIP) server, `reserved` on a reserved server, and `live` everywhere else. Every environment table is checked when the config is defined, including the ones this server doesn't use, so a typo or a wrong type fails at boot with a `[HYDROGEN]` error.
- **Server-only is the default, and the shared module is public.** `Config.value` is never sent, and reading it on a client errors. A ModuleScript in ReplicatedStorage is downloaded by every client, though, so never write a real secret as a default. Supply it with `override` from a ServerStorage module, or from a live source.
- **Reads are plain table lookups** on a table that is updated in place when a value changes. Read `GameConfig.values.X` when you use it, or `observe` it; a copy kept in a local doesn't follow live changes. Unknown names error, assignments error, and tables are frozen.
- **Add the config to the app on the server.** As a system, it sends shared values to clients, evaluates every player's flags as they join (before the `playerAdded` of systems that `use` it), looks up group ranks and runs the live source. If you forget, a warning says so once the network is running.
- **Flags are evaluated on the server**, once per player, and again when a rule changes, when group lookups finish or when you call `Config.reevaluate`. A percentage hashes the flag's name with the UserId, so the answer is the same on every server, players already in stay in as the percentage grows, and different flags pick different players. Group ranks are looked up when a player joins, all at once, for at most 5 seconds. `when` checks must not yield; one that errors or yields counts as false, with a warning.
- **Clients see only their own flags**, and only the ones that are on. Flags and shared values reach a joining client in the ready handshake, before client systems start.
- **Live values are checked like code.** Each value is validated against its schema, and each flag rule compiled, on its own. A bad one is rejected with a warning and the last good value kept. A missing one falls back to the lower layers, and a failed fetch keeps everything. `app:stop()` stops refreshing.
- **Tests:** `Config.useEnvironment({ kind = "studio" })` pretends to be elsewhere, `override` forces a value or flag, and `Config.memory()` is a source you can `set`, `push` and `fail`. Refreshes run on `Hydrogen.Clock`, so `t:advance(seconds)` drives them. `Hydrogen.test` resets Config when it closes. Under loopback, read what a client received with `t:as(player, GameConfig.replica, GameConfig)`.

#### Live sources

- **`Config.experienceConfigs()`** is the one to reach for. Experience Configs are edited in Studio (File > Open Configs) or on the Creator Hub, and published without a deploy. Each value or flag is the config key of the same name: a number, string or boolean, or a JSON object for a flag rule such as `{"percent": 25}`. Roblox pushes `UpdateAvailable` when a new version is published, so changes reach running servers in seconds to a minute. A scheduled refresh only reads the snapshot the server already has. Hydrogen uses the global snapshot; Roblox's own per-player targeting isn't used, because flags do that.
- **`Config.dataStore(name, { key, topic })`** reads one DataStore key holding a table of values, with one `GetAsync` per server per refresh. With a `topic`, publishing any message to it over MessagingService makes every server fetch straight away.
- **Your own source** is any table with `name` and `fetch(self, names) -> { [name]: value }`, plus an optional `subscribe(self, onUpdate) -> unsubscribe` for push.

#### Why it's designed this way

- **One declaration, typed reads.** `Config.value(schema, default)` returns the default's type, so `GameConfig.values.RoundLength` autocompletes as a `number` and a read is one table index. There are no string keys to mistype, and no getter on the hot path.
- **Server-only by default.** Forgetting to mark something private shouldn't leak it. You opt in to replication per value, and the docs say plainly that a shared module's source is public anyway.
- **Flags replicate through `Hydrogen.State`.** A flag's answer is per player, must reach that player only, must arrive before client systems start, and must update when a rule changes. That is exactly `State.playerMap` with owner-only visibility. Shared values are a `State.map`. Config writes nothing new on the wire, and tests get per-client replicas for free. Only flags that are on are sent, so clients don't learn which players are excluded.
- **Evaluated on the server, cached per player.** Rules can name groups, which need a web call, and custom checks, which only make sense on the server. Evaluating once per player and on change makes `enabled` a table lookup, while percentages stay deterministic across servers with no stored assignments.
- **Experience Configs as the default live source.** It is Roblox's own tool: it needs no Open Cloud key or admin UI, it pushes updates, and it keeps serving its last values through outages. DataStore polling remains for teams that already store config there, and the interface is one function for anything else.
- **Per-value validation with last-good fallback.** One bad remote value shouldn't take a whole config down, and a bad deploy of config shouldn't take the game down. Each name is checked on its own, and nothing changes unless it passes.
### Debug overlay and network stats

`Hydrogen.Debug` counts traffic per network object and shows it, with the rest of your game's live state, in a panel you open with a key.

```luau
-- ServerScriptService/Main.server.luau
Hydrogen.Debug.configure({
	users = { 12345678 },     -- who may open it in live servers; Studio is always allowed
	inspect = { PlayerData }, -- Data.player stores and PlayerStates to show per player
})

local app = Hydrogen.App.new({ debug = true, output = Hydrogen.Debug.bootOutput })
app:addSystemsFolders(ServerScriptService.Systems)
app:addSystem(Hydrogen.Debug)
app:start()
```

```luau
-- StarterPlayerScripts/Main.client.luau
local app = Hydrogen.App.new({ debug = true, output = Hydrogen.Debug.bootOutput })
app:addSystem(Hydrogen.Debug)
app:start()
-- F3 opens and closes the overlay.
```

The overlay has five tabs:

- **Network**: for the server and for this client, every network object's messages per second in and out, estimated bytes per second, dropped messages and average function time, busiest first.
- **Boot**: how long each system's `init` and `start` took on each side, the numbers `App.new({ debug = true })` prints.
- **State**: every global `Hydrogen.State` value on the server.
- **Player**: pick a player to see their per-player `Hydrogen.State` and the stores passed in `inspect`.
- **Warnings**: the last 50 `[HYDROGEN]` warnings on the server and on this client.

The stats work without the overlay, on either side, which is handy for logging and tests:

```luau
Hydrogen.Debug.enableStats()
local buy = Hydrogen.Debug.stats()["Shop/Buy"]
print(buy.inPerSecond, buy.inBytesPerSecond, buy.dropped, buy.latency)
```

Each entry has `inTotal`/`outTotal`, `inPerSecond`/`outPerSecond` (the last full second), `inBytes`/`outBytes` and their per-second rates, `dropped`, and for functions `latency` (round trips of calls this side made) and `handler` (time this side's handler took), each as `{ count, last, average, max }` in seconds. `Debug.disableStats()` stops and `Debug.resetStats()` forgets. Client code can read the server's view with `Hydrogen.Debug.fetch(userId?)`, which yields and returns `nil` if the player isn't authorized. `Debug.open()`, `close()` and `toggle()` drive the overlay from your own button or command, and `Debug.configure({ key = Enum.KeyCode.F6 })` changes the key.

Rules:

- **Add `Hydrogen.Debug` on both sides before `app:start()`.** It registers one network function, `Hydrogen/Debug`, which both sides need. Stats alone need no system.
- **Nothing runs until it's used.** Until stats are enabled or someone opens the overlay, no middleware or observer is installed, so the network does no extra work. An authorized request turns server stats on for 10 seconds, and each refresh renews that. The open overlay keeps this client's stats on until 3 seconds after it closes. `enableStats()` keeps them on until `disableStats()`.
- **Only authorized players get server data.** By default that's anyone in Studio, the owner of a user-owned game, the UserIds in `users`, and, if you define the `Hydrogen.Guards` permission `"debug"`, players who have it. `authorize = function(player) ... end` replaces that check entirely, for staff lists or roles. An `authorize` that errors denies and warns. Unauthorized players get `nil`, and their request does no other work. Outside Studio, the panel opens only after the server answers, so for everyone else the key does nothing.
- **Read-only.** The server sends formatted text, never live tables, so nothing in the panel can change game state.
- **Bytes are estimates** of the plain values: 9 bytes for Hydrogen's id, then 9 per number, a string's length plus 4, 2 per boolean, 4 per table plus its contents (full list in `docs/ai/debug.md`). After 256 values in one message, each further value counts as a number, which keeps the estimate cheap. `:Encode()` objects send less than estimated.
- **Dropped** counts events and requests that arrived but never reached a listener or handler: rate-limited, dropped by middleware or failing the schema. A server event sent to three players counts three messages out.
- **Boot timings** need `output = Hydrogen.Debug.bootOutput` in `App.new`. They still print.
- Under `Hydrogen.test`, one VM is the server and every client, so each message counts once leaving and once arriving. Rates follow the fake clock (`t:advance(1)`), and the harness turns stats off when it closes. The panel itself is only drawn in a real client; check it in a Studio play test.

#### Why it's designed this way

- **Stats are middleware plus the network's delivery observer.** Middleware sees every message arriving and leaving, with its values. The observer sees what reached a listener or handler. The difference is what was dropped, whatever dropped it. Neither needs a change to the network.
- **Off by default, on while someone looks.** A collector that always runs costs every message, in every game, for numbers nobody reads. Leasing from the overlay keeps that cost to the moments you are actually debugging.
- **Text over the wire, not values.** Formatting on the server makes the view small and safe to send: cycles, Instances and mixed tables can't break the remote. It also makes the panel read-only.
- **Explicit `inspect`.** Data stores and PlayerStates hold private data, so the panel shows only what you list.

### Teleports

`Hydrogen.Teleport` moves players to another place or server without losing or duplicating their `Hydrogen.Data`. A bare `TeleportAsync` leaves the player's session lock on this server until its `playerRemoving` saves, so the destination's load waits for it (up to 30 seconds, then kicks). `Teleport.send` saves and releases first:

```luau
-- ServerScriptService/Systems/Portals.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local FOREST_PLACE = 1234567890

return Hydrogen.define(function(use)
	use(Hydrogen.Teleport) -- adds it to the app, so shutdown stops its retries
	local Portals = {}

	function Portals.enter(player: Player)
		local result = Hydrogen.Teleport.send(player, FOREST_PLACE) -- yields until they left or failed
		if not result.ok then
			-- Still here, with their data taken back and saving again.
			print(result.failed[1].reason, result.failed[1].message)
		end
	end

	return Portals
end)
```

What `send` does, for one player or a party:

1. Runs `Teleport.onHandOff` callbacks: the last moment a change still reaches the destination (session playtime, last position).
2. Saves and releases every `Data.player` store the players are in: one write that stores the data and clears the lock. A player whose release fails isn't sent (`DataNotSaved`) and keeps playing on locked, saving data.
3. Calls `TeleportAsync`, only after every release landed. A player can't reach the destination before this call, so the destination's load always finds the lock cleared and loads at once.
4. Waits for each player to leave (teleported) or for `TeleportInitFailed`. `Failure`, `Flooded` (after 15 seconds) and `TeleportAsync` errors are retried with backoff, up to `attempts` (3). `GameFull`, `GameNotFound`, `GameEnded`, `Unauthorized`, `IsTeleporting` and `TimedOut` (still here `timeout`, 30, seconds after Roblox accepted) aren't.
5. Takes the data back for everyone who stayed, under the same lock. Changes made on this server in the meantime are kept and saved if nothing else wrote the record; otherwise the stored data wins, with a warning. If the data can't be taken back, the store's `onLoadFailed` runs (warn and kick, by default): no one keeps playing on data that isn't saved.

The result is `{ ok, teleported, failed = { { player, reason, message } }, attempts, reservedCode }`, and failures are warned once per send.

While a player's data is handed off, `get` still works, but `isLoaded` is false, `update` changes memory only, `updateOnce` returns `"failed"` (so a purchase in that window is granted at the destination) and `transaction` errors. If the player then leaves, changes made after the hand-off are lost, and Data warns. Make them before `send`, or in `onHandOff`.

Options: `reserveServer = true` puts a party in a new reserved server (retries join the same one, and `result.reservedCode` sends late joiners there), `reservedCode` joins one (`Teleport.reserve(placeId)` makes a code), `serverId` joins a specific server, `data` sets teleport data, and `attempts` and `timeout` override the defaults (`Teleport.configure` changes them for every send).

**Tickets** carry typed teleport data:

```luau
-- ReplicatedStorage/Shared/Tickets.luau, required by both places
local DungeonTicket = Hydrogen.Teleport.ticket("Dungeon", gt.table({ dungeon = gt.string(), difficulty = gt.number() }))

-- Lobby:
DungeonTicket:send(party, DUNGEON_PLACE, { dungeon = "Crypt", difficulty = 2 }, { reserveServer = true })

-- Dungeon place, in a system's playerAdded:
local ticket = DungeonTicket:read(player) -- checked against the schema; nil if absent or invalid
```

Teleport data passes through the client, so an exploiter can change it. Use tickets for routing and presentation (which dungeon, which gate, party names) and never for anything of value. Put coins, items and unlocks in Data before the teleport and read them from Data at the destination.

Rules:

- A second `send` for a player whose send is still running reports `Busy`. Players who leave mid-teleport are reported `Left`, with their data saved and released.
- On `app:stop()` (bound to `BindToClose`) sends stop retrying, and players still here are reported `ShuttingDown`, their data saved and released.
- Only `Data.player` stores are handed off. Key stores (`Data.store`) stay with the server.
- In Studio the real `TeleportAsync` fails; Teleport reports it with a hint instead of retrying. Test with `Hydrogen.Teleport.fakeService()`:

```luau
local fake = Hydrogen.Teleport.fakeService()
Hydrogen.Teleport.configure({ service = fake })
-- In a Hydrogen.test with the Data store and Hydrogen.Teleport:
fake:failNext(1)              -- the first attempt fails; t:advance(1) runs the retry
fake:hold(true)               -- accepted teleports wait for fake:complete(player) or fake:fail(player)
fake:arrive(bob)              -- bob's join data as the destination would see the last request
```

By default the fake makes an accepted player leave at once, so `send` returns without advancing time. Under Lune and `Hydrogen.loopback()`, an unconfigured Teleport uses a fake automatically.

#### Why it's designed this way

- **Release before teleporting, not after leaving.** Data's session lock is what stops two servers from writing one record. Releasing it in the source's `playerRemoving` races the destination's load. Releasing it first, and calling `TeleportAsync` only once that write landed, orders the two by construction.
- **Read-only while handed off, rather than locked.** Between the release and the outcome, the player is still playing here. Erroring on every `update` would break gameplay code, so writes go to memory: kept if the teleport fails and nothing else changed the record, reported if it succeeds.
- **Take back with the normal lock.** Reclaiming reads the stored record under the same rules as a load, so it never overwrites a server that legitimately loaded the data in between.
- **A result, not an exception.** Teleports fail for ordinary reasons (full servers, throttling). The caller decides what to tell the player, and the data is already safe when `send` returns.

### Cross-server messaging

`Hydrogen.Messaging` wraps `MessagingService` in typed topics:

```luau
-- ServerScriptService/Shared/Topics.luau
local Announcements = Hydrogen.Messaging.topic("Announcements", gt.table({ text = gt.string() }))

-- In a system that use(Hydrogen.Messaging):
function Announcer:start()
	Hydrogen.Scope.of(self):add(Announcements:subscribe(function(value, info)
		Remotes.Show:FireAll(value.text) -- info.fromThisServer, info.serverId, info.sent
	end))
end

task.spawn(function()
	Announcements:publish({ text = "Double XP for an hour!" }) -- yields; returns ok, err
end)
```

- **`publish` checks before sending.** A value that fails the schema, that JSON can't hold (Vector3, Instances, arrays with holes) or that is over MessagingService's 1000 bytes as JSON (Hydrogen's envelope included) errors at the call. Then it waits if this server would pass its publish limit (600 + 240 per player per minute), sends, and retries failures (3 attempts). A publish that keeps failing returns `false, err` and warns.
- **`subscribe` only sees valid values.** Messages that fail the schema, or weren't sent by Hydrogen, are dropped with a warning at most once per topic per 10 seconds. Values are frozen and shared by every subscriber. A server receives its own messages too (`info.fromThisServer`); pass `{ ignoreSelf = true }` to `Messaging.topic` to skip them.
- **Lazy.** Defining a topic does nothing. The first subscriber makes one MessagingService subscription in the background (retried on failure), later subscribers share it, and the last unsubscribe drops it.
- **Cleanup.** `subscribe` returns an unsubscribe function; `scope:add(...)` ties it to a system, player or round. With `Hydrogen.Messaging` in the app, `app:stop()` drops every subscription.
- **Delivery isn't guaranteed and order isn't kept.** Never grant anything from a message alone: store it (DataStore, MemoryStore) and use the message as a hint to look.
- **Server-only.** Topics can be defined in shared modules, but `publish` and `subscribe` error on a client.

Tests use `Hydrogen.Messaging.memoryBus()`: `Messaging.configure({ service = bus })`, then `bus:send(topic, value, serverId?)` plays another server, `bus:sendRaw` sends malformed data, `bus.published` lists what was sent, and `failPublishes` / `failSubscribes` simulate outages.

#### Why it's designed this way

- **Schemas on both ends.** Servers running different versions of a place publish to the same topics during an update. Checking on receive turns a mismatch into a warning instead of an error deep in a handler.
- **Limits enforced where they can be.** Size and this server's publish rate are known locally, so they're checked before the request. The receive and subscription limits depend on every server, so they're documented instead.
- **One subscription per topic.** Subscriptions per server are limited, and subscribing yields. Sharing one per topic makes per-player and per-round subscribers cheap.

---

## Part 2: Working on Hydrogen itself

This section is for contributors and coding agents.

### Toolchain

- [pesde](https://pesde.dev) `^0.7` for packages and scripts. It also provides the Lune runtime (`^0.10.2`) used by tests.
- [Rokit](https://github.com/rojo-rbx/rokit) installs Rojo (`rokit install`, version pinned in `rokit.toml`).
- Editor: the luau-lsp VS Code extension with its Studio plugin enabled (`.vscode/settings.json`). `sourcemap.json` feeds it Rojo paths.

Setup:

```bash
pesde install
```

### Run the tests

```bash
pesde run test
```

Expected output ends with `Tests Ran: 552 | Passed: 552` and `status: OK`. A few `[HYDROGEN]` warnings in the output are expected; tests exercise those paths. The command exits with code 1 on failure. GitHub Actions runs the suite on every push to `main` and every pull request (`.github/workflows/ci.yml`). The setup step installs Lune explicitly, because `pesde run` needs a `lune` executable on the PATH.

### Layout

```
src/
  init.luau            public API and exported types
  App.luau             App: collects systems, runs init -> Network.init -> start, player, character and stop hooks; adds used systems
  Clock.luau           time sources (now, time, serverNow, wait, delay, cancel, heartbeat) and the fake clock
  Log/
    init.luau          Hydrogen.Log: loggers, levels, sinks, rate limiting; Log.warn / Log.capture for Hydrogen's own warnings
    Types.luau         Level, Line, Logger, Buffer types and level ranks
    Format.luau        how a line reads: [Tag] message key=value
    Buffer.luau        the ring buffer sink
  Definition.luau      define/use, system ids, dependency graph wiring, replace redirects, lifecycle-stripping type function, Definition.hooks
  Graph.luau           generic dependency graph with topological sort and cycle detection
  Network/
    init.luau          exports constructors and Network.init
    Runtime.luau       remotes, name->id mapping, queues, batching, ready handshake, dispatch
    Middleware.luau    middleware context/types, onion ordering, global middleware, logger
    Codec.luau         schema-driven buffer encoding for :Encode()
    Loopback.luau      in-memory remotes and fake players for headless tests
    ClientEvent.luau   ServerEvent.luau  ClientFunction.luau  ServerFunction.luau
  Scope/
    init.luau          Scope: cleanup tied to lifetimes; Scope.of looks up the scopes App keeps
  Character/
    init.luau          characterAdded / characterRemoving, registered with Definition.hooks; Hydrogen.Character test helpers
    Fake.luau          fake character signals and models for loopback players
  Data/
    init.luau          re-exports Stores and its types
    Stores.luau        Data.player / Data.store systems, backend selection
    Store.luau         sessions: load and lock, update, transactions, updateOnce, saving, autosave
    Backend.luau       backend type, in-memory backend, Roblox DataStore backend
    Tables.luau        copy, deep freeze, reconcile, structural sharing
    Clock.luau         Data's time sources, forwarding to Hydrogen.Clock
    HandOff.luau       internal, for Teleport: release every player store before a teleport, take it back after a failure
  PlayerState/
    init.luau          re-exports Define and its types
    Define.luau        PlayerState.new: fields, proxies, lifecycle
    Replication.luau   one State.playerValue per replicated field, per-field audiences, client views
  State/
    init.luau          public API, types, write checks
    Store.luau         cells per context (server / replica), subscriptions, flush, snapshots, receive
    Wire.luau          one serverEvent per state, payload schemas per kind
    Value.luau  Map.luau  List.luau   how each kind diffs, applies and notifies
    Meter.luau         meters: segments extrapolated with Clock.serverNow, onLimit timers, client prediction
    Computed.luau      derived state with dependency tracking
    Schedule.luau      the end-of-frame flush, on Hydrogen.Clock
  Receipts/
    init.luau          exports the Receipts system and its types
    Receipts.luau      the system: ProcessReceipt routing, waiting for players, game passes
    Stores.luau        dataStore, memoryStore and fromData (Hydrogen.Data)
    FakeMarketplace.luau  stand-in MarketplaceService for tests
    Types.luau         Receipt, ReceiptStore, Marketplace, options
    Clock.luau  Log.luau  time sources and warnings, forwarding to Hydrogen.Clock and the log; tests can patch them
  Signal/
    init.luau          Signal: typed in-process signals, listeners on a reused runner thread
  Scheduler/
    init.luau          Scheduler: after, every, fixed, debounce, throttle on one min-heap and one Clock.delay
  Component/
    init.luau          Component.new: options, per-instance entries, construct/destroy, lookups
    Source.luau        where tag changes come from: CollectionService signals, or polling under a fake clock
  Input/
    init.luau          Hydrogen.Input: actions, contexts, bindings, saving, glyphs, the public API
    Core.luau          the engine: contexts and actions, routing keys to actions by priority, held state
    Device.luau        UserInputService events as key names; the current device
    Keys.luau          key names, binding parsing and display
    Touch.luau         on-screen touch buttons, made on first touch input
    Types.luau         Action, Context, Binding, Device and Glyph types
  Commands/
    init.luau          Hydrogen.Commands (server system) and Commands.Client; register, configure, execute
    Server.luau        registry, permissions (admins, Guards, Studio), rate limit, the parse-and-run pipeline
    Client.luau        sends lines, keeps the command list, output and autocomplete on the client
    Args.luau          argument types: built-ins and GreenTea schemas
    Builtins.luau      help and kick
    Complete.luau      autocomplete from the command list
    Console.luau       the in-game console UI (verified in Studio; not drawn headless)
    TextChat.luau      TextChatService chat commands
    Types.luau         public types
    Wire.luau          the network objects, registered by the systems' init
  Guards/
    init.luau          public API: guard constructors, all/any, role and range helpers, configure
    Guard.luau         guards as middleware: specs, rejection (DROP or error), onReject hooks, atomic cooldown use
    Cooldown.luau      per-player cooldowns with charges, gaps and groups
    Roles.luau         role and permission registry, resolvers, per-session cache with in-flight dedupe
    Range.luau         character and target positions, distance checks
    Leave.luau         clears guard state when a player leaves (Players or the loopback)
  Config/
    init.luau          public API and types
    Define.luau        Config.define: layers, values tables, flag evaluation, live refresh, the system hooks
    Rules.luau         flag rules and segments: checking, compiling, evaluating, the rollout hash
    Environment.luau   which kind of server this is (studio, private, reserved, live) and the place id
    Sources.luau       live sources: experienceConfigs, dataStore, memory
  Debug/
    init.luau          the Debug system and API: configure, stats, fetch, boot timings, warnings
    Stats.luau         network stats: a global middleware plus the delivery observer, leases, byte estimate
    Server.luau        authorization and the read-only view sent to the overlay
    Format.luau        values as one line of text for the view
    Overlay.luau       the client panel (verified in Studio; not drawn headless)
  Teleport/
    init.luau          exports the Teleport system and its types
    Teleport.luau      the system: send (hand off, TeleportAsync, retries, take back), tickets, reserve, onHandOff
    Types.luau         Result, Failure, SendOptions, Request, Backend, Ticket
    FakeService.luau   stand-in TeleportService for tests
    RobloxService.luau the real TeleportService behind the Backend shape (TeleportOptions, GetJoinData)
  Messaging/
    init.luau          exports the Messaging system and its types
    Messaging.luau     the system: typed topics, publish budget and retries, shared lazy subscriptions
    Types.luau         Topic, MessageInfo, Backend (MessagingService's shape), Config
    MemoryBus.luau     in-memory MessagingService for tests
    Json.luau          whether a value can be JSON, and its size (also used for teleport data)
  Testing/
    init.luau          Hydrogen.test and Hydrogen.harness
    Expect.luau        expectations on deliveries, argument matching, failure messages
    Lune.luau          Lune runtime: Roblox globals and a Roblox-style require (shipped for game tests)
    Lint/              the network lint engine (Lune only), run by tools/hydrogen-lint
      World.luau       one side of a game: Instance tree from the sourcemap, globals, require, scripts
      Probe.luau       wraps the network runtime in a world and records registrations with their stacks
      Rules.luau       compares the two sides' registrations into diagnostics
      Lint.luau  Report.luau  Cli.luau   Lint.run, text/JSON output, the command line
test/
  _run.luau            Lune entry point: installs the Lune runtime, runs suites
  App.luau  Clock.luau  Definition.luau  Graph.luau  Network.luau
  Testing.luau         Hydrogen.test, app:replace and Hydrogen.loopback, used the way a game's tests would
  Scope.luau           Scope on its own, and the system and player scopes an app keeps
  Data.luau  PlayerState.luau
  State.luau           Hydrogen.State end to end through loopback
  Receipts.luau        Hydrogen.Receipts with a fake marketplace, memory store and Data store
  Log.luau             Hydrogen.Log: levels, laziness, sinks, rate limiting, harness capture, Log.warn compatibility
  Character.luau       character hooks, the Definition.hooks extension point, and used systems being added
  Signal.luau  Scheduler.luau
  Input.luau  Commands.luau
  Component.luau       Hydrogen.Component under Hydrogen.test (polling), and through CollectionService signals on a fake world
  Guards.luau          Hydrogen.Guards as middleware under Hydrogen.test
  Config.luau          Hydrogen.Config under Hydrogen.test: environments, rollouts, replication, live sources
  Debug.luau           Hydrogen.Debug stats, drops, latency, authorization and the server view
  Teleport.luau        Hydrogen.Teleport under Hydrogen.test: hand-off, retries, take-back, leaving, shutdown, tickets
  Messaging.luau       Hydrogen.Messaging with a memory bus: schemas both ways, limits, retries, cleanup
  Lint.luau            the network lint against the fixture games in Fixtures/Lint
  Docs.luau            every luau example in README.md and docs/ai compiles, and every Hydrogen.X it names exists
  Fixtures/            modules the suites require
bench/                 micro-benchmarks, not run by the suite (lune run bench/Signal)
docs/ai/               agent-facing docs, one file per API area (format in AGENTS.md); llms.txt indexes them
default.project.json   Rojo project for development (see below)
pesde.toml             package manifest, scripts, dependencies, version
tools/create-hydrogen/ the `pesde x atk422/create_hydrogen` project generator: its own pesde package
tools/hydrogen-lint/   the `pesde x atk422/hydrogen_lint` launcher: finds a game's Hydrogen and runs its src/Testing/Lint
```

When the public API changes, update the generator's template in `tools/create-hydrogen/template/` in the same change and run its tests (`lune run test/run e2e` from that folder). Its [README](tools/create-hydrogen/README.md) covers maintaining and publishing it.

The network lint reads the network runtime's internals: `Runtime.registerNetworkObject`, `RegisteredNames`, `Objects`, `Initialized`, `namesHash` and `countObjects`, and each object's `_kind`, `_schema` / `_argsSchema` / `_returnsSchema`, `_codec` / `_argsCodec`, `_listeners` and `_callback`, plus `ServerFunction.new`, `ClientFunction.new` and `App.addNetwork`. When you change those, update `src/Testing/Lint/Probe.luau` in the same change; `test/Lint.luau` boots the fixture games in `test/Fixtures/Lint/` and fails on drift. After changing a fixture's layout, regenerate its sourcemap from its folder with `rojo sourcemap default.project.json --output sourcemap.json`. The launcher in `tools/hydrogen-lint` has its own tests (`lune run test/run` from that folder) and [README](tools/hydrogen-lint/README.md).

### How the tests run

Tests run outside Roblox under Lune, on the same runtime game developers use ([Running tests under Lune](#running-tests-under-lune)). `test/_run.luau` requires `src/Testing/Lune.luau` with Lune's own `require`, calls `Lune.install()`, and shadows `require` with `Lune.require`, so every suite and everything it requires loads through the runtime:

- `game` is a DataModel from `@lune/roblox`, with `RunService` stubbed so `IsClient()` and `IsServer()` both return `false`. Real remotes and the `Players` / `BindToClose` connections are never exercised. `test/Testing.luau` runs the network end to end through `Hydrogen.test` and `Hydrogen.loopback()`; the other suites call `app:_addPlayer` / `app:_removePlayer` with fake players.
- `require` follows Roblox's require-by-string rules: in an `init.luau`, `./X` is a sibling of the folder and `@self/X` a child, as in Studio. It resolves `.luaurc` aliases, and runs `require(script.X)`, so GreenTea loads through its own `init`. Lune can't require Instances, so a test sets `_G.instanceModules[moduleScript] = value` and `require(moduleScript)` then returns `value`.
- Modules are named like Roblox full names, so errors read `src.Network.Runtime:345: ...`.
- It calls each test module, runs [frktest](https://github.com/itsfrank/frktest), then exits with `process.exit`. The explicit exit matters: the server function timeout test yields the main thread and resumes it from a timer, and without the exit Lune can keep running after the last suite.

To add a test file: create `test/Thing.luau` that returns a function registering `test.suite(...)` blocks (copy the shape of `test/Graph.luau`), then add `require("./Thing")()` next to the others in `test/_run.luau`. Tests of systems should use `Hydrogen.test`, which cleans up after itself. Suites that drive Runtime directly (Network, the lower-level Testing cases) reset `Runtime` state in `test.on_suite_enter`, and stop their apps and close their loopbacks in `test.on_test_leave`, so a failed test doesn't leak a running network into the next one.

### Conventions

- Strict mode is on for every file through `.luaurc` / `src/.luaurc`. Keep code type-checking clean.
- Requires: `@self/...` from `init.luau` files, `./...` or `../...` elsewhere. GreenTea is loaded by relative path (`./roblox_packages/gt` from `src/init.luau`, `../../roblox_packages/gt` from `src/Network/*`).
- Those paths rely on `src` and `roblox_packages` being siblings. That is the layout pesde generates for consumers, and `default.project.json` mirrors it for development. Don't move `roblox_packages` inside `src`. After changing `default.project.json`, regenerate the sourcemap with `rojo sourcemap default.project.json --output sourcemap.json`.
- Runtime warnings and errors are prefixed with `[HYDROGEN]`. Warn through `Log.warn` (`src/Log/init.luau`, required as `./Log` or `../Log`) so tests can capture it; the text is kept exactly.
- Read time and schedule work through `Clock` (`Clock.now()`, `Clock.delay(...)`, looked up at call time), never `os.clock` / `task.delay` directly, so the fake clock reaches it.
- Match the indentation of the file you edit (most use tabs; some `Network/*` files use 4 spaces).
- Public API changes go through `src/init.luau`. Update this README when the API or a network rule changes.

### Adding a lifecycle hook

A module can give systems a new pair of hooks (as `src/Character` does for `characterAdded` / `characterRemoving`) without touching the App. Register the pair once, when the module loads, with `Definition.hooks` (`src/Definition.luau`):

```luau
local Definition = require("./Definition")

Definition.hooks({
	name = "round",              -- used in scope names: "Arena for round <subject.Name>"
	added = "roundStarted",      -- system:roundStarted(...args)
	removing = "roundEnded",     -- system:roundEnded(...args)
	-- Optional: once per app that has a system defining either hook. Return cleanup for app:stop().
	attach = function(feed: Definition.Feed)
		local connection = Rounds.started:Connect(function(round)
			feed:add(round, { round })        -- yields while hooks run; returns false if not added
		end)
		return function()
			connection:Disconnect()
		end
	end,
	-- Optional: for each player the app adds, before their playerAdded. Must not yield.
	-- Return cleanup, run after their playerRemoving.
	player = function(feed: Definition.Feed, player: Player)
		return nil
	end,
})
```

The feed is the module's handle on one app:

- `feed:add(subject, args, parent?)` runs `added` on every system in dependency order, in the calling thread, with `args` (a table without holes). With a `parent` (a player, or another subject), it first waits for the parent's added hooks, and the subject is removed before the parent. It returns `false` and runs nothing if the subject is already in, the parent isn't in or is being removed, the app has stopped, or the subject is removed before its first hook runs.
- `feed:remove(subject)` runs `removing` in reverse dependency order after the added hooks finished, destroying each system's `Scope.of(system, subject)` right after its hook, and yields until the subject is fully removed (also when another thread is removing it). Unknown subjects are ignored.
- `feed:has(subject)` is true while the subject is in and not being removed.
- `feed:scope(system, subject)` is the system's scope for the subject under this pair. `Scope.of(system, subject)` gives the same scope, except that it looks for a player first and then each pair in the order they attached; one Instance can be a subject of several pairs (a tagged character) with separate lifetimes, so a module whose subjects may overlap should hand out `feed:scope`.

Errors in hooks are warned and the other systems still run. Systems added after start get `added` for subjects already in. An app none of whose systems define either hook never calls `attach` or `player`, so the pair costs nothing. Also add the hook names to `Lifecycle` and to the `WithoutLifecycle` type function in `src/Definition.luau`, so systems type-check and `use` strips them, and require the module from `src/init.luau` (or `src/App.luau` for core hooks) so it registers before any app starts.

### Releasing

1. Bump `version` in `pesde.toml` and run `pesde install` so `pesde.lock` picks it up.
2. Add the release to `CHANGELOG.md`.
3. Point the generator at the new version: `hydrogen` in `tools/create-hydrogen/src/versions.luau` and the `atk422/hydrogen` pin its test checks in `tools/create-hydrogen/test/run.luau`.
4. Run the tests, then check what will be uploaded:

```bash
pesde publish --dry-run
```

5. Merge to `main` once CI passes. CI runs on Linux, so it catches what a Windows run doesn't (process errors, path separators).
6. Publish:

```bash
pesde publish
```

7. Publish the tools that changed, after Hydrogen so they can install it. The generator changes whenever its Hydrogen pin does: from `tools/create-hydrogen/`, bump `version` in `pesde.toml` and `cli` in `src/versions.luau`, run `lune run test/run e2e` (it builds a game from the registry, so the new Hydrogen must be published), then `pesde publish`. The lint launcher only needs a release when `tools/hydrogen-lint/` itself changes: run `lune run test/run.luau` there, then `pesde publish`. Each tool's README has the details.

Only files listed under `includes` in `pesde.toml` are published: the source, `pesde.toml`, `README.md`, `LICENSE`, `CHANGELOG.md`, and the agent docs (`AGENTS.md`, `llms.txt`, `docs/ai/*.md`; see `AGENTS.md` for their format and when to update them). `default.project.json` is deliberately left out so pesde generates the consumer layout.
