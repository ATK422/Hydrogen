# Hydrogen.Debug

> Network stats per network object (calls/s, estimated bytes/s, drops, function latency) that you can read anywhere with `Debug.stats()`, plus a client developer overlay (toggled by a key) showing boot timings, the network table, `Hydrogen.State`, a player's Data/PlayerState and recent `[HYDROGEN]` warnings; server data is sent only to authorized players.

## Use it when / Don't use it when

Use it when:
- you want to see which network objects are busy, how many bytes they move, or whether messages are being dropped (rate limits, invalid payloads);
- you want function round-trip and handler times;
- you want an in-game panel in Studio, or for staff in live servers, showing state, player data and warnings;
- you want to assert traffic in a test (`Debug.stats()` under `Hydrogen.test`).

Don't use it when:
- you need exact wire bytes: sizes are estimates of the plain values (see Rules);
- you want per-message logs: use `Hydrogen.logger()` middleware;
- you want to edit data from the panel: the overlay is read-only by design.

## Quick start

```luau
-- ServerScriptService/Main.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local PlayerData = require(ServerScriptService.Systems.PlayerData) -- a Hydrogen.Data.player store

Hydrogen.Debug.configure({
	users = { 12345678 },        -- who may open it in live servers (Studio is always allowed)
	inspect = { PlayerData },    -- shown in the Player tab
})

local app = Hydrogen.App.new({ debug = true, output = Hydrogen.Debug.bootOutput })
app:addSystemsFolders(ServerScriptService.Systems)
app:addSystem(Hydrogen.Debug)
app:start()
```

```luau
-- StarterPlayerScripts/Main.client.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new({ debug = true, output = Hydrogen.Debug.bootOutput })
app:addSystem(Hydrogen.Debug) -- on BOTH sides, before start
app:start()
-- Press F3 to open the overlay.
```

Stats alone, no system needed:

```luau
Hydrogen.Debug.enableStats()
-- later
local buy = Hydrogen.Debug.stats()["Shop/Buy"]
print(buy.inPerSecond, buy.inBytesPerSecond, buy.dropped)
```

## API

```luau
local Debug = Hydrogen.Debug

-- Stats: either side, no system needed. Per side: the server sees server traffic, a client its own.
Debug.enableStats(): ()                       -- collect until disableStats(); installs one global middleware
Debug.disableStats(): ()                      -- removes everything; counts are kept until resetStats()
Debug.statsEnabled(): boolean                 -- true while enabled or leased by the overlay
Debug.resetStats(): ()                        -- forget counts; collection carries on if on
Debug.stats(): { [string]: Hydrogen.NetStat } -- snapshot by network name; {} until stats have run
Debug.estimateBytes(...any): number           -- the estimate stats use for one message's values

export type NetStat = {
	name: string,
	kind: "ClientEvent" | "ServerEvent" | "ClientFunction" | "ServerFunction",
	inTotal: number, outTotal: number,        -- messages since start (events, requests, responses)
	inPerSecond: number, outPerSecond: number, -- during the last full second
	inBytes: number, outBytes: number,        -- estimated payload bytes since start
	inBytesPerSecond: number, outBytesPerSecond: number,
	dropped: number,                          -- arrived but never reached a listener/handler
	latency: Hydrogen.NetLatency?,            -- round trips of calls made from this side
	handler: Hydrogen.NetLatency?,            -- time this side's handler took to answer
}
export type NetLatency = { count: number, last: number, average: number, max: number } -- seconds

-- Setup (call before or after start; later calls change only the fields given).
Debug.configure(options: Hydrogen.DebugOptions): ()
export type DebugOptions = {
	key: Enum.KeyCode?,                       -- client: overlay key, default Enum.KeyCode.F3
	users: { number }?,                       -- server: UserIds allowed in live servers
	authorize: ((player: Player) -> boolean)?, -- server: replaces the default check entirely
	inspect: { Hydrogen.DebugInspectable }?,  -- server: Data.player stores / PlayerStates for the Player tab
	refresh: number?,                         -- client: seconds between overlay refreshes, default 1
}
export type DebugInspectable = { name: string, find: (self: any, player: Player) -> any }

Debug.bootOutput(message: string): ()         -- pass as AppOptions.output; records and prints boot timings
Debug.boot(): Hydrogen.BootReport?            -- this side's last boot timings (milliseconds)
export type BootReport = { total: number, network: number, systems: { { name: string, init: number, start: number } } }
Debug.warnings(): { Hydrogen.DebugWarning }   -- this side's last 50 warn and error log lines, oldest first
export type DebugWarning = { text: string, at: number, level: string? } -- at = Clock.time(); level "warn" or "error"

Debug.isAuthorized(player: Player): boolean   -- server: runs authorize, or the default check
Debug.fetch(userId: number?): Hydrogen.DebugView?  -- client, YIELDS: the server's view, nil if not authorized
export type DebugView = {
	stats: { [string]: Hydrogen.NetStat },    -- server stats
	warnings: { Hydrogen.DebugWarning },      -- server warnings
	boot: Hydrogen.BootReport?,               -- server boot timings
	state: { Hydrogen.DebugRow },             -- every global Hydrogen.State, formatted
	players: { { userId: number, name: string } },
	player: Hydrogen.DebugPlayerView?,        -- when userId names a player in the server
}
export type DebugPlayerView = { userId: number, name: string, state: { Hydrogen.DebugRow }, data: { { name: string, fields: { Hydrogen.DebugRow } } } }
export type DebugRow = { name: string, value: string }

Debug.open(): ()    -- client, YIELDS outside Studio (asks the server first)
Debug.close(): ()   -- client
Debug.toggle(): ()  -- client; what the key does

-- The system: app:addSystem(Hydrogen.Debug) on the server AND the client.
```

## Rules

- **Add `Hydrogen.Debug` to the app on both sides before `app:start()`.** Its `init` registers one network function, `Hydrogen/Debug`; a name registered on one side only shifts ids and causes NETWORK MISMATCH warnings. Stats (`enableStats`, `stats`) need no system.
- **Zero cost when off.** Until `enableStats()` or an overlay request, nothing is installed: no middleware, no observer, no per-message work. While on, every message costs one middleware call and a bounded size estimate. Disable removes the middleware and gives the network observer back.
- **On demand.** An authorized `Debug.fetch` turns server stats on for 10 seconds (renewed by each fetch); the open overlay keeps client stats on and they stop 3 seconds after it closes. `enableStats()` keeps them on regardless. So the first view after opening shows no rates yet.
- **Counting.** A server event sent to N players counts N out. Functions count the request and the response, each on the side that sends or receives it. Under `Hydrogen.test` one VM is the server and every client, so each message counts once out and once in.
- **Rates** are messages (or bytes) during the last full second of `Hydrogen.Clock` time; a second with no traffic reads 0. Totals keep growing until `resetStats()`.
- **Byte estimate**: 9 bytes for Hydrogen's id, plus per value: number 9, string length + 4, boolean/nil 2, buffer length + 4, Vector3 13, CFrame 49, other datatypes 16, table 4 plus its keys and values. After 256 values in one message, each further value counts 9, so huge payloads are cheap to estimate. Middleware sees plain values, so `:Encode()` objects are estimated larger than the buffer actually sent. Roblox's own packet overhead isn't included.
- **Dropped** = events and requests that arrived but never reached a listener or handler: dropped by middleware (`Hydrogen.rateLimit`, guards returning `Hydrogen.DROP`) or failing the schema. Undecodable payloads, unknown ids and malformed batches fail before middleware and show only as warnings.
- **Global middleware order.** The stats middleware keeps itself last in the global chain, so it sees incoming messages before your global middleware can drop them, and outgoing messages after your global middleware ran. A global middleware added after stats started is handled from its second message on.
- **Latency** is measured per calling thread: from the outgoing request to the incoming response on the same thread. Calls that time out or error record nothing. `handler` is the time between the handler starting and returning on the answering side.
- **Authorization.** Default: allowed in Studio, for the owner of a user-owned game, a UserId in `users`, or, when the game defines the `Hydrogen.Guards` permission `"debug"`, a player who has it (`Guards.can(player, "debug")`). `authorize` replaces all of it (it is the only check when given). An `authorize` that errors denies and warns. Unauthorized requests get `nil`, do no work and don't turn stats on. Group games: use `users` or `authorize`.
- **`Hydrogen/Debug` is rate-limited** to 4 requests per second per player (burst 8); a faster caller's `fetch` errors with `Hydrogen/Debug request was dropped by middleware`. The overlay's own requests appear in the network table under that name.
- **Read-only.** The server sends formatted text (`DebugRow.value`), never live tables; nothing in the view can change server state. Tables show up to 12 entries and 3 levels; strings up to 120 characters.
- **The overlay** opens outside Studio only if the server answers this player, so unauthorized players see nothing when they press the key. It refreshes once per `refresh` seconds while open, never per frame, and is built the first time it opens. The key is ignored while typing in a TextBox (gameProcessed).
- **Boot timings** exist only when the app was made with `output = Hydrogen.Debug.bootOutput` (and `debug = true`). They still print.
- **Warnings** are captured only while `Hydrogen.Debug` runs in an app on that side (from its `init`): every warn and error line that goes through `Hydrogen.Log`, so every `[HYDROGEN]` warning and your loggers' `log:warn` / `log:error` lines, each with its `level` (errors show red). Plain `warn()` calls are not captured in a game.

## Recipes

Staff from Hydrogen.Guards roles (no configure needed; the same roles can gate Commands):

```luau
Hydrogen.Guards.defineRole("staff", Hydrogen.Guards.groupRank(1234567, 200))
Hydrogen.Guards.definePermission("debug", { "staff" })
```

Gate the overlay on a Hydrogen.Config flag:

```luau
Hydrogen.Debug.configure({
	authorize = function(player: Player): boolean
		local flag = Hydrogen.Config.findFlag("DebugOverlay")
		return flag ~= nil and flag:enabled(player) -- server-side; never yields
	end,
})
```

Staff from your own list, or another role system:

```luau
Hydrogen.Debug.configure({
	authorize = function(player: Player): boolean
		return player:GetAttribute("Staff") == true
	end,
})
```

A different key, and a button for touch devices:

```luau
Hydrogen.Debug.configure({ key = Enum.KeyCode.F6 })
button.Activated:Connect(function()
	task.spawn(Hydrogen.Debug.toggle)
end)
```

Log the busiest objects every minute on the server:

```luau
Hydrogen.Debug.enableStats()
task.spawn(function()
	while true do
		Hydrogen.Clock.wait(60)
		for name, stat in Hydrogen.Debug.stats() do
			if stat.inBytesPerSecond > 1000 or stat.dropped > 0 then
				print(`[stats] {name}: {stat.inPerSecond}/s in, {stat.inBytesPerSecond} B/s, {stat.dropped} dropped`)
			end
		end
	end
end)
```

Show PlayerState and Data in the Player tab:

```luau
Hydrogen.Debug.configure({ inspect = { PlayerData, Session } }) -- Data.player store, PlayerState.new(...)
```

Read the server's view from client code (your own UI or a command):

```luau
local view = Hydrogen.Debug.fetch(Players.LocalPlayer.UserId) -- yields
if view and view.player then
	for _, row in view.player.state do
		print(row.name, row.value)
	end
end
```

## Mistakes

- Don't add `Hydrogen.Debug` only on the client (or only on the server). Do add it on both sides before `app:start()`.
- Don't add it with `app:addSystem` after `app:start()`. Do add it before start; a late add warns and can't reach the server.
- Don't expect boot timings from `App.new({ debug = true })` alone. Do pass `output = Hydrogen.Debug.bootOutput` too.
- Don't treat `inBytes` as exact for `:Encode()` objects. Do use it to compare objects and spot spikes.
- Don't leave `enableStats()` on in production servers unless you read the numbers. Do let the overlay lease them on demand.
- Don't put secrets in `Hydrogen.State` or inspected stores expecting the panel to hide them. Do restrict who is authorized; authorized players see everything in the view.
- Don't write an `authorize` that yields for long; each request waits for it. Do cache roles and look them up.

## Testing

Stats work under `Hydrogen.test` (fake clock: rates move with `t:advance`). The harness turns stats off, clears them and gives back its observer when it closes.

```luau
local Ping = Hydrogen.clientEvent("Ping", gt.number())

Hydrogen.test({ players = { "Alice" } }, function(t, alice)
	Hydrogen.Debug.enableStats()
	t:as(alice, function()
		Ping:Fire(1)
		Ping:Fire(2)
	end)
	local ping = Hydrogen.Debug.stats()["Ping"]
	assert(ping.outTotal == 2 and ping.inTotal == 2) -- one VM: counted leaving and arriving
	t:advance(1)
	assert(Hydrogen.Debug.stats()["Ping"].inPerSecond == 2)
end)
```

Authorization through the real request path:

```luau
Hydrogen.test({ systems = { Hydrogen.Debug }, players = { "Alice", "Bob" } }, function(t, alice, bob)
	Hydrogen.Debug.configure({ users = { alice.UserId } })
	assert(t:as(alice, Hydrogen.Debug.fetch) ~= nil)
	assert(t:as(bob, Hydrogen.Debug.fetch) == nil)
end)
```

`Debug.configure` settings persist between tests (like module-level setup); set what each test needs. The overlay UI isn't created under the loopback or Lune; check it in a Studio play test.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `[HYDROGEN] Debug.fetch needs Hydrogen.Debug added to the app on the server and the client before app:start()` | `fetch` was called but the Debug system never ran `init` on this side. | `app:addSystem(Hydrogen.Debug)` on both sides before start. |
| `[HYDROGEN] Hydrogen.Debug was added after the network started, so the overlay can't reach the server. Add it to the app on both sides before app:start()` | Added with `addSystem` after `app:start()`. | Add it before start. |
| `[HYDROGEN] Debug authorize failed for <name>, so they were denied: <error>` | Your `authorize` errored. | Fix the callback; it must return a boolean without erroring. |
| `[HYDROGEN] Debug.configure: key must be an Enum.KeyCode, e.g. Enum.KeyCode.F3` | Wrong `key` type. | Pass an `Enum.KeyCode`. |
| `[HYDROGEN] Debug.configure: users must be a list of UserIds (numbers), got <type>` | `users` contains names or other values. | Pass numbers: `{ 12345678 }`. |
| `[HYDROGEN] Debug.configure: authorize must be a function(player): boolean` | Wrong `authorize` type. | Pass a function. |
| `[HYDROGEN] Debug.configure: inspect takes Data.player stores and PlayerStates (anything with find(player))` | Something in `inspect` has no `find`. | Pass the store/PlayerState systems themselves. |
| `[HYDROGEN] Debug.configure: refresh must be a positive number of seconds` | `refresh` is 0, negative or not a number. | Use e.g. `1`. |
| `[HYDROGEN] NETWORK MISMATCH ...` | Debug added on one side only (its `Hydrogen/Debug` name is missing on the other). | Add it on both sides. |
| Overlay row `server unavailable: <error>` | The fetch errored (server has no Debug system, network not running). | Add Debug on the server. |
| Overlay row `not authorized for server data` | In Studio, your `authorize` returned false for you. | Allow yourself in `authorize`. |

## Works with

- [Network](network.md) and [Middleware](middleware.md): stats are a global middleware; `Hydrogen.rateLimit` drops show as `dropped`.
- [App](app.md): `AppOptions.output = Hydrogen.Debug.bootOutput` feeds the Boot tab.
- [State](state.md): the State and Player tabs list every `Hydrogen.State`.
- [Data](data.md) and [PlayerState](player-state.md): pass stores in `inspect` for the Player tab.
- [Test harness](testing.md) and [Clock](clock.md): rates follow `Hydrogen.Clock`, the harness resets stats on close.
- [Guards](guards.md): the default check lets in the Guards permission `"debug"`.
- [Log](log.md): the Warnings tab shows every warn and error line from `Hydrogen.Log`, with its level.
- [Config](config.md): gate the overlay on a feature flag through `authorize`.
