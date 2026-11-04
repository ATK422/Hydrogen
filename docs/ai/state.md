# Hydrogen.State
> Server-authoritative state replicated to clients (global values, per-player values, maps, lists, derived values); reach for it whenever clients need to see and react to data the server owns.

## Use it when / Don't use it when

Use it when:
- Clients must display or react to server-owned data: round phase, timers, coins, levels, teams, scores, inventories, quest logs.
- Late joiners must see the current state without extra code.
- Collections change a little at a time and should be sent as diffs.

Don't use it when:
- The data is a one-off happening (a hit, a sound, a chat line): fire a `Hydrogen.serverEvent`.
- The client asks for data on demand: use `Hydrogen.clientFunction`.
- The data is server-only: keep it in a plain table in your system.
- It changes every frame per unit (positions, a battle frame): use an `:Unreliable():Encode()` serverEvent. State is reliable and ordered.
- It must be saved: use `Hydrogen.Data` (persistence) and replicate the fields that clients need, through State or PlayerState.
- The client should write it: State is written by the server only. Send a `clientEvent` and let the server write.

## Quick start

```luau
-- ReplicatedStorage/Network/GameState.luau (shared: required on server AND client before app:start)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local State = Hydrogen.State
local gt = Hydrogen.gt

return {
	Round = State.value("Round", gt.string(), "Lobby"),
	Coins = State.playerValue("Coins", gt.number(), 0), -- only the owner sees it
	Level = State.playerValue("Level", gt.number(), 1, { visibleTo = "everyone" }),
	Inventory = State.playerMap("Inventory", gt.string(), gt.number()),
}
```

```luau
-- ServerScriptService/Systems/RoundSystem.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local GameState = require(ReplicatedStorage.Network.GameState)

return Hydrogen.define(function()
	local RoundSystem = {}

	function RoundSystem:playerAdded(player: Player)
		GameState.Coins:set(player, 100)
		GameState.Inventory:set(player, "sword", 1)
	end

	function RoundSystem:start()
		GameState.Round:set("Playing")
	end

	return RoundSystem
end)
```

```luau
-- ReplicatedStorage/ClientSystems/Hud.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local GameState = require(ReplicatedStorage.Network.GameState)

return Hydrogen.define(function()
	local Hud = {}

	function Hud:start()
		GameState.Round:observe(function(round: string)
			print("round:", round) -- called now, then on every change
		end)
		GameState.Coins:observe(Players.LocalPlayer, function(coins: number)
			print("coins:", coins)
		end)
	end

	return Hud
end)
```

Boot: both sides call `app:addNetwork(ReplicatedStorage.Network)` before `app:start()`. Nothing else is needed: there is no State system to add.

## API

All constructors are called at module top level in a shared module, before `app:start()`, on both sides.

Constructors (`Hydrogen.State.*`):
- `value<T>(name: string, schema: T, initial: T, options: Options?): StateValue<T>`: one global value.
- `map<K, V>(name: string, keySchema: K, valueSchema: V, options: Options?): StateMap<K, V>`: global key -> value table, sent as key diffs.
- `list<T>(name: string, itemSchema: T, options: Options?): StateList<T>`: global array, sent as insert/remove/set operations.
- `playerValue<T>(name: string, schema: T, initial: T, options: PlayerOptions?): PlayerValue<T>`: one value per player.
- `playerMap<K, V>(name: string, keySchema: K, valueSchema: V, options: PlayerOptions?): PlayerMap<K, V>`: one map per player.
- `playerList<T>(name: string, itemSchema: T, options: PlayerOptions?): PlayerList<T>`: one list per player.
- `computed<T>(compute: () -> T): Computed<T>`: derived from other state; never sent; may be created anywhere, anytime.
- `flush(): ()`: server; sends every pending change now instead of at the end of the frame.
- `reset(): ()`: tests only; every state back to its initial value on the server and in every replica, and all observers dropped.

Options:
```luau
type Options = { encode: boolean?, serializer: StateSerializer? }
type PlayerOptions = { visibleTo: ("owner" | "everyone")?, encode: boolean?, serializer: StateSerializer? } -- visibleTo defaults to "owner"
type StateSerializer = { schema: any, serialize: (value: any) -> any, deserialize: (wire: any) -> any }
```
- `encode = true`: calls `:Encode()` on the state's event (schema-driven buffer packing).
- `serializer`: values travel as `serialize(value)` and are checked against `serializer.schema` on the wire. Writes are still checked against the state's own schema. The client stores `deserialize(wire)`.

Every state object has `name: string` and `event: ServerEvent<...any>` (the underlying `serverEvent`, named `State/<name>`, for `:Use(middleware)`).

`StateValue<T>`:
- `get(self): T`: both sides.
- `set(self, value: T): ()`: server only.
- `update(self, transform: (current: T) -> T): ()`: server only; `transform` gets the server value.
- `observe(self, observer: (value: T, previous: T?) -> ()): () -> ()`: both sides; calls now (`previous` nil), then on change; returns a disconnect function.

`StateMap<K, V>`:
- `get(self, key: K): V?`, `all(self): { [K]: V }` (a copy), `size(self): number`: both sides.
- `set(self, key: K, value: V?): ()`: server; nil removes the key.
- `remove(self, key: K): ()`, `update(self, key: K, transform: (current: V?) -> V?): ()` (returning nil removes), `replace(self, entries: { [K]: V }): ()` (sends only the keys that differ), `clear(self): ()`: server.
- `observe(self, observer: (entries: { [K]: V }) -> ()): () -> ()`: both sides; a copy of the whole map, now and after each change.
- `observeKey(self, key: K, observer: (value: V?) -> ()): () -> ()`: both sides; one key, now and on change.
- `onChange(self, listener: (key: K, value: V?, previous: V?) -> ()): () -> ()`: both sides; each changed key; no initial call.

`StateList<T>`:
- `get(self, index: number): T?`, `all(self): { T }` (a copy), `size(self): number`: both sides.
- `push(self, value: T): ()`, `insert(self, index: number, value: T): ()` (1..size+1), `remove(self, index: number): T` (1..size), `set(self, index: number, value: T): ()` (1..size), `replace(self, items: { T }): ()`, `clear(self): ()`: server.
- `observe(self, observer: (items: { T }) -> ()): () -> ()`: both sides; a copy, now and after each change.

`PlayerValue<T>`, `PlayerMap<K, V>`, `PlayerList<T>`: the same methods with `player: Player` inserted first, e.g.:
- `Coins:get(player: Player): T`, `Coins:set(player: Player, value: T)`, `Coins:update(player: Player, transform: (T) -> T)`.
- `Coins:observe(player: Player, observer: (value: T, previous: T?) -> ()): () -> ()`.
- `Inventory:set(player: Player, key: K, value: V?)`, `Inventory:observeKey(player: Player, key: K, observer)`, `Quests:insert(player: Player, index: number, value: T)`.
- Plus `observeAll(self, observer: (player: Player, ...) -> ()): () -> ()` with no player argument. It covers every player, called now for each player whose state exists on this side, then on each change. Its arguments after `player` are what that kind's `observe` gets: `(player, value, previous)`, `(player, entries)` or `(player, items)`.

`Computed<T>`:
- `get(self): T`: computes now; not cached.
- `observe(self, observer: (value: T, previous: T?) -> ()): () -> ()`: calls now, then whenever a state it read changes and the result differs.

Exported types: `Hydrogen.StateValue<T>`, `Hydrogen.StateMap<K, V>`, `Hydrogen.StateList<T>`, `Hydrogen.PlayerValue<T>`, `Hydrogen.PlayerMap<K, V>`, `Hydrogen.PlayerList<T>`, `Hydrogen.Computed<T>`, `Hydrogen.StateOptions`, `Hydrogen.PlayerStateOptions`, `Hydrogen.StateSerializer`.

Nothing in State yields. Observers run synchronously on a reused thread; if one yields, the write that triggered it does not wait.

## Rules

- Definitions are network registrations. Each state registers a `serverEvent` named `State/<name>`, and everyone-visible per-player state also registers `Hydrogen/StateLeft` once. Wire ids come from sorting all registered names on each side, so both sides must define exactly the same states. Put them in shared modules passed to `app:addNetwork` on both sides.
- Define before the network starts. Defining after `app:start()` errors. Names are unique: a duplicate errors, and so does a name that clashes with a network object `State/<name>`.
- Only the server writes. On a real client every write errors. Under loopback, writes always go to the server's copy.
- Writes are checked against the schema and error at the caller's line. They apply immediately: server reads see them, and server observers have already run when `set` returns.
- Writing the same non-table value does nothing. Setting a table always counts as a change and sends the whole value, even the same reference.
- Replication is per frame. The first write in a frame schedules one send at the end of the frame (`Heartbeat`). Each changed state sends one message, and per-player state sends one message per changed player. Maps send changed and removed keys. Lists send their operations, or the whole list once the operations outnumber the items (plus 8). `State.flush()` sends now.
- Ordering: an event fired right after a write reaches clients before the state does. Call `State.flush()` before firing events whose client listeners read the new state.
- Visibility: global state goes to everyone. Per-player `"owner"` (the default) goes only to that player; `"everyone"` goes to all players. Another client's `get(player)` on an owner-only state returns `initial` (value) or empty (map/list).
- Late joiners are sent everything written so far that they may see, then later changes. It is delivered in the ready handshake, before client systems' `start`. Reads before any data arrives return `initial` or empty.
- Player leaves:
  - Clients drop that player's per-player state.
  - On the server it stays readable (held weakly by `Player`), so later `playerRemoving` hooks can save it.
  - Writes for a departed player apply on the server and are not sent.
  - Pending changes for them are not sent.
- Shutdown: nothing to do; State holds no external resources.
- Collections: `all()`, `observe` and `observeAll` give copies, so changing them changes nothing. Only the methods change state.
- Map keys must be non-nil. List items must be non-nil and lists stay dense; there are no holes.
- Computed state must not yield. It depends on whatever it read on its last run, including reads through other computed state. On the client it reads replicas.
- Cost: nothing until the server first uses State (then two `Players` connections). Nothing per frame while idle. Writes, schema checks and observers are O(1) per change. Map and list `observe` copy the collection per change, only when observed.
- Under loopback (tests), each fake client has its own replica. Code inside `net:as(player, fn)` reads that client's copy; code outside reads the server's. Client systems' `start` runs outside `as`, so it reads server values.

## Recipes

The snippets after the first one assume `local GameState = require(ReplicatedStorage.Network.GameState)` (the module below), plus `Players` and `State`/`gt` locals as in the first one.

Global, per-player-private, per-player-public and collection state, all in one shared module:
```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local State, gt = Hydrogen.State, Hydrogen.gt

return {
	Round = State.value("Round", gt.string(), "Lobby"),                                 -- global
	TimeLeft = State.value("TimeLeft", gt.number(), 0),                                 -- global
	Coins = State.playerValue("Coins", gt.number(), 0),                                 -- per player, private
	Team = State.playerValue("Team", gt.optional(gt.string()), nil, { visibleTo = "everyone" }), -- per player, public
	Scores = State.map("Scores", gt.string(), gt.number()),                             -- global map
	Feed = State.list("Feed", gt.string()),                                             -- global list
	Inventory = State.playerMap("Inventory", gt.string(), gt.number()),                 -- per-player map
}
```

Count down a timer (one message per frame even when written more often):
```luau
for remaining = 60, 0, -1 do
	GameState.TimeLeft:set(remaining)
	task.wait(1)
end
GameState.Round:set("Results")
```

Grant an item and spend coins atomically from the server's point of view:
```luau
local function buy(player: Player, item: string, price: number): boolean
	if GameState.Coins:get(player) < price then
		return false
	end
	GameState.Coins:update(player, function(coins) return coins - price end)
	GameState.Inventory:update(player, item, function(count) return (count or 0) + 1 end)
	return true
end
```

Leaderboard on the client from a public per-player state:
```luau
local rows: { [Player]: number } = {}
GameState.Level:observeAll(function(player: Player, level: number)
	rows[player] = level
end)
Players.PlayerRemoving:Connect(function(player) rows[player] = nil end)
```

Derived state (extension): a computed value used on both sides:
```luau
local CanShop = State.computed(function(): boolean
	return GameState.Round:get() == "Lobby" and GameState.TimeLeft:get() > 5
end)
CanShop:observe(function(open: boolean) print("shop open:", open) end)
```

Custom type (extension): send a class instance as a number:
```luau
type Money = { cents: number }
local MoneyClass = {}
MoneyClass.__index = MoneyClass
local function money(cents: number): Money
	return setmetatable({ cents = cents }, MoneyClass) :: any
end

local Wallet = State.value("Wallet", gt.any(), money(0), {
	serializer = {
		schema = gt.number(),
		serialize = function(value: Money): number return value.cents end,
		deserialize = function(cents: number): Money return money(cents) end,
	},
})
```

Log one state's traffic: `GameState.Inventory.event:Use(Hydrogen.logger())`.

## Mistakes

- Don't mutate a table you got from State (`GameState.Scores:all().red = 5`, or `local inv = Inventory:all(player); inv.sword = 2`). `all` returns a copy, so nothing changes or replicates. Use `Scores:set("red", 5)`, `Inventory:update(player, "sword", fn)` or `Scores:replace(newTable)`.
- Don't keep a whole collection in `State.value` and mutate it in place (`local t = Bag:get(); table.insert(t, x); Bag:set(t)`). It resends the whole table every time, and the in-place change already leaked into the server's copy before `set`. Use `State.list` / `State.map`, or build a new table and `set` that.
- Don't define a state in a server-only or client-only module. The other side then has one name fewer, every later wire id shifts, and `[HYDROGEN] NETWORK MISMATCH` warns. Define states in shared modules that both sides `addNetwork`.
- Don't create states conditionally or in a loop that differs by side (`if RunService:IsServer() then State.value(...) end`). The set of names must be identical on both sides.
- Don't define states inside `init`, `start` or a function called later. They must exist before `app:start()`; afterwards they error.
- Don't call `set`/`update`/`push` on the client. Send a `clientEvent` and write on the server.
- Don't call a per-player method without the player (`Coins:get()`). Pass it first: `Coins:get(Players.LocalPlayer)` on the client, `Coins:set(player, 10)` on the server.
- Don't fire an event right after a write and expect client listeners to read the new state. Call `State.flush()` first, or carry the data in the event.
- Don't store nil in maps or lists. `Map:set(key, nil)` removes the key, and `List:push(nil)` errors.
- Don't yield inside `State.computed`, and don't read state you don't want as a dependency inside it.
- Don't expect `observeAll` to report players whose state was never written. They have `initial`. Handle "no entry yet" as the initial value.
- Don't disconnect by setting observers to nil. Call the function `observe` returned.

## Testing

Run server and client together with `Hydrogen.loopback()`. Each fake client has its own replica; read it inside `net:as`.
```luau
local net = Hydrogen.loopback()
local alice = net:join("Alice")
local app = Hydrogen.App.new()
app:addSystem(RoundSystem)
app:start()

GameState.Round:set("Playing")
assert(net:as(alice, function() return GameState.Round:get() end) == "Lobby") -- not sent yet
Hydrogen.State.flush()
assert(net:as(alice, function() return GameState.Round:get() end) == "Playing")

local bob = net:join("Bob") -- late joiner gets the snapshot on join
assert(net:as(bob, function() return GameState.Round:get() end) == "Playing")

app:stop()
net:close()
Hydrogen.State.reset() -- values are module singletons: reset between tests
```
- Without `Hydrogen.State.flush()`, changes go out at the end of the frame (`task.wait()` headless).
- Define states once per test file, at top level or on suite entry, before any network starts. A second definition with the same name errors.
- Count messages per state with middleware: `GameState.Round.event:Use(function(context, ...) if context.direction == "outgoing" then sent += 1 end return ... end)`. Each flush of a changed state is one outgoing message.
- Without a loopback in a headless test, State is a plain store with no replication, which is useful for unit-testing server logic.
- `app:replace` works as usual for systems that write state. State itself is not a system and is never replaced.
- Planned at merge: the `Hydrogen.test` harness calls `State.reset()` on close, and State's end-of-frame send runs on the harness's fake clock (`Clock.heartbeat`).

## Errors and warnings

Errors (raised at the caller's line):
- `[HYDROGEN] State <name> can only be changed on the server`: a write on a real client. Write on the server.
- `[HYDROGEN] State <name> got an invalid <value|key|list item|value from update>: <GreenTea error>`: the value doesn't match the schema. Fix the value or the schema.
- `[HYDROGEN] State <name> can't hold nil as a <key|list item>`: nil key or list item. Use `remove`.
- `[HYDROGEN] State <name>: index <i> is out of range (1 to <n>)`: bad list index. Check `size()`.
- `[HYDROGEN] State <name>: replace expects a table|an array, got <type>`: pass a table.
- `[HYDROGEN] State <name> is per player: pass the player first (:<method>(player, ...)), got <type>`: add the player argument.
- `[HYDROGEN] State needs a non-empty name`: name it.
- `[HYDROGEN] State <name> is already defined; state names must be unique`: rename one, or require the shared module instead of redefining.
- `[HYDROGEN] State <name> was defined after the network started; ...`: move the definition to a shared module required before `app:start()`.
- `[HYDROGEN] State <name>: options must be a table` / `visibleTo only applies to per-player state ...` / `visibleTo must be "owner" or "everyone", got <x>` / `serializer needs schema, serialize and deserialize`: fix the options.
- `[HYDROGEN] State <name>: the initial value doesn't match the schema: ...`: fix `initial`, or use `gt.optional(...)` for nil.
- `[HYDROGEN] State.computed expects a function`.
- `[HYDROGEN] Network object State/<name> is already registered; ...`: a network object already uses that name. Rename.

Warnings:
- `[HYDROGEN] Observer of State <name> failed: <error + traceback>`: your observer errored. Other observers and the write were not affected. Fix the observer. `(computed)` names computed state.
- `[HYDROGEN] Computed state failed: <error>`: the compute function errored during a recompute. Observers kept the last value.
- `[HYDROGEN] State <name> could not be sent: <error>`: the payload failed the wire schema, usually a `serializer` returning something that doesn't match `serializer.schema`.
- `[HYDROGEN] State could not tell clients that <player> left: <error>`: should not happen. Report it.
- `[HYDROGEN] State <name> received a map change with <k> keys and <v> values; ignored` / `... received a list change that doesn't fit the list ...`: the client's replica disagrees with the server, usually from mismatched definitions or a bad middleware. Check that both sides define the same states.
- `[HYDROGEN] Dropped invalid State/<name> from server: ...`: the client's schema differs from the server's. The definitions don't match.
- `[HYDROGEN] NETWORK MISMATCH ...`: the sides registered different names. A state (or network object) is defined on one side only.

## Works with

- **Network:** each state is a normal `serverEvent`, so `Hydrogen.logger()`, `Hydrogen.useMiddleware`, `App.new({ batching = true })` (state messages batch with other events) and `encode = true` all apply. It uses the same queue and handshake rules, so state sent before a client is ready is delivered on its handshake.
- **Systems:** write state from any hook. `playerAdded` writes reach the joining client in its handshake. `playerRemoving` can still read the leaving player's state.
- **PlayerState (`Hydrogen.PlayerState`, kit-data; wired up at merge):** each replicated field becomes `State.playerValue("<Session>/<field>", ...)` with `visibleTo` from the field's `"owner"` or `"everyone"`. PlayerState's client `changed` signal is `observeAll`. Server-only fields create no State.
- **Data (`Hydrogen.Data`):** persistence. Load in `playerAdded`, then `set` the fields clients need. State is not saved.
- **Scope (`Hydrogen.Scope`, kit-scope; at merge):** `observe`, `observeKey`, `onChange` and `observeAll` return disconnect functions, so pass them to a scope: `Hydrogen.Scope.of(self):add(GameState.Round:observe(fn))`, or `Hydrogen.Scope.of(self, player):add(...)` for per-player observers.
- **Testing (`Hydrogen.loopback`, and the `Hydrogen.test` harness at merge):** see Testing. The harness's fake clock drives State's end-of-frame send.
