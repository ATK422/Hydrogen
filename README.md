# Hydrogen

A mildly opinionated Luau framework/bootstrapper for Roblox. Hydrogen gives you four things:

- **Systems**: modules with `init` / `start`, player (`playerAdded` / `playerRemoving`) and shutdown (`stop`) hooks that run in dependency order.
- **App**: collects your systems (and network definitions) and boots them.
- **Network**: typed, schema-checked remote events and functions. Nothing fired during startup is lost, because events are queued until the network and each client are ready. Middleware inspects or transforms traffic, and a logger and a rate limiter are built in. Events can be unreliable, and batching and buffer encoding are there when traffic gets heavy.
- **Testing**: `Hydrogen.test` runs your systems with fakes, fake players and a fake clock in one call, checks what was fired with expectations, and always cleans up. It runs in Studio and under Lune, with any test framework. Underneath, `app:replace` swaps a system for a fake and `Hydrogen.loopback` runs server and client systems together in one VM.

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
Hydrogen.test           -- one call per test: loopback, fake clock, app, fakes, players, expectations
Hydrogen.harness        -- the same harness for frameworks with setup/teardown hooks
Hydrogen.Clock          -- time for systems and tests: Clock.now(), wait, delay, heartbeat, fake()
Hydrogen.gt             -- GreenTea, for writing schemas
```

Types are exported too, for annotations: `Hydrogen.App`, `Hydrogen.Defined<T>`, `Hydrogen.ClientEvent<T...>`, `Hydrogen.ServerEvent<T...>`, `Hydrogen.ClientFunction<A..., R...>`, `Hydrogen.ServerFunction<A..., R...>`, `Hydrogen.MiddlewareContext`, `Hydrogen.Middleware<T...>`, `Hydrogen.AnyMiddleware`, `Hydrogen.LoggerOptions`, `Hydrogen.RateLimitOptions`, `Hydrogen.Namespace`, `Hydrogen.Loopback`, `Hydrogen.AppOptions`, `Hydrogen.Harness`, `Hydrogen.TestOptions`, `Hydrogen.Expectation`, `Hydrogen.Delivery`, `Hydrogen.FakeClock` and `Hydrogen.FakeClockOptions`.

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

Expected output ends with `Tests Ran: 106 | Passed: 106` and `status: OK`. A few `[HYDROGEN]` warnings in the output are expected; tests exercise those paths. The command exits with code 1 on failure. GitHub Actions runs the suite on every push to `main` and every pull request (`.github/workflows/ci.yml`). The setup step installs Lune explicitly, because `pesde run` needs a `lune` executable on the PATH.

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
  Testing/
    init.luau          Hydrogen.test and Hydrogen.harness
    Expect.luau        expectations on deliveries, argument matching, failure messages
    Lune.luau          Lune runtime: Roblox globals and a Roblox-style require (shipped for game tests)
test/
  _run.luau            Lune entry point: installs the Lune runtime, runs suites
  App.luau  Clock.luau  Definition.luau  Graph.luau  Network.luau
  Testing.luau         Hydrogen.test, app:replace and Hydrogen.loopback, used the way a game's tests would
  Fixtures/            modules the suites require
default.project.json   Rojo project for development (see below)
pesde.toml             package manifest, scripts, dependencies, version
```

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

Only files listed under `includes` in `pesde.toml` are published: the source, `pesde.toml`, `README.md`, `LICENSE` and `CHANGELOG.md`. `default.project.json` is deliberately left out so pesde generates the consumer layout.
