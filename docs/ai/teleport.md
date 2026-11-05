# Hydrogen.Teleport

> Server-only teleports that can't lose or duplicate `Hydrogen.Data`: `Teleport.send(players, placeId, options?)` saves and releases every `Data.player` store the players are in, calls `TeleportAsync`, retries failures with backoff, and takes the data back for anyone who stays; `Teleport.ticket(name, schema)` carries typed teleport data to the destination.

## Use it when / Don't use it when

Use it when:
- A game is split across places (lobby, world zones, dungeons) and players move between them with their saved data.
- You teleport a party together, to a new or existing reserved server, or to a specific server (`serverId`).
- The destination needs to know why the player came (which dungeon, which spawn): use a ticket.

Don't use it when:
- The player isn't using `Hydrogen.Data`, and you don't care about retries: `TeleportService:TeleportAsync` directly is fine. (Teleport still works without Data; it just has nothing to hand off.)
- You need to move value (currency, items, ranks) with the player: teleport data passes through the client and can be forged. Save it in Data before the teleport and read it from Data at the destination.
- Testing in Studio: real teleports only work in a live server. Use `Teleport.fakeService()`.

## Quick start

```luau
-- ReplicatedStorage/Shared/Tickets.luau (required by both places)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Dungeon = Hydrogen.Teleport.ticket("Dungeon", gt.table({ dungeon = gt.string(), difficulty = gt.number() })),
}
```

```luau
-- Lobby place: ServerScriptService/Systems/Queue.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Tickets = require(ReplicatedStorage.Shared.Tickets)

local DUNGEON_PLACE = 1234567890

return Hydrogen.define(function(use)
	use(Hydrogen.Teleport) -- adds it to the app, so shutdown stops its retries
	local Queue = {}

	function Queue.start(party: { Player })
		local result = Tickets.Dungeon:send(party, DUNGEON_PLACE, { dungeon = "Crypt", difficulty = 2 }, {
			reserveServer = true, -- the party gets its own server
		})
		for _, failure in result.failed do
			print(failure.player.Name, "stayed:", failure.reason) -- their data is back and saving again
		end
	end

	return Queue
end)
```

```luau
-- Dungeon place: ServerScriptService/Systems/Dungeon.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Tickets = require(ReplicatedStorage.Shared.Tickets)
local PlayerDataStore = require(ReplicatedStorage.State.PlayerData)

return Hydrogen.define(function(use)
	local PlayerData = use(PlayerDataStore) -- loads without waiting: the lobby released the lock first
	local Dungeon = {}

	function Dungeon:playerAdded(player: Player)
		local ticket = Tickets.Dungeon:read(player) -- nil if they came some other way
		local dungeon = if ticket then ticket.dungeon else "Crypt"
		print(player.Name, "entered", dungeon, "with", PlayerData:get(player).coins, "coins")
	end

	return Dungeon
end)
```

## API

`Teleport` is `Hydrogen.Teleport`, a system (`use(Hydrogen.Teleport)` adds it to the app). Everything marked server-only errors on a client.

```luau
Teleport.send(players: Player | { Player }, placeId: number, options: Hydrogen.TeleportSendOptions?): Hydrogen.TeleportResult
-- YIELDS until every player left or failed. Server-only.

Teleport.ticket<T>(name: string, schema: T): Hydrogen.TeleportTicket<T>
ticket:send(players: Player | { Player }, placeId: number, value: T, options: Hydrogen.TeleportSendOptions?): Hydrogen.TeleportResult
-- YIELDS. Server-only. Validates value, then Teleport.send with it as the teleport data.
ticket:read(player: Player): T?
-- Server-only. The value the player arrived with, checked against the schema. UNTRUSTED.
ticket.name: string

Teleport.joinData(player: Player): { [string]: any }?   -- player:GetJoinData() (through the fake in tests). Server-only.
Teleport.reserve(placeId: number): string                -- YIELDS. ReserveServer access code; 3 attempts, then errors. Server-only.
Teleport.onHandOff(callback: (player: Player) -> ()): () -> ()  -- runs right before a player's data is released; returns remove
Teleport.configure(config: Hydrogen.TeleportConfig): ()  -- service, default attempts and timeout
Teleport.fakeService(): Hydrogen.FakeTeleportService     -- stand-in TeleportService for tests
```

```luau
export type TeleportSendOptions = {
	data: any?,              -- teleport data (plain JSON values). Tickets set it; don't pass both
	serverId: string?,       -- join this server (its game.JobId)
	reservedCode: string?,   -- join this reserved server (Teleport.reserve, or a result's reservedCode)
	reserveServer: boolean?, -- put the players in a new reserved server together
	attempts: number?,       -- TeleportAsync attempts in all; default 3
	timeout: number?,        -- seconds, after Roblox accepts, for each player to leave; default 30
}
-- Pass at most one of serverId, reservedCode and reserveServer.

export type TeleportResult = {
	ok: boolean,                  -- every player left for the destination
	teleported: { Player },       -- left after Roblox accepted their teleport
	failed: { TeleportFailure },  -- everyone else: still here with their data back, unless they left
	attempts: number,             -- TeleportAsync calls made
	reservedCode: string?,        -- with reserveServer: the new server's code, to send more players there
}
export type TeleportFailure = { player: Player, reason: TeleportFailReason, message: string }
export type TeleportFailReason =
	"Failure" | "Flooded" | "GameFull" | "GameNotFound" | "GameEnded" | "Unauthorized" | "IsTeleporting" -- Enum.TeleportResult names
	| "Error"        -- TeleportAsync errored
	| "TimedOut"     -- accepted, but the player was still here after timeout
	| "Busy"         -- another send for this player was running
	| "Left"         -- left before the teleport started, or between attempts
	| "DataNotSaved" -- their Data couldn't be saved and released; not sent
	| "ShuttingDown" -- the server began shutting down

export type TeleportConfig = { service: TeleportBackend?, attempts: number?, timeout: number? }
export type TeleportTicket<T> = { read name: string, send: ..., read: ... }

-- The injectable service (TeleportService + Player:GetJoinData):
export type TeleportBackend = {
	teleport: (self, request: TeleportRequest) -> TeleportAccepted?,  -- TeleportAsync; yields; errors when refused
	onFailed: (self, callback: (player: Player, reason: string, message: string) -> ()) -> () -> (), -- TeleportInitFailed
	joinData: (self, player: Player) -> { [string]: any }?,
	reserve: (self, placeId: number) -> string,
}
export type TeleportRequest = { placeId: number, players: { Player }, serverId: string?, reservedCode: string?, reserveServer: boolean?, data: any? }
export type TeleportAccepted = { reservedCode: string? }
```

## Rules

The hand-off (why the destination never waits and nothing is lost or written twice)
- Order per send: `onHandOff` callbacks, then every `Data.player` store holding the player saves and releases it (one `UpdateAsync` that writes the data and clears the session lock), then `TeleportAsync`. `TeleportAsync` is only called after every release write succeeded, and a player can only reach the destination after `TeleportAsync`, so the destination's load always finds the lock cleared. It loads at once instead of waiting for this server's `playerRemoving`.
- Only one server holds a record's lock at a time. Between the release and either the player leaving or the data being taken back, this server never writes the record. Taking it back goes through the normal lock (it waits for, and never overrides, another server's lock).
- Everything committed before the release is in the release write. A player whose release fails is not sent (`DataNotSaved`) and keeps playing on locked, saving data.
- While handed off, on this server: `get`/`find` still work; `isLoaded` and `waitForLoad` are false; `update` and PlayerState writes change memory only; `updateOnce` returns `"failed"` (so `Hydrogen.Receipts` answers `NotProcessedYet` and the purchase is granted at the destination); `transaction` errors; `save` returns false; autosave skips it.
- A player who leaves after Roblox accepted their teleport counts as teleported. Changes made here after the hand-off are not saved; Data warns. Make last changes before `send`, or in `Teleport.onHandOff`.
- A player who stays (every attempt failed, a reason not worth retrying, or `TimedOut`) gets their data back: same lock id, data read from the store. If the stored data is still what the hand-off wrote, changes made meanwhile are kept and saved; if something else changed it, the stored data wins (warned). If it can't be taken back (another server holds it past `loadTimeout`, DataStore outage), the store's `onLoadFailed` runs: warn and kick by default. Data never lets them play on unsaved data silently.
- A release write that errored may still have landed. The player isn't sent, the session stays loaded, and its next write accepts the unlocked record if it holds exactly the data that release stored (anything else is treated as a lost lock).

Retries and outcomes
- Retried: `Failure` and `Error` after 1, 2, 4 s (max 8), `Flooded` after 15 s, up to `attempts` (3) in all. Not retried: `GameFull`, `GameNotFound`, `GameEnded`, `Unauthorized`, `IsTeleporting`, `TimedOut`.
- After `TeleportAsync` accepts, each player either leaves (teleported), fails (`TeleportInitFailed`), or neither within `timeout` (30 s): `TimedOut`, not retried, because the client may still be on its way. If they arrive after all, the destination waits for this server's lock until their `playerRemoving` saves and releases it.
- Parties: one `TeleportAsync` for everyone; only failed members are retried. With `reserveServer`, retries join the server the first accepted call reserved (`result.reservedCode`). Without a reserved server, retried members may land in a different public server than the rest.
- Failures (except `Left`) are warned once per send: `Teleport to place <id> failed for ...`. The result says the same.

Players, concurrency and shutdown
- A second `send` for a player whose send is still running fails that player with `Busy`; it doesn't queue.
- A player who leaves while their data is saving, or between attempts, is reported `Left`; their data is saved and released.
- On `app:stop()` (bound to `BindToClose`), with `Hydrogen.Teleport` in the app: waits end early, nothing is retried, and players still here fail with `ShuttingDown` with their data saved and released (no kick). Without the system in the app, sends keep retrying during shutdown.
- In Studio, the real `TeleportAsync` errors; Teleport reports `Unauthorized` with a hint instead of retrying.
- Only `Data.player` stores are handed off. `Data.store` keys stay with this server.

Tickets and join data
- Teleport data travels through the client. **Never trust it for anything security-relevant** (currency, items, ranks, admin, unlocked areas): an exploiter can change it. A ticket's schema checks its shape only. Use it for presentation and routing (which dungeon, spawn point, party names); put anything of value in Data before the teleport and read it from Data at the destination.
- `ticket:read` returns nil when the player arrived without join data, with another ticket, or with a value that fails the schema (warned).
- Ticket names are what `read` matches on: define each ticket once in a module both places require.
- Teleport data must be plain JSON values (no Instances, Vector3, CFrame; arrays without holes): `send` errors before teleporting otherwise.

Time: all waits use `Hydrogen.Clock`, so `t:advance` drives backoff and timeouts.

## Recipes

Send a party to a new private server, then send a late joiner to the same one:

```luau
local result = Teleport.send(party, ARENA_PLACE, { reserveServer = true })
if result.reservedCode then
	arenaCodes[arenaId] = result.reservedCode
end
-- later
Teleport.send(lateJoiner, ARENA_PLACE, { reservedCode = arenaCodes[arenaId] })
```

Record session playtime before the data leaves (instead of in `playerRemoving`, which runs after the hand-off):

```luau
local joinedAt: { [Player]: number } = {} -- set in playerAdded: joinedAt[player] = Hydrogen.Clock.now()

Teleport.onHandOff(function(player: Player)
	PlayerData:update(player, function(data)
		data.playtime += Hydrogen.Clock.now() - joinedAt[player]
		return nil
	end)
end)
```

Retry a whole group a caller-defined way (e.g. a "Try again" button) after `send` gave up:

```luau
local result = Teleport.send(players, WORLD_PLACE, { attempts = 5 })
local stayed: { Player } = {}
for _, failure in result.failed do
	if failure.reason ~= "Left" then
		table.insert(stayed, failure.player)
	end
end
Remotes.TeleportFailed:Fire(stayed, "Couldn't reach the world server, try again")
```

Join a friend's server:

```luau
Teleport.send(player, game.PlaceId, { serverId = friendJobId })
```

Server hop to the next world zone, carrying the spawn point:

```luau
local ZoneEntry = Hydrogen.Teleport.ticket("ZoneEntry", gt.table({ gate = gt.string() }))
ZoneEntry:send(player, FOREST_PLACE, { gate = "North" })
-- Forest place, in playerAdded:
local entry = ZoneEntry:read(player)
spawnAt(player, if entry then entry.gate else "Default")
```

## Mistakes

- Don't call `TeleportService:TeleportAsync` for players using `Hydrogen.Data`. Do use `Teleport.send`, or the destination waits for this server's lock (up to 30 s, then kicks).
- Don't put coins, items or permissions in teleport data. Do save them in Data before `send` and read Data at the destination.
- Don't change Data in `playerRemoving` for players who teleported and expect it saved: the data left with them. Do it in `Teleport.onHandOff` (or before `send`).
- Don't ignore the result. Do tell players in `result.failed` that they stayed (their data is back).
- Don't retry `Busy` in a loop. Do wait for the first send's result.
- Don't send one party member at a time to a shared reserved server with `reserveServer = true` each time. Do send them together, or reuse `result.reservedCode`.
- Don't test real teleports in Studio. Do configure `Teleport.fakeService()`.
- Don't define the same ticket name twice with different schemas. Do share one module between the places.

## Testing

`Teleport.fakeService()` plays TeleportService: by default an accepted teleport makes each player leave at once (`player:Kick()`, which loopback players treat as leaving), so `send` returns without advancing time. Configure it before the test; give each test a fresh `Data.memory()` backend.

```luau
local fake = Hydrogen.Teleport.fakeService()
Hydrogen.Teleport.configure({ service = fake })
local backend = Hydrogen.Data.memory()
local PlayerData = Hydrogen.Data.player("PlayerData", { template = { coins = 0 }, backend = backend })

Hydrogen.test({ systems = { PlayerData, Hydrogen.Teleport }, players = { "Alice" } }, function(t, alice)
	fake:failNext(1)                      -- first attempt fails (TeleportInitFailed "Failure")
	local result: Hydrogen.TeleportResult? = nil
	task.spawn(function()
		result = Hydrogen.Teleport.send(alice, 123)
	end)
	assert(backend:peek("PlayerData", tostring(alice.UserId)).lock == nil) -- released before teleporting
	t:advance(1)                          -- backoff, then the retry succeeds
	assert(result and result.ok and result.attempts == 2)
end)
```

`FakeTeleportService` (methods with `:`):
- `requests: { TeleportRequest }` (copies, oldest first); `reserved: { string }` (codes handed out: `"fake-reserved-N"`).
- `failNext(count, reason?, message?)`: the next `count` players named in requests fail (default `"Failure"`).
- `errorNext(count, message?)`: the next `count` `teleport` (or `reserve`) calls error.
- `hold(true)`: accepted teleports wait; then `complete(player)` (leaves) or `fail(player, reason?, message?)`; `holding(): { Player }`.
- `setJoinData(player, joinData?)`, and `arrive(player, request?)`: join data as the destination would see it from a request (default the last): `TeleportData`, `SourcePlaceId`, `Members`.

Tips:
- "Another server loads at once": `Hydrogen.Data.store(name, { template = ..., backend = backend }):load(tostring(userId))` returns true while the teleport is held.
- Player leaving mid-teleport: `t:leave(player)` during a held teleport, a backoff, or a slow save (`backend.latency = 1`).
- Shutdown: `t.app:stop()` inside the test, then `t:advance`.
- Without `configure`, Teleport uses a VM-wide fake under Lune and `Hydrogen.loopback()`, and the real TeleportService on a live server.
- To fake Teleport in another system's test: `replace = { [Hydrogen.Teleport] = { send = function(...) ... end } }`.

## Errors and warnings

Errors (at the call):
- `Teleport.send is server-only; fire a clientEvent and teleport from a server system` (also `Teleport.joinData`, `Teleport.reserve`, `Ticket:send`, `Ticket:read`).
- `Teleport.send needs a player or a list of players, got <type>` / `Teleport.send: players[<i>] is a <type>, not a Player`.
- `Teleport.send needs a place id (number), got <type>`; `Teleport.send options must be a table`.
- `Teleport.send: pass only one of serverId, reservedCode and reserveServer`.
- `Teleport.send: attempts must be a number, at least 1` / `timeout must be a positive number of seconds`.
- `Teleport.send: teleport data can't be sent: data.<path> is a <type>, which JSON can't hold; ...` (also `contains itself`, `mixes array items and string keys`, `is an array with holes`): send plain values.
- `Ticket <name>:send: the value doesn't match the ticket's schema: <cause>`; `Ticket <name>:send sets the teleport data itself; don't pass data`.
- `Teleport.ticket needs a name`; `Teleport.ticket <name> needs a GreenTea schema (Hydrogen.gt), got <type>`.
- `Teleport.configure expects a table`; `Teleport.configure: service is missing <method>`; `attempts` / `timeout` as above.
- `Teleport.reserve needs a place id (number), got <type>`; `Teleport.reserve couldn't reserve a server for place <id> after 3 attempts: <err>`.
- `Teleport.onHandOff expects a function, got <type>`.
- `fakeService: <name> has no held teleport to complete` / `to fail`; `fakeService:arrive needs a request; teleport someone first, or pass one`.

Warnings:
- `Teleport to place <id> failed for <Name> (<reason>: <message>), ...`: some players stayed; see `result.failed`. With `; their data couldn't be taken back: <err>` the store's `onLoadFailed` also ran.
- `<store> couldn't take <Name>'s data back after a failed teleport: <err>` (then a kick, from the default `onLoadFailed`).
- `Data store <name>: changes to <player> made after their data was handed off for a teleport weren't saved; make them before Teleport.send, or in Teleport.onHandOff`.
- `Data store <name>: <player>'s saved data changed while their teleport was in progress; changes made here since the hand-off were dropped`.
- `Teleport.onHandOff callback failed for <Name>: <traceback>`: fix the callback; the hand-off continued.
- `Teleport ticket <name> for <Name> doesn't match its schema, so it was ignored: <cause>`: stale code in one place, or tampered data.
- `Teleport failed internally: <traceback>`: a bug; report it. Players' data is taken back.
- Reason `Unauthorized` with `(teleports don't work in Studio play tests; ...)`: expected in Studio.

## Works with

- `Hydrogen.Data` (data.md): every `Data.player` store is handed off automatically; no option needed. The destination's store loads normally.
- `Hydrogen.Receipts` (receipts.md): purchases during a hand-off answer `NotProcessedYet` and are granted at the destination, once.
- `Hydrogen.PlayerState` (player-state.md): saved fields follow Data; writes during the hand-off stay in memory like Data's.
- `Hydrogen.Messaging` (messaging.md): tell other servers about a reserved server (`result.reservedCode`) so they can send players to it.
- `Hydrogen.Clock` and `Hydrogen.test` (clock.md, testing.md): backoff and timeouts run on the fake clock.
