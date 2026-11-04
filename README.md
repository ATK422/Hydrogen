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
Hydrogen.Receipts       -- kit: routes ProcessReceipt and grants each purchase once; add it to the app
```

Types are exported too, for annotations: `Hydrogen.App`, `Hydrogen.Defined<T>`, `Hydrogen.ClientEvent<T...>`, `Hydrogen.ServerEvent<T...>`, `Hydrogen.ClientFunction<A..., R...>`, `Hydrogen.ServerFunction<A..., R...>`, `Hydrogen.MiddlewareContext`, `Hydrogen.Middleware<T...>`, `Hydrogen.AnyMiddleware`, `Hydrogen.LoggerOptions`, `Hydrogen.RateLimitOptions`, `Hydrogen.Namespace`, `Hydrogen.Loopback` and `Hydrogen.AppOptions`. For Receipts: `Hydrogen.Receipt`, `Hydrogen.PurchaseDecision`, `Hydrogen.ProductHandler`, `Hydrogen.GamePassHandler`, `Hydrogen.ReceiptStore`, `Hydrogen.ReceiptsOptions`, `Hydrogen.Marketplace`, `Hydrogen.MemoryReceiptStore` and `Hydrogen.FakeMarketplace`.

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
- **Handlers grant; they don't save.** Change the player's data and return. Saving is the store's job, and the store decides when the purchase counts as granted. Return `false` to decline for now; an error does the same, with a warning.
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
- **Your data system as the store** (recommended): implement `Hydrogen.ReceiptStore` on top of your player data, keeping the processed purchase ids in the player's profile. Keep that list bounded (the last few hundred ids is plenty), and don't let a save go out while `record` is between `grant()` and adding the id.

```luau
export type ReceiptStore = {
	-- Optional. Yield until the player's record can be read; return false if it failed to load.
	load: ((self, player: Player) -> boolean?)?,
	-- Was this purchase granted already (saved or not)? Error if you can't tell.
	isGranted: (self, player: Player, receipt: Receipt) -> boolean,
	-- Call grant(), add receipt.PurchaseId to the profile in the same save, and return once
	-- that save succeeded. If grant() errors, record nothing and let the error through.
	-- Error if the save fails.
	record: (self, player: Player, receipt: Receipt, grant: () -> ()) -> (),
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

Expected output ends with `Tests Ran: 100 | Passed: 100` and `status: OK`. A few `[HYDROGEN]` warnings in the output are expected; tests exercise those paths. The command exits with code 1 on failure. GitHub Actions runs the suite on every push to `main` and every pull request (`.github/workflows/ci.yml`). The setup step installs Lune explicitly, because `pesde run` needs a `lune` executable on the PATH.

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
  Receipts/
    init.luau          exports the Receipts system and its types
    Receipts.luau      the system: ProcessReceipt routing, waiting for players, game passes
    Stores.luau        dataStore and memoryStore
    FakeMarketplace.luau  stand-in MarketplaceService for tests
    Types.luau         Receipt, ReceiptStore, Marketplace, options
    Clock.luau  Log.luau  time sources and warnings, called through tables tests can patch
test/
  _run.luau            Lune entry point: mocks Roblox globals, patches require, runs suites
  App.luau  Definition.luau  Graph.luau  Network.luau
  Testing.luau         app:replace and Hydrogen.loopback, used the way a game's tests would
  Receipts.luau        Hydrogen.Receipts with a fake marketplace and memory store
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
