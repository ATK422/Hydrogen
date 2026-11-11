# Hydrogen.State
> Server-authoritative state replicated to clients (global values, per-player values, maps, lists, meters that move over time, derived values); reach for it whenever clients need to see and react to data the server owns.

## Use it when / Don't use it when

Use it when:
- Clients must display or react to server-owned data: round phase, timers, coins, levels, teams, scores, inventories, quest logs.
- Late joiners must see the current state without extra code.
- Collections change a little at a time and should be sent as diffs.
- A number moves steadily over time (stamina, mana, posture, hunger, temperature, a capture bar): use a meter (`State.meter` / `State.playerMeter`). It sends only when the rate or value jumps, and each side works out the value now.
- The server must judge a client action by the meter's value when the player acted, not when the request arrived (a spell castable only while mana is 85-95): give the meter `history` and read `getAt(player, stamp)` with a `Guards.timestamp`-checked `Clock.serverNow()` stamp.

Don't use it when:
- The data is a one-off happening (a hit, a sound, a chat line): fire a `Hydrogen.serverEvent`.
- The client asks for data on demand: use `Hydrogen.clientFunction`.
- The data is server-only: keep it in a plain table in your system.
- It changes every frame per unit (positions, a battle frame): use an `:Unreliable():Encode()` serverEvent. State is reliable and ordered.
- A number that drains or refills on a timer: don't `set` it every tick. Use a meter and set its rate once.
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
	Stamina = State.playerMeter("Stamina", { max = 100, rate = 10 }), -- refills 10/s; sent only on changes
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
- `meter(name: string, options: MeterOptions): StateMeter`: one global number moving at a rate between min and max.
- `playerMeter(name: string, options: PlayerMeterOptions): PlayerMeter`: one meter per player; optional client prediction.
- `computed<T>(compute: () -> T): Computed<T>`: derived from other state; never sent; may be created anywhere, anytime.
- `flush(): ()`: server; sends every pending change now instead of at the end of the frame.
- `reset(): ()`: tests only; every state back to its initial value on the server and in every replica, and all observers dropped.

Options:
```luau
type Options = { encode: boolean?, serializer: StateSerializer? }
type PlayerOptions = { visibleTo: ("owner" | "everyone")?, encode: boolean?, serializer: StateSerializer? } -- visibleTo defaults to "owner"
type StateSerializer = { schema: any, serialize: (value: any) -> any, deserialize: (wire: any) -> any }
```
Meter options (no schema: a meter is always a number):
```luau
type MeterOptions = {
	min: number?,   -- default 0
	max: number,    -- required
	value: number?, -- initial value, default max; must be within [min, max]
	rate: number?,  -- initial units per second, default 0; negative drains
	history: number?, -- seconds of past values the server keeps for getAt, e.g. 1.5; off by default
	encode: boolean?,
}
type PlayerMeterOptions = {
	min: number?, max: number, value: number?, rate: number?, history: number?, encode: boolean?,
	visibleTo: ("owner" | "everyone")?, -- default "owner"
	predict: boolean?,                  -- default false; lets the owning client predictRate / predictAdd
	predictTimeout: number?,            -- seconds, default 1; only with predict = true
}
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

`StateMeter` (global meter):
- `get(self): number`: both sides; the value now: `clamp(value + rate * (Clock.serverNow() - at), min, max)` from the last change. Cheap; call it every frame for UI.
- `getAt(self, serverTime: number): number?`: server only, needs the `history` option; the value at a past server time (a client's `Clock.serverNow()` stamp), from the segment in force then, clamped to that segment's range. A time after the last write, including a stamp slightly in the future, extrapolates like `get()`. `nil` when `serverTime` is more than `history` seconds ago or before the oldest segment kept.
- `getRate(self): number`, `getRange(self): (number, number)`: both sides; units per second, and `(min, max)`.
- `set(self, value: number): ()`: server; an instant change, clamped; the rate carries on from it.
- `add(self, delta: number): ()`: server; `set(get() + delta)`.
- `setRate(self, rate: number): ()`: server; the value carries on from where it is now at the new rate.
- `setRange(self, min: number, max: number): ()`: server; the value is clamped into the new range.
- `observe(self, observer: (value: number, rate: number) -> ()): () -> ()`: both sides; calls now, then on each change (a write, an update arriving, a prediction or its expiry). Never as time passes.
- `onLimit(self, listener: (limit: "min" | "max") -> ()): () -> ()`: both sides; called each time the value arrives at min or max, by its rate (on time, from one `Clock.delay`) or by a change. Not called for where it is when connected.

`PlayerMeter`: the same methods with `player: Player` first (`Stamina:get(player)`, `Mana:getAt(player, stamp)`, `Stamina:setRate(player, -20)`, `Stamina:onLimit(player, fn)`), plus:
- `sync(self, player: Player): ()`: server; sends the segment again though nothing changed, so the owner's prediction is replaced now (use it when turning a request down).
- `predictRate(self, player: Player, rate: number): ()`: owning client only, needs `predict = true`; shows the new rate locally from `Clock.serverNow()`.
- `predictAdd(self, player: Player, delta: number): ()`: owning client only, needs `predict = true`; shows an instant change locally.
- `observeAll(self, observer: (player: Player, value: number, rate: number) -> ()): () -> ()`.

`Computed<T>`:
- `get(self): T`: computes now; not cached.
- `observe(self, observer: (value: T, previous: T?) -> ()): () -> ()`: calls now, then whenever a state it read changes and the result differs.

Exported types: `Hydrogen.StateValue<T>`, `Hydrogen.StateMap<K, V>`, `Hydrogen.StateList<T>`, `Hydrogen.PlayerValue<T>`, `Hydrogen.PlayerMap<K, V>`, `Hydrogen.PlayerList<T>`, `Hydrogen.Computed<T>`, `Hydrogen.StateOptions`, `Hydrogen.PlayerStateOptions`, `Hydrogen.StateSerializer`, `Hydrogen.StateMeter`, `Hydrogen.PlayerMeter`, `Hydrogen.MeterOptions`, `Hydrogen.PlayerMeterOptions`, `Hydrogen.MeterLimit` (`"min" | "max"`).

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

Meters:
- A meter is a segment `(value, rate, min, max, at)`: the value at server time `at` and its rate. Every write rebases it at `Clock.serverNow()` from the current extrapolated value, and that segment is what is sent. Nothing is sent, scheduled or computed while time passes; `get()` does the arithmetic.
- Only `set`, `add`, `setRate`, `setRange` and `sync` send, coalesced like other state (one message per meter, or per player, per frame). A write that changes nothing (same rate, same value now, same range) sends nothing.
- Values are clamped to `[min, max]`: writes clamp, and extrapolation stops at the limit. Changing the rate at a limit starts from the limit, not from where the value "would have been".
- Observers fire on changes, not as time passes. UI that shows the number reads `get()` each frame (`RunService.RenderStepped`); use `observe` for things that happen on a change (rate turned negative: play a drain effect).
- Clients extrapolate with `Clock.serverNow()` (`workspace:GetServerTimeNow()`). A client whose clock runs behind holds the value until it reaches `at` instead of running backwards; one running ahead sees it slightly further on. The error is the clock skew times the rate.
- The initial `rate` runs from when the server first uses the meter, per player for `playerMeter`: the player's join (when they start receiving state) or the first server read or write, whichever comes first. Before any data arrives a client shows the initial value at rest.
- `onLimit` costs nothing until a listener connects. With listeners, each watched meter holds at most one `Clock.delay`, for the moment the value reaches the limit it is heading for; every change reschedules it. Each arrival is reported once; staying at a limit is not reported again. It is per side: server listeners follow the server's value, client listeners the client's (including its prediction).
- Prediction (`playerMeter` with `predict = true`) is a local view only. `predictRate` / `predictAdd` change what the owning client's `get`, `getRate`, `observe` and `onLimit` show, starting at that client's `Clock.serverNow()`. They never reach the server: pair each with a `clientEvent` the server handles by calling `setRate` / `add`. The next segment from the server replaces the prediction, whatever it says (that is the confirmation or the correction). With no segment within `predictTimeout` (default 1 s), the prediction is dropped and the server's view shows again. A server write unrelated to the request also replaces it, so a prediction may end early; `sync(player)` forces a correction without changing anything.
- A player leaving: clients drop their meter (and its limit timers); the server keeps it readable and extrapolating for later `playerRemoving` hooks; writes after leaving are not sent.
- Computed state that reads a meter recomputes on the meter's changes only, not as its value moves.
- History (`history = seconds`) is opt-in: without it the server keeps nothing and `getAt` errors. With it, every server write (`set`, `add`, `setRate`, `setRange`) keeps the segment it replaced; `sync` changes nothing, so it keeps nothing. Segments that ended more than `history` seconds before the write are dropped on that write, and at most 128 are kept per meter (per player); nothing runs while time passes. Writes at one instant keep nothing for the segments that never ran.
- Make `history` at least the oldest stamp you accept: `Guards.timestamp()`'s window is the sender's ping capped at `maxPing` (1 s) plus `tolerance` (0.2 s), so 1.2 s by default; `history = 1.5` covers it.
- `getAt` answers what the server's meter was at that time. The client saw the same value if it had received the segment in force then; a segment the server wrote shortly before the stamp (within the one-way network delay) may not have reached it yet.
- `getAt` reads the past as it was, before any write the server made since. A cost paid at `now` (`add(player, -40)`) does not show at an earlier stamp, so a second action stamped before the first was paid reads mana already spent. Refuse stamps older than the last accepted action (see the recipe).
- A player leaving drops their meter's past (`getAt` for an earlier time returns `nil`); the current segment stays readable. History is server-only; client prediction is unaffected.

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

Stamina with client prediction (meter + clientEvent): the client shows sprinting at once, the server decides.
```luau
-- ReplicatedStorage/Network/Movement.luau (shared)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local State, gt = Hydrogen.State, Hydrogen.gt

return {
	-- Full at 100, refills 10/s from the moment the player joins.
	Stamina = State.playerMeter("Stamina", { max = 100, rate = 10, predict = true }),
	Sprint = Hydrogen.clientEvent("Sprint", gt.boolean()),
}
```
```luau
-- ServerScriptService/Systems/Sprinting.luau (server)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Movement = require(ReplicatedStorage.Network.Movement)

local DRAIN = -25
local REFILL = 10

return Hydrogen.define(function()
	local Sprinting = {}

	function Sprinting:init()
		Movement.Sprint:On(function(player: Player, sprinting: boolean)
			if not sprinting then
				Movement.Stamina:setRate(player, REFILL)
			elseif Movement.Stamina:get(player) > 0 then
				Movement.Stamina:setRate(player, DRAIN) -- confirms the client's prediction
			else
				Movement.Stamina:sync(player) -- refused: replace the prediction now, not after the timeout
			end
		end)
	end

	function Sprinting:playerAdded(player: Player)
		-- Fires once, at the moment stamina runs out; no polling.
		Hydrogen.Scope.of(self, player):add(Movement.Stamina:onLimit(player, function(limit: Hydrogen.MeterLimit)
			if limit == "min" then
				Movement.Stamina:setRate(player, REFILL)
			end
		end))
	end

	return Sprinting
end)
```
```luau
-- ReplicatedStorage/ClientSystems/SprintInput.luau (client)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Movement = require(ReplicatedStorage.Network.Movement)

return Hydrogen.define(function()
	local SprintInput = {}

	function SprintInput:start()
		local player = Players.LocalPlayer
		local bar = player:WaitForChild("PlayerGui"):WaitForChild("Hud"):WaitForChild("StaminaBar") :: Frame

		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			if not processed and input.KeyCode == Enum.KeyCode.LeftShift then
				Movement.Stamina:predictRate(player, -25) -- shown now
				Movement.Sprint:Fire(true) -- the server makes it real
			end
		end)
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.KeyCode == Enum.KeyCode.LeftShift then
				Movement.Stamina:predictRate(player, 10)
				Movement.Sprint:Fire(false)
			end
		end)

		-- Observers only fire on changes: read get() each frame for a smooth bar.
		RunService.RenderStepped:Connect(function()
			local _, max = Movement.Stamina:getRange(player)
			bar.Size = UDim2.fromScale(Movement.Stamina:get(player) / max, 1)
		end)
	end

	return SprintInput
end)
```

Spend mana on a cast, predicted (`Mana = State.playerMeter("Mana", { max = 100, rate = 5, predict = true })`, `Cast = Hydrogen.clientEvent("Cast", gt.string())`):
```luau
-- client
if GameState.Mana:get(Players.LocalPlayer) >= 30 then
	GameState.Mana:predictAdd(Players.LocalPlayer, -30)
	GameState.Cast:Fire("Fireball")
end

-- server
GameState.Cast:On(function(player: Player, spell: string)
	if GameState.Mana:get(player) < 30 then
		GameState.Mana:sync(player) -- correct the client
		return
	end
	GameState.Mana:add(player, -30)
end)
```

Judge an action at the moment the player acted (`Mana = State.playerMeter("Mana", { max = 100, rate = 8, history = 1.5 })`, `CastFulgur = Hydrogen.clientEvent("CastFulgur", gt.number())`). Fulgur casts only while mana is 85-95. By the time the request arrives the server's `get()` has charged past 95, so judge the value at the client's stamp instead:
```luau
-- client: stamp the cast with the server time it was pressed at
local mana = GameState.Mana:get(Players.LocalPlayer)
if mana >= 85 and mana <= 95 then
	GameState.CastFulgur:Fire(Hydrogen.Clock.serverNow())
end

-- server
local spentAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

-- Drops stamps from the future or older than ping (capped at 1 s) + 0.2 s: within history = 1.5.
GameState.CastFulgur:Use(Hydrogen.Guards.timestamp())
GameState.CastFulgur:On(function(player: Player, castAt: number)
	-- A stamp from before the last cast was paid would read mana that cast already spent.
	if castAt < (spentAt[player] or -math.huge) then
		return
	end
	local mana = GameState.Mana:getAt(player, castAt) -- what the player saw when they pressed
	if mana == nil or mana < 85 or mana > 95 then
		GameState.Mana:sync(player)
		return
	end
	GameState.Mana:add(player, -40) -- the cost comes off the value now
	spentAt[player] = Hydrogen.Clock.serverNow()
end)
```

Hunger that drains on its own, starving at zero (`Hunger = State.playerMeter("Hunger", { max = 100, rate = -0.2 })`):
```luau
function Survival:playerAdded(player: Player)
	Hydrogen.Scope.of(self, player):add(GameState.Hunger:onLimit(player, function(limit: Hydrogen.MeterLimit)
		if limit == "min" then
			print(player.Name, "is starving") -- start damage here
		end
	end))
end

local function eat(player: Player, food: number)
	GameState.Hunger:add(player, food) -- clamped at max
end
```

Upgrade max stamina, keeping the current value: `GameState.Stamina:setRange(player, 0, 150)`.

A global capture bar everyone sees (`Capture = State.meter("Capture", { min = -100, max = 100, value = 0 })`): the server calls `GameState.Capture:setRate(10 * (redCount - blueCount))` when someone enters or leaves the zone, and clients draw `GameState.Capture:get()` every frame.

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
- Don't `set` a meter every tick to drain it (`while true do Stamina:add(player, -1) task.wait(0.1) end`). That sends ten messages a second and still lags. Call `setRate(player, -10)` once.
- Don't draw a meter's bar from `observe`; it fires only on changes, so the bar would freeze between them. Read `get()` in `RenderStepped`.
- Don't compute a meter's value from `os.clock()`, `tick()` or the time an update arrived. Use `get()`, which uses `Clock.serverNow()` and the segment's `at`.
- Don't expect `predictRate` / `predictAdd` to change server state. Fire a `clientEvent` and let the server `setRate` / `add`; the client only changes its own view.
- Don't poll `get()` to detect empty or full on the server (`Heartbeat` checks). Use `onLimit`.
- Don't use a meter for a number that only jumps (coins, level). A `playerValue` is simpler; meters are for values with a rate.
- Don't add a flat tolerance to `get()` to forgive latency (`if mana >= 85 - 3 and mana <= 95 + 3`). It is too loose for slow meters and too tight for high ping. Stamp the action with `Clock.serverNow()`, put `Guards.timestamp()` on the event, and judge `getAt(player, stamp)`.
- Don't call `getAt` with an unchecked stamp. Without `Guards.timestamp()` a client can pick any moment in the last `history` seconds when the value suited it.
- Don't judge several actions by their stamps without refusing stamps older than the last accepted one. `getAt` reads the past before the cost was paid, so two casts stamped a moment apart would both see full mana.
- Don't make `history` shorter than the stamps you accept (`history = 0.5` with `Guards.timestamp()`'s 1.2 s window): a high-ping player's honest casts read `nil` and are refused.

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
- `Hydrogen.test` calls `State.reset()` when it closes, and State's end-of-frame send runs on the harness's fake clock: it goes out on the next `t:advance` (`t:advance(0)` is one frame). Without a fake clock, headless, it runs deferred.

Meters under `Hydrogen.test`: the fake clock drives `Clock.serverNow()`, so `t:advance(seconds)` moves meters on every side, and `onLimit` and prediction timeouts fire during the advance. Start it at a known time with `clock = { serverNow = 1000 }`. Skew one client's server clock with `t.clock:setServerOffset(seconds, player)` (positive = ahead). Predict inside `t:as(player, ...)`.
```luau
Hydrogen.test({ systems = { Sprinting }, players = { "Alice" }, clock = { serverNow = 0 } }, function(t, alice)
	local Stamina = Movement.Stamina
	Stamina:set(alice, 50)
	Stamina:setRate(alice, -10)
	t:advance(0) -- one frame: the segment is sent
	t:advance(2) -- time passing: nothing is sent
	assert(Stamina:get(alice) == 30)
	assert(t:as(alice, Stamina.get, Stamina, alice) == 30)

	local clock = t.clock :: Hydrogen.FakeClock
	clock:setServerOffset(0.1, alice) -- Alice's clock reads 0.1 s ahead
	t:as(alice, function()
		Stamina:predictRate(alice, 10) -- shown on Alice's client only
		Movement.Sprint:Fire(false)    -- the server sets REFILL
	end)
	t:advance(0)
	assert(Stamina:getRate(alice) == 10)
end)
```
- Count a meter's messages with middleware on `Stamina.event`, as above; time passing must add none.
- Test a prediction the server ignores by advancing past `predictTimeout` without a server write: the client's `getRate` returns to the server's.
- Test `getAt` with a late client: `t.clock:setServerOffset(-0.3, player)` makes that client's `Clock.serverNow()` stamps 0.3 s old when they arrive. Give `Guards.timestamp` a ping that covers it with `Hydrogen.Guards.configure({ ping = function() return 0.3 end })` (fake players have no ping), and call `Hydrogen.Guards.resetConfiguration()` afterwards. On the server, `Mana:getAt(player, stamp)` then returns what that client saw, while `get()` has moved on.

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
- `[HYDROGEN] State <name>: <set|add|setRate|setRange|predictRate|predictAdd> expects a finite number, got <x>`: NaN, infinity or a non-number. Check the arithmetic that produced it (a division by zero gives inf or NaN).
- `[HYDROGEN] State <name>: setRange got min (<a>) greater than max (<b>)`: swap them.
- `[HYDROGEN] State <name>: onLimit expects a function, got <type>`.
- `[HYDROGEN] State <name>: <predictRate|predictAdd> needs predict = true in the playerMeter options`: add `predict = true` to the definition.
- `[HYDROGEN] State <name>: <predictRate|predictAdd> runs on the client that owns the meter; the server changes it with <setRate|add>`: called on the server (or outside `t:as` in a test). On the server write the real value.
- `[HYDROGEN] State <name>: a client can only predict its own meter; pass Players.LocalPlayer, got <name>`: predict only the local player's meter.
- `[HYDROGEN] State <name>: getAt reads the server's past values and runs on the server only; a client reads its meter with get()`: called on a client (or inside `t:as`). The client's own view is `get()`; send the stamp to the server.
- `[HYDROGEN] State <name>: getAt needs history in the meter options, e.g. State.playerMeter("<name>", { max = 100, history = 1.5 }); make it at least Guards.timestamp's window (maxPing + tolerance, 1.2 s by default)`: the meter keeps no past. Add `history`.
- `[HYDROGEN] State <name>: getAt expects a server time (a finite number from Clock.serverNow()), got <x>`: NaN, infinity or a non-number. Pass the stamp the client sent, after `Guards.timestamp()` checked it.
- Meter definitions: `history must be a positive number of seconds, e.g. history = 1.5, got <x>`, `meter option <min|max|value|rate> must be a finite number[, e.g. { max = 100 }], got <x>`, `meter min (<a>) is greater than max (<b>)`, `the initial value <v> is outside the meter's range (<min> to <max>)`, `unknown meter option <key>; meters take <list>` (usually a typo), `<predict|predictTimeout> only applies to State.playerMeter (...)`, `predict must be true or false`, `predictTimeout only applies with predict = true`, `predictTimeout must be a positive number of seconds`. Fix the options.
- `[HYDROGEN] Network object State/<name> is already registered; ...`: a network object already uses that name. Rename.

Warnings:
- `[HYDROGEN] Observer of State <name> failed: <error + traceback>`: your observer errored. Other observers and the write were not affected. Fix the observer. `(computed)` names computed state.
- `[HYDROGEN] Computed state failed: <error>`: the compute function errored during a recompute. Observers kept the last value.
- `[HYDROGEN] State <name> could not be sent: <error>`: the payload failed the wire schema, usually a `serializer` returning something that doesn't match `serializer.schema`.
- `[HYDROGEN] State could not tell clients that <player> left: <error>`: should not happen. Report it.
- `[HYDROGEN] State <name> received a map change with <k> keys and <v> values; ignored` / `... received a list change that doesn't fit the list ...`: the client's replica disagrees with the server, usually from mismatched definitions or a bad middleware. Check that both sides define the same states.
- `[HYDROGEN] Dropped invalid State/<name> from server: ...`: the client's schema differs from the server's. The definitions don't match.
- `[HYDROGEN] State <name> received a meter segment that isn't finite numbers with min <= max; ignored`: a middleware or mismatched definition changed the payload. Check both sides define the same meter.
- `[HYDROGEN] NETWORK MISMATCH ...`: the sides registered different names. A state (or network object) is defined on one side only.

## Works with

- **Network:** each state is a normal `serverEvent`, so `Hydrogen.logger()`, `Hydrogen.useMiddleware`, `App.new({ batching = true })` (state messages batch with other events) and `encode = true` all apply. It uses the same queue and handshake rules, so state sent before a client is ready is delivered on its handshake.
- **Systems:** write state from any hook. `playerAdded` writes reach the joining client in its handshake. `playerRemoving` can still read the leaving player's state.
- **PlayerState (`Hydrogen.PlayerState`):** each replicated field is `State.playerValue("<name>/<field>", ...)` with `visibleTo` from the field's `"owner"` or `"everyone"`. PlayerState's client `changed` signal is `observeAll`. Server-only fields create no State.
- **Data (`Hydrogen.Data`):** persistence. Load in `playerAdded`, then `set` the fields clients need. State is not saved.
- **Scope (`Hydrogen.Scope`):** `observe`, `observeKey`, `onChange` and `observeAll` return disconnect functions, so pass them to a scope: `Hydrogen.Scope.of(self):add(GameState.Round:observe(fn))`, or `Hydrogen.Scope.of(self, player):add(...)` for per-player observers.
- **Testing (`Hydrogen.loopback` and `Hydrogen.test`):** see Testing. The harness's fake clock drives State's end-of-frame send.
- **Clock (`Hydrogen.Clock`):** meters timestamp with `Clock.serverNow()` and time `onLimit` and prediction expiry with `Clock.delay`, so the fake clock and `setServerOffset` control them in tests.
- **Guards (`Hydrogen.Guards`):** `Guards.timestamp()` bounds a client's `Clock.serverNow()` stamp, and a meter's `getAt(player, stamp)` judges the action at that stamp. Keep `history` at least the guard's window (`maxPing` + `tolerance`).
