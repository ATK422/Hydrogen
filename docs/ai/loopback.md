# Hydrogen testing primitives (`app:replace`, `Hydrogen.loopback`)

> Two low-level tools for testing real systems without a running game: `app:replace` swaps a dependency for a fake, and `Hydrogen.loopback()` replaces the remotes with in-memory ones, so one VM plays the server and any number of fake clients. Both work under Lune and in Studio. For everyday tests, prefer the harness in `testing.md`, which wraps these and tears down for you.

## Use it when / Don't use it when

- Use `replace` to isolate a system from a slow or external dependency (DataStores, MarketplaceService, another team's system).
- Use `loopback` to test server and client systems talking to each other, with real ids, middleware, validation and the handshake.
- Don't use either in production code.
- Don't hand-roll fake remotes. Use `loopback`.

## Quick start

```luau
local Hydrogen = require(path.to.hydrogen)
local Shop = require(Systems.Shop)        -- does `local Data = use(DataSystem)`
local DataSystem = require(Systems.Data)

local fakeData = {
	getCoins = function(_player: Player): number
		return 500
	end,
}

local net = Hydrogen.loopback()           -- open BEFORE app:start()
local alice = net:join("Alice")

local app = Hydrogen.App.new()
app:addSystem(Shop)
app:replace(DataSystem, fakeData)
app:start()

-- exercise Shop; every Data.getCoins call it makes reaches fakeData

app:stop()   -- always
net:close()  -- always
```

## API

`app:replace(original: Defined<any>, fake: { [any]: any })` must be called before `app:start()`.

`Hydrogen.loopback(): Loopback`

| Method | Notes |
| --- | --- |
| `net:join(name: string?): Player` | Adds a fake client. Apps run `playerAdded` for it. Once the network runs, it does the ready handshake, so queued events are delivered. |
| `net:leave(player: Player)` | The player leaves. Apps run `playerRemoving`, and later sends to the player are dropped. |
| `net:players(): { Player }` | The players still in. `FireAll` and `FireExcept` target these. |
| `net:as(player: Player, fn: (...any) -> ...any, ...any): ...any` | Runs `fn` as that client. Client fires inside it come from `player`. |
| `net:client(): Player?` | The client the running code acts as: inside `as`, or inside a server event or function handler delivered to that client. |
| `net:close()` | Everyone leaves. Listeners and middleware added since the loopback opened are removed, and the network stops so the next test can start it again. Names stay registered. |

## Rules

**`replace`:**

- The fake takes the original's place in the boot order: its hooks run where the original's would have, and the original's hooks don't run. A fake's own `use` calls don't move it.
- While the app runs, **the original table forwards to the fake**, so every holder of the table (through `use` or `require`) reaches the fake. `app:stop()`, or a boot that errors, puts the original back.
- Only one running app can replace a given system at a time.
- Systems with frozen tables or locked metatables can't be replaced.

**`loopback`:**

- Open it before `app:start()`. Only one can be open at a time.
- With **exactly one** client joined, client code needs no `as`. With several, a client send outside `as` errors.
- Delivery is immediate: when `Fire` returns, listeners have already run up to their first yield. Each event handler runs in its own thread; its errors are warned, not raised to the sender. Function errors do reach the caller.
- Tables are copied and lose their metatables, as with real remotes. Unreliable events are delivered reliably. Batching is skipped.
- Fake players are tables with `Name`, `DisplayName`, `UserId` (negative), `Parent` and `Kick` (which makes them leave). They aren't Instances, so `player:IsA(...)` and other Instance methods don't exist.
- `RunService:IsServer()` and `IsClient()` return what the host says, on both "sides".
- Systems are module singletons, so their state persists across tests in one VM. Reset it in `init`, or use one test file per scenario.

## Recipes

**Two clients, one sending.**

```luau
local net = Hydrogen.loopback()
local alice = net:join("Alice")
local bob = net:join("Bob")

local app = Hydrogen.App.new()
app:addSystems({ ChatServer, ChatClient })
app:start()

net:as(bob, function()
	Remotes.SendMessage:Fire("hi")
end)
```

**Telling clients apart in a client listener.**

```luau
local received: { [Player]: { string } } = {}

Remotes.MessagePosted:On(function(author, text)
	local me = net:client() :: Player
	received[me] = received[me] or {}
	table.insert(received[me], text)
end)
```

**A player leaving mid-operation.**

```luau
local alice = net:join("Alice")
app:start()
net:leave(alice) -- playerRemoving runs, in reverse dependency order
```

**Always tearing down, even when an assertion fails.**

```luau
local ok, err = pcall(runScenario)
app:stop()
net:close()
if not ok then
	error(err, 0)
end
```

## Mistakes

- Don't open the loopback after `app:start()`. It errors.
- Don't forget `app:stop()` and `net:close()`. A leaked network breaks the next test. Use the harness (`testing.md`) to make teardown automatic.
- Don't copy functions out of a dependency in a constructor (`local get = use(Data).get`). `replace` can't reach them.
- Don't call Instance methods on fake players.
- Don't assume fresh system state per test.

## Testing

This file is about testing. The harness, expectations and the fake clock are in `testing.md` and `clock.md`.

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] A loopback is already open; close it before opening another` | The previous test leaked one. Call `net:close()`. |
| `[HYDROGEN] Open the loopback before app:start(); the network is already running` | Reorder the setup. |
| `[HYDROGEN] A client sent a message over loopback before any client joined; ...` | Call `net:join()` first. |
| `[HYDROGEN] N loopback clients have joined; wrap client code in loopback:as(player, fn) ...` | Say which client is sending. |
| `[HYDROGEN] loopback:as expects a player from loopback:join()` | Pass a loopback player. |
| `[HYDROGEN] Can't invoke <name>: the player has left` | A server function targeted a player who left. |
| `[HYDROGEN] Loopback event handler failed: ...` | A listener errored during a test. |
| `[HYDROGEN] System X is already replaced by a running app; stop that app first` | Stop the earlier test's app. |
| `[HYDROGEN] Can't replace system X: its table is frozen` / `its metatable is locked` | Don't freeze system tables. |
| `[HYDROGEN] replace expects a system made with Hydrogen.define as the original` | Pass the system itself. |

## Works with

`testing.md` (the harness), `clock.md` (fake time), `systems.md`, `network.md`.
