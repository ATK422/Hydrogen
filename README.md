# Hydrogen

A mildly opinionated Luau framework/bootstrapper for Roblox. Hydrogen gives you four things:

- **Systems**: modules with `init` / `start`, player (`playerAdded` / `playerRemoving`) and shutdown (`stop`) hooks that run in dependency order.
- **App**: collects your systems (and network definitions) and boots them.
- **Network**: typed, schema-checked remote events and functions. Nothing fired during startup is lost, because events are queued until the network and each client are ready. Middleware inspects or transforms traffic, and a logger and a rate limiter are built in. Events can be unreliable, and batching and buffer encoding are there when traffic gets heavy.
- **Testing**: swap a system for a fake with `app:replace`, and run server and client systems together in one VM with `Hydrogen.loopback`.

Package: `atk422/hydrogen` on the [pesde](https://pesde.dev) registry. Current version: **0.4.0** (see [CHANGELOG.md](CHANGELOG.md)). License: MIT.

---

## Part 1: Using Hydrogen in a game

### Install

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
Hydrogen.gt             -- GreenTea, for writing schemas
Hydrogen.Data           -- session-locked DataStore persistence: Data.player, Data.store, Data.memory
Hydrogen.PlayerState    -- per-player state from Data or runtime, replicated per field
```

Types are exported too, for annotations: `Hydrogen.App`, `Hydrogen.Defined<T>`, `Hydrogen.ClientEvent<T...>`, `Hydrogen.ServerEvent<T...>`, `Hydrogen.ClientFunction<A..., R...>`, `Hydrogen.ServerFunction<A..., R...>`, `Hydrogen.MiddlewareContext`, `Hydrogen.Middleware<T...>`, `Hydrogen.AnyMiddleware`, `Hydrogen.LoggerOptions`, `Hydrogen.RateLimitOptions`, `Hydrogen.Namespace`, `Hydrogen.Loopback` and `Hydrogen.AppOptions`. Data adds `Hydrogen.PlayerStore<T>`, `Hydrogen.KeyStore<T>`, `Hydrogen.DataBackend`, `Hydrogen.MemoryBackend` and `Hydrogen.UpdateOnceResult`; PlayerState adds `Hydrogen.PlayerState<S>`.

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

The id is recorded in the same commit as the change, in the record's own metadata (the last 100 ids are kept), and `updateOnce` only reports success once a save holding both has gone through. If the save fails, the grant stays in memory without being repeated, and the next call for that id saves before answering `"duplicate"`.

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

### Testing your systems

Two tools let a test start real systems without a running game: `app:replace` swaps a dependency for a fake, and `Hydrogen.loopback()` stands in for the remotes so client and server systems can talk in one VM. Both work under [Lune](https://lune-org.github.io/docs) and in Studio. `test/Testing.luau` in this repository has runnable examples.

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
- `net:client()`: the client the running code acts as, inside `as` or inside a server event or function handler running on that client. Every fake client shares the same client-side listeners, so this is how a test tells them apart.
- `net:close()`: everyone leaves, listeners and middleware added since the loopback opened are removed, and the network stops so the next test can start it again. Network names stay registered.

How it differs from real remotes:

- Messages still go through ids, middleware in both directions, schema validation, and the queue and handshake rules above. An invalid payload is dropped with the same warning.
- Delivery is immediate: when `Fire` returns, listeners have already run up to their first yield. Each event handler gets its own thread, so its errors are reported as `[HYDROGEN] Loopback event handler failed` instead of reaching the sender. Function errors reach the caller, as with `InvokeServer`.
- Tables are copied and lose their metatables, as remotes do. Unreliable events are delivered reliably.
- Fake players are tables with `Name`, `DisplayName`, `UserId` (negative), `Parent` and `Kick` (which makes them leave). They aren't Instances, so `player:IsA(...)` and other Instance methods don't exist on them.
- `RunService:IsServer()` and `IsClient()` still return what the host says, so systems that branch on them see the same answer on both sides.
- Under Lune, a network that an app started without a loopback is reset when the next loopback opens. In Studio, open the loopback before any app starts.

Systems are still module singletons: state a system keeps in its own tables lives across tests in the same VM. Reset it in `init`, or use one test file per scenario.

#### Design: why `replace` redirects the original

`use(Other)` runs once, when the dependent module is required, and returns the `Other` table. By the time a test calls `replace`, every dependent already holds that table. Two ways to make them reach a fake were considered:

- **`use` returns a forwarding proxy** whose target can be swapped. Dependents would reach the fake without the original being touched. But every field access from a dependent would go through a metatable in every game, test or not. `self` inside the original's methods would be the proxy, so `self == Data` breaks and writes need forwarding too. And modules that `require` a system without `use` would still see the original.
- **`replace` redirects the original table** (chosen). While the app runs, the original is emptied and given a metatable that forwards reads and writes to the fake; `stop` restores its fields and metatable. Games that never call `replace` pay nothing, and every holder of the table reaches the fake, whether it got it from `use` or `require`. The costs: the original is mutated while the app runs, frozen tables and locked metatables can't be replaced, and functions copied out of a dependency before the swap keep pointing at the original.

**Replacements belong to an app, but act on the whole VM while that app runs.** Systems are constructed once per VM, at require time, so every app shares one `Data` table; a swap can't be visible to one app and not another. An app records its replacements, applies them at `start` and undoes them at `stop`, and two running apps can't replace the same system.

**The dependency graph and network runtime stay module-global.** Moving them into each app wouldn't isolate apps, because the systems and network objects themselves are module singletons. Real isolation would need `define` to build a fresh system per app, so `require(DataSystem)` would return a definition instead of the system, which breaks every game that calls systems directly. For tests, `app:stop()` and `loopback:close()` undo what a test changes instead.

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

Expected output ends with `Tests Ran: 105 | Passed: 105` and `status: OK`. A few `[HYDROGEN]` warnings in the output are expected; tests exercise those paths. The command exits with code 1 on failure. GitHub Actions runs the suite on every push to `main` and every pull request (`.github/workflows/ci.yml`). The setup step installs Lune explicitly, because `pesde run` needs a `lune` executable on the PATH.

### Layout

```
src/
  init.luau            public API and exported types
  App.luau             App: collects systems, runs init -> Network.init -> start, player and stop hooks
  Definition.luau      define/use, system ids, dependency graph wiring, replace redirects, lifecycle-stripping type function
  Graph.luau           generic dependency graph with topological sort and cycle detection
  Network/
    init.luau          exports constructors and Network.init
    Runtime.luau       remotes, name->id mapping, queues, batching, ready handshake, dispatch
    Middleware.luau    middleware context/types, onion ordering, global middleware, logger
    Codec.luau         schema-driven buffer encoding for :Encode()
    Loopback.luau      in-memory remotes and fake players for headless tests
    ClientEvent.luau   ServerEvent.luau  ClientFunction.luau  ServerFunction.luau
  Data/
    init.luau          re-exports Stores and its types
    Stores.luau        Data.player / Data.store systems, backend selection
    Store.luau         sessions: load and lock, update, transactions, updateOnce, saving, autosave
    Backend.luau       backend type, in-memory backend, Roblox DataStore backend
    Tables.luau        copy, deep freeze, reconcile, structural sharing
    Clock.luau         time sources, swappable by tests
  PlayerState/
    init.luau          re-exports Define and its types
    Define.luau        PlayerState.new: fields, proxies, lifecycle
    Replication.luau   per-field audiences, coalesced sends, client replicas
test/
  _run.luau            Lune entry point: mocks Roblox globals, patches require, runs suites
  App.luau  Definition.luau  Graph.luau  Network.luau
  Testing.luau         app:replace and Hydrogen.loopback, used the way a game's tests would
  Data.luau  PlayerState.luau
default.project.json   Rojo project for development (see below)
pesde.toml             package manifest, scripts, dependencies, version
```

### How the tests run

Tests run outside Roblox under Lune. `test/_run.luau`:

- builds a DataModel with `@lune/roblox` and sets the `game` / `Instance` / `task` globals;
- stubs `RunService` so `IsClient()` and `IsServer()` both return `false`. Real remotes and the `Players` / `BindToClose` connections are never exercised. `test/Testing.luau` runs the network end to end through `Hydrogen.loopback()`; the other suites call `app:_addPlayer` / `app:_removePlayer` with fake players;
- overrides `require` so `@self/` and relative paths resolve from the calling file, and redirects GreenTea to its pesde install path. Lune can't require Instances, so a test sets `_G.instanceModules[moduleScript] = value` and `require(moduleScript)` then returns `value`;
- calls each test module, runs [frktest](https://github.com/itsfrank/frktest), then exits with `process.exit`. The explicit exit matters: the server function timeout test yields the main thread and resumes it from a timer, and without the exit Lune can keep running after the last suite.

To add a test file: create `test/Thing.luau` that returns a function registering `test.suite(...)` blocks (copy the shape of `test/Graph.luau`), then add `require("./Thing")()` next to the others in `test/_run.luau`. The Network and Testing suites reset `Runtime` state in `test.on_suite_enter`; do the same if you touch Runtime. The Testing suite also stops its apps and closes its loopbacks in `test.on_test_leave`, so a failed test doesn't leak a running network into the next one.

### Conventions

- Strict mode is on for every file through `.luaurc` / `src/.luaurc`. Keep code type-checking clean.
- Requires: `@self/...` from `init.luau` files, `./...` or `../...` elsewhere. GreenTea is loaded by relative path (`./roblox_packages/gt` from `src/init.luau`, `../../roblox_packages/gt` from `src/Network/*`).
- Those paths rely on `src` and `roblox_packages` being siblings. That is the layout pesde generates for consumers, and `default.project.json` mirrors it for development. Don't move `roblox_packages` inside `src`. After changing `default.project.json`, regenerate the sourcemap with `rojo sourcemap default.project.json --output sourcemap.json`.
- Runtime warnings and errors are prefixed with `[HYDROGEN]`.
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

Only files listed under `includes` in `pesde.toml` are published: the source, `pesde.toml`, `README.md`, `LICENSE` and `CHANGELOG.md`. `default.project.json` is deliberately left out so pesde generates the consumer layout.
