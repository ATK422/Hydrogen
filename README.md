# Hydrogen

A mildly opinionated Luau framework/bootstrapper for Roblox. Hydrogen gives you three things:

- **Systems**: modules with `init` / `start` lifecycle hooks that run in dependency order.
- **App**: collects your systems (and network definitions) and boots them.
- **Network**: typed, schema-checked remote events and functions over a single `RemoteEvent` + `RemoteFunction`, with queuing so nothing fired during startup is lost, and middleware (including a built-in logger) for inspecting or transforming traffic.

Package: `atk422/hydrogen` on the [pesde](https://pesde.dev) registry. License: MIT.

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

### Public API

```luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

Hydrogen.App            -- App.new(), then add systems/network, then :start()
Hydrogen.define         -- define a system
Hydrogen.clientEvent    -- client -> server event
Hydrogen.serverEvent    -- server -> client event
Hydrogen.clientFunction -- client -> server request/response
Hydrogen.serverFunction -- server -> client request/response
Hydrogen.useMiddleware  -- add middleware to every network object
Hydrogen.logger         -- build a logging middleware for debugging
Hydrogen.gt             -- GreenTea, for writing schemas
```

Types are exported too, for annotations: `Hydrogen.App`, `Hydrogen.Defined<T>`, `Hydrogen.ClientEvent<T...>`, `Hydrogen.ServerEvent<T...>`, `Hydrogen.ClientFunction<A..., R...>`, `Hydrogen.ServerFunction<A..., R...>`, `Hydrogen.MiddlewareContext`, `Hydrogen.Middleware<T...>`, `Hydrogen.AnyMiddleware` and `Hydrogen.LoggerOptions`.

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

- **The system's `id` is the ModuleScript's name** (e.g. `Logger`). It is read from the calling script, so call `define` at the top level of the module, once per module.
- `init` and `start` are optional and are called with `:` (they receive the system as `self`).
- `use(other)` must be called synchronously inside the constructor. It records the dependency and returns `other` (typed without its lifecycle fields, so you can't call `init`/`start` on it by accident).
- Dependencies must also be added to the same app, otherwise Hydrogen warns `System X depends on system Y which was not added to the app`.
- Circular `use` chains error at `app:start()` with the cycle printed: `Cyclic system dependency: A -> B -> A`.
- Systems with no dependency relationship start in the order they were added.

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

Every `:On` returns a disconnect function. Events can have many listeners; a function has one handler (calling `:On` again replaces it).

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

### Booting the app

Run one app on the server and one on each client.

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

- `App.new()`: a fresh app with its own system list.
- `app:addSystem(system)` / `app:addSystems({ ... })`: add systems directly.
- `app:addSystemsFolders(folderA, folderB, ...)`: require every descendant ModuleScript and add the ones that are systems. Non-systems are skipped with a warning.
- `app:addNetwork(folder)`: require every descendant ModuleScript so their network objects get registered.
- `app:start()`: boot. Systems added after this are `init`ed and `start`ed immediately.

What `app:start()` does, in order:

1. Sorts systems so dependencies come first.
2. Calls every `init`.
3. Starts the network. The server creates `ReplicatedStorage.HydrogenNetworkRemoteEvent` and `HydrogenNetworkRemoteFunction`. **On the client this yields** until those exist and until the server hands back any events queued for this player.
4. Calls every `start`.

### Network rules (read these before debugging)

- **Register every network object before `app:start()`.** Objects created after the network starts are ignored with `[HYDROGEN] Network already initialized ignoring X registration`.
- **The server and the client must register the same set of names.** Wire ids are assigned by sorting names alphabetically on each side, so a name that exists on one side only shifts every id after it. Put definitions in shared modules and `addNetwork` the same folder on both sides.
- Names must be unique. Duplicates warn and are ignored.
- Events fired before the network starts (e.g. in `init`) are queued and sent once it does. Server events aimed at a player whose client hasn't finished starting are held and delivered on that client's handshake.
- **Functions are not queued.** Only call `clientFunction:Fire` / `serverFunction:Fire` from `start` or later; calling one earlier errors with `called before the network started`.
- `serverFunction:Fire` invokes a single client and yields until it answers.
- Middleware added after a message is queued does not run on it; add middleware before firing anything.

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

Expected output ends with `Tests Ran: 36 | Passed: 36` and `status: OK`. A few `[HYDROGEN]` warnings in the output are expected; tests exercise those paths. The command exits with code 1 on failure. GitHub Actions runs the suite on every push to `main` and every pull request (`.github/workflows/ci.yml`). The setup step installs Lune explicitly, because `pesde run` needs a `lune` executable on the PATH.

### Layout

```
src/
  init.luau            public API and exported types
  App.luau             App: collects systems, runs init -> Network.init -> start
  Definition.luau      define/use, system ids, dependency graph wiring, lifecycle-stripping type function
  Graph.luau           generic dependency graph with topological sort and cycle detection
  Network/
    init.luau          exports constructors and Network.init
    Runtime.luau       remotes, name->id mapping, queues, ready handshake, dispatch
    Middleware.luau    middleware context/types, onion ordering, global middleware, logger
    ClientEvent.luau   ServerEvent.luau  ClientFunction.luau  ServerFunction.luau
test/
  _run.luau            Lune entry point: mocks Roblox globals, patches require, runs suites
  App.luau  Definition.luau  Graph.luau  Network.luau
default.project.json   Rojo project for development (see below)
pesde.toml             package manifest, scripts, dependencies, version
```

### How the tests run

Tests run outside Roblox under Lune. `test/_run.luau`:

- builds a DataModel with `@lune/roblox` and sets the `game` / `Instance` globals;
- stubs `RunService` so `IsClient()` and `IsServer()` both return `false` (remotes and the handshake are not exercised end to end);
- overrides `require` so `@self/` and relative paths resolve from the calling file, and redirects GreenTea to its pesde install path;
- calls each test module, then runs [frktest](https://github.com/itsfrank/frktest).

To add a test file: create `test/Thing.luau` that returns a function registering `test.suite(...)` blocks (copy the shape of `test/Graph.luau`), then add `require("./Thing")()` next to the others in `test/_run.luau`. The Network suite resets `Runtime` state in `test.on_suite_enter`; do the same if you touch Runtime.

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
