# Hydrogen.App

> The App collects your systems and network definitions and boots them. Run exactly one app on the server and one on each client.

## Use it when / Don't use it when

- Use it once per side, in `Main.server.luau` and `Main.client.luau`.
- Don't create a second app on the same side. The dependency graph and the network runtime are VM-global, so a second app shares them instead of getting its own. The exception is tests under `Hydrogen.loopback()`.

## Quick start

```luau
-- ServerScriptService/Main.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage.Network)          -- requires every ModuleScript under it
app:addSystemsFolders(ServerScriptService.Systems) -- adds every system under it
app:start()
```

```luau
-- StarterPlayer/StarterPlayerScripts/Main.client.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage:WaitForChild("Network"))
app:addSystemsFolders(ReplicatedStorage:WaitForChild("ClientSystems"))
app:start() -- yields until the server's remotes exist and the handshake is done
```

## API

| Signature | Notes |
| --- | --- |
| `Hydrogen.App.new(options: AppOptions?): App` | Creates a fresh app with its own system list. |
| `AppOptions.debug: boolean?` | Prints the total boot time and each system's `init`/`start` time, slowest first. |
| `AppOptions.output: ((string) -> ())?` | Where debug output goes. Defaults to `print`. |
| `AppOptions.batching: boolean?` | Sends each frame's events as one remote call per target (see `network-performance.md`). |
| `app:addSystem(system)` | Adds one system. |
| `app:addSystems(systems: { System })` | Adds several systems. |
| `app:addSystemsFolders(...: Instance)` | Requires every ModuleScript in each instance (and the instance itself, if it's a ModuleScript) and adds the systems. Skips non-systems with a warning. |
| `app:addNetwork(...: Instance)` | Requires every ModuleScript in each instance so its network objects get registered. Warns if none are found. |
| `app:replace(original, fake: {})` | Tests only, before `start`: swaps a system for a fake (see `loopback.md`). |
| `app:start()` | Boots the app. Yields on the client. Systems added afterwards are `init`ed and `start`ed immediately. |
| `app:stop()` | Runs the shutdown sequence once. Bound to `BindToClose` on the server; call it yourself on the client or in tests. |

Type: `Hydrogen.App`, `Hydrogen.AppOptions`.

## Rules

What `app:start()` does, in order:

1. Adds every system that an added system `use`s (transitively) that wasn't added, then sorts systems so dependencies come first.
2. Runs every `init`.
3. Starts the network. The server creates `ReplicatedStorage.HydrogenNetworkRemoteEvent`, `HydrogenNetworkUnreliableRemoteEvent` and `HydrogenNetworkRemoteFunction`. The client yields until they exist and the server has flushed this player's queued events.
4. Runs every `start`.
5. Runs `playerAdded` for players already in the game, then for every later join, and `characterAdded` for their characters once a system defines it. On the server, binds `app:stop()` to `BindToClose`.

More rules:

- Register every network object (call `addNetwork`) **before** `app:start()`. Later registrations are ignored.
- `addNetwork` must cover the **same set of names** on the server and on the client. Wire ids come from the sorted names.
- On the client, `WaitForChild` anything outside the LocalScript's own descendants before passing it in. Both adders take any `Instance`, so you don't need a cast.
- `batching` must be decided in `App.new`, before the network starts. Turn it on for both apps.
- `app:stop()` runs `characterRemoving` and then `playerRemoving` for remaining players, waits for all of them, runs the `stop` hooks, and restores any `replace`d systems.
- `app:addSystem(X)` after `start` also adds and boots what `X` uses that isn't in the app yet, first. Adding the same system twice after start does nothing.

## Recipes

**Boot timings while optimizing startup.**

```luau
local app = Hydrogen.App.new({ debug = true })
```

**Several folders, including shared client code.**

```luau
local playerScripts = script.Parent
app:addSystemsFolders(script.Systems, playerScripts:WaitForChild("common"))
```

**Heavy traffic.**

```luau
local app = Hydrogen.App.new({ batching = true }) -- on both server and client
```

## Mistakes

- Don't call `app:start()` before `addNetwork`. Objects registered after the network starts are ignored.
- Don't add a network folder on only one side. That gives a `NETWORK MISMATCH`, and messages reach the wrong objects.
- Don't put systems and network definitions in the same folder. `addSystemsFolders` warns about every non-system module it finds.
- Don't create an app per feature. Use one app per side and add systems to it.
- Don't call `stop` hooks or save data from your own `BindToClose`. Hydrogen already binds `app:stop()`.

## Testing

In a test, create the app after opening `Hydrogen.loopback()`, and always call `app:stop()` and `net:close()` at the end (see `loopback.md`). The test harness does both for you (see `testing.md`).

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] addNetwork found no network objects in <name>` | Usually the wrong instance was passed. Point it at the folder that holds the network modules. |
| `[HYDROGEN] addSystemsFolders found no systems in <name>` | Same as above, for systems. |
| `[HYDROGEN] Network already initialized ignoring X registration` | A network object was created after `app:start()`. Move it into a module that `addNetwork` loads. |
| `[HYDROGEN] Booted N systems in Xms (network Yms)` | Debug output from `debug = true`. |
| `[HYDROGEN] Added <Y>: <X> uses it` | Debug output from `debug = true`: `Y` wasn't added, so the app added it because `X` uses it. Add it yourself to silence it, or leave it. |
| `[HYDROGEN] replace must be called before app:start()` | Move the `replace` call earlier. |

## Works with

`systems.md`, `network.md`, `loopback.md`, and the kit modules, which you add to the app like any other system.
