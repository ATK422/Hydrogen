# Hydrogen

A mildly opinionated Luau framework/bootstrapper for Roblox. Hydrogen gives you three things:

- **Systems**: modules with `init` / `start` lifecycle hooks that run in dependency order.
- **App**: collects your systems (and network definitions) and boots them.
- **Network**: typed, schema-checked remote events and functions over a single `RemoteEvent` + `RemoteFunction`, with queuing so nothing fired during startup is lost.

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

Hydrogen validates network payloads with [GreenTea](https://github.com/corecii/greentea) (`corecii/greentea`). Add it to your own project too, so you can write the schemas:

```bash
pesde add corecii/greentea --alias gt
```

### Public API

```luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

Hydrogen.App            -- App.new(), then add systems/network, then :start()
Hydrogen.define         -- define a system
Hydrogen.clientEvent    -- client -> server event
Hydrogen.serverEvent    -- server -> client event
Hydrogen.clientFunction -- client -> server request/response
Hydrogen.serverFunction -- server -> client request/response
```

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
local gt = require(ReplicatedStorage.roblox_packages.gt)

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

Payloads are checked against the schema with `assert` on fire, and function arguments/returns are checked on both ends, so bad data errors instead of travelling silently.

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
- **Functions are not queued.** Only call `clientFunction:Fire` / `serverFunction:Fire` from `start` or later.
- `serverFunction:Fire` invokes a single client and yields until it answers.
- Note: on the server, `clientEvent` listeners receive `player` as their first argument even though the Luau type of `:On` doesn't show it yet.

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

Expected output ends with `Tests Ran: 24 | Passed: 24` and `status: OK`. A few `[HYDROGEN]` warnings in the output are expected; tests exercise those paths. The command exits with code 1 on failure.

### Layout

```
src/
  init.luau            public API (App, define, clientEvent, serverEvent, clientFunction, serverFunction)
  App.luau             App: collects systems, runs init -> Network.init -> start
  Definition.luau      define/use, system ids, dependency graph wiring, lifecycle-stripping type function
  Graph.luau           generic dependency graph with topological sort and cycle detection
  Network/
    init.luau          exports constructors and Network.init
    Runtime.luau       remotes, name->id mapping, queues, ready handshake, dispatch
    ClientEvent.luau   ServerEvent.luau  ClientFunction.luau  ServerFunction.luau
test/
  _run.luau            Lune entry point: mocks Roblox globals, patches require, runs suites
  App.luau  Definition.luau  Graph.luau  Network.luau
default.project.json   Rojo project (src + optional roblox_packages)
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

- Every file is `--!strict` (also set in `.luaurc` / `src/.luaurc`). Keep code type-checking clean.
- Requires: `@self/...` from `init.luau` files, `./...` or `../...` elsewhere. Network modules load GreenTea from `../../roblox_packages/gt`.
- Runtime warnings and errors are prefixed with `[HYDROGEN]`.
- Match the indentation of the file you edit (most use tabs; some `Network/*` files use 4 spaces).
- Public API changes go through `src/init.luau`. Update this README when the API or a network rule changes.

### Releasing

Bump `version` in `pesde.toml`, run the tests, then publish:

```bash
pesde publish
```

Only files listed under `includes` in `pesde.toml` (`src/**/*.luau`, `src/.luaurc`, `pesde.toml`) are published.
