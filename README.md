# Hydrogen

A mildly opinionated Luau framework/bootstrapper for Roblox. Hydrogen gives you four things:

- **Systems**: modules with `init` / `start`, player (`playerAdded` / `playerRemoving`) and shutdown (`stop`) hooks that run in dependency order.
- **App**: collects your systems (and network definitions) and boots them.
- **Network**: typed, schema-checked remote events and functions. Nothing fired during startup is lost, because events are queued until the network and each client are ready. Middleware inspects or transforms traffic, and a logger and a rate limiter are built in. Events can be unreliable, and batching and buffer encoding are there when traffic gets heavy.
- **Testing**: `Hydrogen.test` runs your systems with fakes, fake players and a fake clock in one call, checks what was fired with expectations, and always cleans up. It runs in Studio and under Lune, with any test framework. Underneath, `app:replace` swaps a system for a fake and `Hydrogen.loopback` runs server and client systems together in one VM.

Package: `atk422/hydrogen` on the [pesde](https://pesde.dev) registry. Current version: **0.4.0** (see [CHANGELOG.md](CHANGELOG.md)). License: MIT.

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
Hydrogen.Clock          -- time for systems and tests: Clock.now(), wait, delay, heartbeat, fake()
Hydrogen.gt             -- GreenTea, for writing schemas
Hydrogen.Scope          -- cleanup tied to lifetimes: Scope.new(), Scope.of(system, player?)
Hydrogen.Data           -- session-locked DataStore persistence: Data.player, Data.store, Data.memory
Hydrogen.PlayerState    -- per-player state from Data or runtime, replicated per field
Hydrogen.State          -- replicated state: value, map, list, playerValue, playerMap, playerList, computed
Hydrogen.Receipts       -- kit: routes ProcessReceipt and grants each purchase once; add it to the app
```

Types are exported too, for annotations: `Hydrogen.App`, `Hydrogen.Defined<T>`, `Hydrogen.ClientEvent<T...>`, `Hydrogen.ServerEvent<T...>`, `Hydrogen.ClientFunction<A..., R...>`, `Hydrogen.ServerFunction<A..., R...>`, `Hydrogen.MiddlewareContext`, `Hydrogen.Middleware<T...>`, `Hydrogen.AnyMiddleware`, `Hydrogen.LoggerOptions`, `Hydrogen.RateLimitOptions`, `Hydrogen.Namespace`, `Hydrogen.Loopback`, `Hydrogen.AppOptions`, `Hydrogen.Scope`, `Hydrogen.Harness`, `Hydrogen.TestOptions`, `Hydrogen.Expectation`, `Hydrogen.Delivery`, `Hydrogen.FakeClock` and `Hydrogen.FakeClockOptions`. Data adds `Hydrogen.PlayerStore<T>`, `Hydrogen.KeyStore<T>`, `Hydrogen.DataBackend`, `Hydrogen.MemoryBackend` and `Hydrogen.UpdateOnceResult`; PlayerState adds `Hydrogen.PlayerState<S>`. For State: `Hydrogen.StateValue<T>`, `Hydrogen.StateMap<K, V>`, `Hydrogen.StateList<T>`, `Hydrogen.PlayerValue<T>`, `Hydrogen.PlayerMap<K, V>`, `Hydrogen.PlayerList<T>`, `Hydrogen.Computed<T>`, `Hydrogen.StateOptions`, `Hydrogen.PlayerStateOptions` and `Hydrogen.StateSerializer`. For Receipts: `Hydrogen.Receipt`, `Hydrogen.PurchaseDecision`, `Hydrogen.ProductHandler`, `Hydrogen.GamePassHandler`, `Hydrogen.ReceiptStore`, `Hydrogen.ReceiptsOptions`, `Hydrogen.Marketplace`, `Hydrogen.MemoryReceiptStore` and `Hydrogen.FakeMarketplace`.

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
- Dependencies must also be added to the same app, otherwise Hydrogen warns `System X depends on system Y which was not added to the app`.
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
- `stop` runs in reverse dependency order on shutdown. On the server, `app:start()` binds `app:stop()` to `game:BindToClose`. `stop` first runs `playerRemoving` for every player still in the game, waits until every `playerRemoving` hook has returned, then calls the `stop` hooks.
- The hooks for one player run one after another in a single thread, so a hook that yields (a DataStore call) delays the next system's hook for that player. Different players don't wait for each other.
- If a player leaves while their `playerAdded` hooks are still running, `playerRemoving` waits for them to finish. Every system sees `playerAdded` before `playerRemoving` for the same player, and each exactly once.
- A hook that errors is reported with `[HYDROGEN] <hook> failed in system <full name>` and the remaining systems still run, so one broken system can't stop `Data` from saving.
- A system added after `app:start()` gets `playerAdded` for players already in the game.
- The player hooks run on the client too (for every player, including the local one). `stop` is only bound on the server; on the client you can call `app:stop()` yourself.
- For cleanup tied to the system or to a player, ask for a scope with `Hydrogen.Scope.of`. See [Scopes](#scopes).

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

`Scope.of(system)` is the system's scope and `Scope.of(system, player)` its scope for that player. Each is created the first time it's asked for, and every later call returns the same one, so it works the same from a hook, a remote handler, a callback or another system (`Scope.of(Combat, player)`). `Hydrogen.Scope.new(name?)` makes one you destroy yourself.

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
function ChatServer:start()
	Chat.SendMessage:On(function(player, text)
		Chat.MessagePosted:FireAll(player.Name, text)
	end)
end

-- client
function ChatClient:start()
	Chat.MessagePosted:On(function(author, text)
		print(`{author}: {text}`)
	end)
	Chat.SendMessage:Fire("hello")
end
```

### Middleware

Middleware sees, and can replace, every payload going over the wire. It has this shape:

```luau
function(context: Hydrogen.MiddlewareContext, ...): ...
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
- `output: (message: string) -> ()`: where lines go. Defaults to `print`.

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

BattleFrame = Hydrogen.serverEvent("BattleFrame", gt.array(Unit)):Unreliable():Encode(),
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
- `serverFunction`s missing their curried returns, `clientFunction`s without `gt.args` / `gt.returns`, events nothing listens to, names that differ only by case, a State passed to `addNetwork` (which this version of Hydrogen loops on forever), script errors during the boot, and Hydrogen's own boot warnings

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

#### Why it's designed this way

- **One network event per state**, not one channel for everything: each state gets its own GreenTea schema, so the client validates what it receives, `:Encode()` and middleware apply per state, and the logger shows the state's name. Ids come from the same sorted-name rule as every other network object.
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

Under [Hydrogen's Lune runtime](#running-tests-under-lune) every `warn()` is captured, your systems' included. In Studio the harness captures the warnings Hydrogen's network emits (dropped payloads, unknown ids, mismatches); other `warn()` calls print as usual.

#### Time and the fake clock

Hydrogen reads time through `Hydrogen.Clock`, and so can your systems. The harness installs a fake clock, so timers only move when the test says so:

```luau
-- In a system
function Autosave:start()
	task.spawn(function()
		while true do
			Hydrogen.Clock.wait(60)
			Data:saveAll()
		end
	end)
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
- Outside the harness: `local clock = Hydrogen.Clock.fake({ now = 0 })`, then `clock:advance(seconds)`, `clock:next()` (jump to the next timer), `clock:pending()` and `clock:restore()`. Only one fake clock can be installed at a time.

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

Expected output ends with `Tests Ran: 200 | Passed: 200` and `status: OK`. A few `[HYDROGEN]` warnings in the output are expected; tests exercise those paths. The command exits with code 1 on failure. GitHub Actions runs the suite on every push to `main` and every pull request (`.github/workflows/ci.yml`). The setup step installs Lune explicitly, because `pesde run` needs a `lune` executable on the PATH.

### Layout

```
src/
  init.luau            public API and exported types
  App.luau             App: collects systems, runs init -> Network.init -> start, player and stop hooks
  Clock.luau           time sources (now, time, wait, delay, cancel, heartbeat) and the fake clock
  Log.luau             warnings go through here so the test harness can capture them
  Definition.luau      define/use, system ids, dependency graph wiring, replace redirects, lifecycle-stripping type function
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
  Data/
    init.luau          re-exports Stores and its types
    Stores.luau        Data.player / Data.store systems, backend selection
    Store.luau         sessions: load and lock, update, transactions, updateOnce, saving, autosave
    Backend.luau       backend type, in-memory backend, Roblox DataStore backend
    Tables.luau        copy, deep freeze, reconcile, structural sharing
    Clock.luau         Data's time sources, forwarding to Hydrogen.Clock
  PlayerState/
    init.luau          re-exports Define and its types
    Define.luau        PlayerState.new: fields, proxies, lifecycle
    Replication.luau   one State.playerValue per replicated field, per-field audiences, client views
  State/
    init.luau          public API, types, write checks
    Store.luau         cells per context (server / replica), subscriptions, flush, snapshots, receive
    Wire.luau          one serverEvent per state, payload schemas per kind
    Value.luau  Map.luau  List.luau   how each kind diffs, applies and notifies
    Computed.luau      derived state with dependency tracking
    Schedule.luau      the end-of-frame flush, on Hydrogen.Clock
  Receipts/
    init.luau          exports the Receipts system and its types
    Receipts.luau      the system: ProcessReceipt routing, waiting for players, game passes
    Stores.luau        dataStore, memoryStore and fromData (Hydrogen.Data)
    FakeMarketplace.luau  stand-in MarketplaceService for tests
    Types.luau         Receipt, ReceiptStore, Marketplace, options
    Clock.luau  Log.luau  time sources and warnings, forwarding to Hydrogen.Clock and the log; tests can patch them
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
  Lint.luau            the network lint against the fixture games in Fixtures/Lint
  Fixtures/            modules the suites require
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
- Runtime warnings and errors are prefixed with `[HYDROGEN]`. Warn through `Log.warn` (`src/Log.luau`) so tests can capture it.
- Read time and schedule work through `Clock` (`Clock.now()`, `Clock.delay(...)`, looked up at call time), never `os.clock` / `task.delay` directly, so the fake clock reaches it.
- Match the indentation of the file you edit (most use tabs; some `Network/*` files use 4 spaces).
- Public API changes go through `src/init.luau`. Update this README when the API or a network rule changes.

### Releasing

1. Bump `version` in `pesde.toml` and run `pesde install` so `pesde.lock` picks it up.
2. Add the release to `CHANGELOG.md`.
3. Run the tests, then check what will be uploaded:

```bash
pesde publish --dry-run
```

4. Publish:

```bash
pesde publish
```

Only files listed under `includes` in `pesde.toml` are published: the source, `pesde.toml`, `README.md`, `LICENSE`, `CHANGELOG.md`, and the agent docs (`AGENTS.md`, `llms.txt`, `docs/ai/*.md`; see `AGENTS.md` for their format and when to update them). `default.project.json` is deliberately left out so pesde generates the consumer layout.
