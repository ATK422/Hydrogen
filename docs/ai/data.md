# Hydrogen.Data

> Session-locked DataStore persistence as Hydrogen systems: declare a store once, and every system that `use`s it sees the player's data already loaded in its own `playerAdded`; saving, autosave, locking, migrations, retries and shutdown are handled for you.

## Use it when / Don't use it when

Use it when:
- You need per-player saved data (coins, inventory, settings, progress): `Hydrogen.Data.player`.
- You need saved data keyed by something else (guilds, a global config record, a shared leaderboard entry that one server owns at a time): `Hydrogen.Data.store`.
- You need to grant a Robux purchase exactly once (`updateOnce`) or trade between two players atomically (`transaction`).

Don't use it when:
- Data must be written by many servers at the same moment (a global counter, cross-server matchmaking): a key is session-locked to one server. Use `MemoryStoreService` or `DataStore:IncrementAsync` directly.
- The value is only needed while the player is in the game (in combat, current target): use a runtime field in `Hydrogen.PlayerState`.
- You need to replicate data to clients: Data never replicates. Use `Hydrogen.PlayerState` with `data = <store>`.
- One record would exceed 4 MB (the Roblox per-key limit). Data doesn't split records across keys.

## Quick start

```luau
-- ReplicatedStorage/State/PlayerData.luau  (shared is fine: stores do nothing on clients)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return Hydrogen.Data.player("PlayerData", {
	template = { coins = 0, inventory = {} :: { string } },
	schema = gt.table({
		coins = gt.number({ integer = true, range = "[0, inf]" }),
		inventory = gt.array(gt.string()),
	}),
})
```

```luau
-- ServerScriptService/Systems/Shop.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local PlayerDataStore = require(ReplicatedStorage.State.PlayerData)

return Hydrogen.define(function(use)
	local PlayerData = use(PlayerDataStore)
	local Shop = {}

	function Shop:playerAdded(player: Player)
		print(player.Name, "has", PlayerData:get(player).coins) -- already loaded
	end

	function Shop.buy(player: Player, item: string, price: number): boolean
		return PlayerData:update(player, function(data)
			if data.coins < price then
				return false -- abort: nothing changes
			end
			data.coins -= price
			table.insert(data.inventory, item)
			return nil
		end)
	end

	return Shop
end)
```

```luau
-- ServerScriptService/Main.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addSystemsFolders(ReplicatedStorage.State, ServerScriptService.Systems) -- the store is a system: add it
app:start()
```

Nothing else: no `PlayerAdded`/`PlayerRemoving`/`BindToClose` wiring.

## API

All methods below are server-only in effect: on a client a store's hooks do nothing and nothing is ever loaded, so `get` errors there.

### Constructors (`Hydrogen.Data`)

```luau
Data.player<T>(name: string, options: PlayerOptions<T>): Hydrogen.Defined<Hydrogen.PlayerStore<T>>
Data.store<T>(name: string, options: StoreOptions<T>): Hydrogen.Defined<Hydrogen.KeyStore<T>>
Data.memory(): Hydrogen.MemoryBackend                  -- new in-memory backend (tests, Lune, Studio without API access)
Data.dataStores(service: DataStoreService?): Hydrogen.DataBackend -- the Roblox DataStore backend
Data.useBackend(backend: Hydrogen.DataBackend?)        -- default backend for stores without `backend`; nil resets
Data.Clock: { now: () -> number, wait: (seconds: number) -> () } -- time sources; tests may replace the functions
```

`name` is the DataStore name and the system id. Each store must be added to the app (it is a system).

### Options

```luau
type StoreOptions<T> = {
	template: T,                 -- required. Data for a never-saved key; fills missing fields of loaded data
	schema: T?,                  -- GreenTea schema; derived with gt.typeof(template) if omitted
	migrations: { Migration }?,  -- run in order on data saved before they existed
	backend: Hydrogen.DataBackend?,
	autosave: number?,           -- seconds between saves of changed data. Default 120
	lockTimeout: number?,        -- seconds until another server's unrefreshed lock counts as abandoned. Default 600
	loadTimeout: number?,        -- seconds a load waits for another server's lock. Default 30
	retries: number?,            -- attempts per DataStore request. Default 5
}
type PlayerOptions<T> = StoreOptions<T> & {     -- (written out flat in the source)
	key: ((userId: number) -> string)?,                         -- record key; default tostring(userId)
	onLoadFailed: ((player: Player, message: string) -> ())?,   -- default: warn and kick
}
type Migration = ((data: any) -> any) | { migrate: (data: any) -> any, backwardsCompatible: boolean? }
```

### Methods on both store kinds (`K` is `Player` for player stores, `string` for key stores)

```luau
store:get(key: K): T                         -- loaded data, deep-frozen. Errors if not loaded
store:find(key: K): T?                       -- get, or nil
store:isLoaded(key: K): boolean              -- loaded successfully and still held by this server
store:waitForLoad(key: K, timeout: number?): boolean  -- YIELDS until the load finishes; false on failure/left
store:update(key: K, fn: (data: T) -> ...any): boolean -- copy, run fn, validate, commit. fn returns false to abort. Returns committed
store:updateOnce(key: K, id: string, fn: (data: T) -> ...any): Hydrogen.UpdateOnceResult -- YIELDS (saves)
store:transaction(keys: { K }, fn: (data: { [K]: T }) -> ...any): boolean -- all-or-nothing across keys
store:save(key: K): (boolean, string?)       -- YIELDS until stored; returns ok, err
store:changed(fn: (key: K, data: T, old: T) -> ()): () -> ()  -- after every commit; returns disconnect
store.name: string
```

`type UpdateOnceResult = "applied" | "duplicate" | "aborted" | "failed"`

### Player store only (`Hydrogen.PlayerStore<T>`)

```luau
store:view(userId: number): T?   -- YIELDS. Read saved data without locking (offline players). nil if never saved
```

Loading and unloading are automatic (`playerAdded` / `playerRemoving`).

### Key store only (`Hydrogen.KeyStore<T>`)

```luau
store:load(key: string): (boolean, string?)  -- YIELDS. Load and session-lock; waits up to loadTimeout for another server
store:unload(key: string)                     -- YIELDS. Save, release the lock, forget the key
store:view(key: string): T?                   -- YIELDS. Read without locking; nil if never saved
```

### Backends

```luau
type DataBackend = {
	update: (self, store: string, key: string, transform: (current: any) -> (any, { number }?)) -> any,
	read: (self, store: string, key: string) -> any,
	write: (self, store: string, key: string, value: any) -> (), -- nil value removes
	budget: (self, kind: "update" | "read" | "write") -> number,
}
type MemoryBackend = DataBackend & {
	latency: number,                                          -- seconds each request yields
	requests: { update: number, read: number, write: number },
	fail: (self, count: number, kind: ("update" | "read" | "write")?, message: string?) -> (), -- next requests error
	setBudget: (self, kind: "update" | "read" | "write", amount: number?) -> (), -- nil = unlimited
	peek: (self, store: string, key: string) -> any,          -- copy of the stored record
}
```

Stored record shape (what `peek` returns and what you `write` to seed tests):
`{ data = T, version = number, compatible = number, lock = { id, time }?, tx = { id, previous }?, once = { string }? }`.

Backend choice, in order: the store's `backend` option, `Data.useBackend(...)`, Roblox DataStores on a server, else a VM-wide in-memory backend (Lune, and any VM with `Hydrogen.loopback()` open).

## Rules

Lifecycle and ordering
- A player store loads in its `playerAdded` and saves + releases in its `playerRemoving`. Systems that `use` the store run `playerAdded` after it (data loaded) and `playerRemoving` before it (data still loaded and writable). On `app:stop()` (bound to `BindToClose`), every player is removed that way, then the store's `stop` saves and releases every remaining key.
- Safe during `playerRemoving` of a system that `use`s the store: `get`, `update`, `updateOnce`, `transaction`. The store saves after all of them return. Not safe: changes from a thread you `task.spawn` there that run after your hook returns. By then the data may be released, and `get` errors.
- After the store's own `playerRemoving`, `get` errors and `find` returns nil for that player.
- Once shutdown starts, new loads fail immediately, and retries shrink to fit `BindToClose`'s window.

Data access
- `get` returns a deep-frozen table. Assigning into it errors. Change data only with `update`, `updateOnce`, `transaction` or PlayerState field writes.
- `update`, `updateOnce` and `transaction` callbacks must not yield (a yield errors, nothing changes). They get a mutable copy; the result is validated against the schema and committed in one step. An error in the callback means nothing changes.
- `update` called inside another callback for the same key changes the outer pending copy and commits or aborts with it. A nested `update` can't return `false` (it errors); return `false` from the outer callback. `updateOnce` and `transaction` can't be nested. Inside a callback, `get` still returns the last committed data, not the pending copy.
- Validation checks only changed top-level fields when `schema` is a plain `gt.table({...})`; otherwise the whole value. GreenTea tables accept extra keys.

Locks and loading
- One server holds a key at a time. A load waits up to `loadTimeout` (30s) for another server to release it (typical after a server hop), then fails.
- A lock not refreshed for `lockTimeout` (600s) is treated as abandoned (crashed server) and taken over with a warning. Autosave refreshes locks even when nothing changed.
- A server that finds its lock taken stops saving that key; for players it kicks them ("Your data was opened on another server."). Its in-memory changes since the last save are lost by design.
- When a player's load fails (lock never freed, DataStore errors, data failing validation or migration), `onLoadFailed` runs: by default warn plus kick. Until they leave, `get` returns the template, `isLoaded` is false, and nothing is ever saved for them. Every system's `playerAdded` still runs. Check `isLoaded` before granting anything that must persist.
- A player who leaves while their load waits for a lock stops the wait. A player who rejoins the same server waits for their previous session to finish saving.
- `waitForLoad(player)` returns true only once loaded; false if the load failed, the player left before it started, or the data is being released. Use it from code not ordered after the store (e.g. `ProcessReceipt`, remote handlers early in a join).

Migrations and templates
- `migrations[i]` runs on data saved with fewer than `i` migrations. Never reorder or remove entries; only append.
- Data saved by a server with more migrations is refused (load fails) unless every newer migration is `{ migrate = fn, backwardsCompatible = true }`.
- After migrations, missing fields are filled from the template at every depth where both sides are tables. Existing values are never overwritten, and an empty template table (`{}`) adds nothing.
- The template must match the schema, or `Data.player`/`Data.store` errors at definition time.

Saving and limits
- Saves join: concurrent `save` calls share one write. Autosave writes only dirty data. Failed requests retry with backoff 1, 2, 4, 8s (`retries` attempts) and wait while the DataStore budget is spent.
- `save` returns `false, err` on failure; the data stays dirty and is retried by autosave and on leave. If the final save on leave fails, it warns and changes since the last save are lost.
- `updateOnce` keeps the last 100 ids per record.
- Records over 4 MB fail to save (Roblox limit).

Teleport hand-off (`Hydrogen.Teleport`)
- `Teleport.send` saves and releases every `Data.player` store holding the player before calling `TeleportAsync`, so the destination's load finds no lock. Nothing to configure: every player store takes part.
- Between that release and the player leaving (or the data being taken back): `get`/`find` still return the data; `isLoaded` and `waitForLoad` are false; `update` and PlayerState writes change memory only; `updateOnce` returns `"failed"`; `transaction` errors (`isn't usable (handedOff)`); `save` returns `false`; autosave skips the player.
- If the teleport fails, the data is taken back with the same lock: changes made meanwhile are kept and saved when the stored record is still what the hand-off wrote, otherwise the stored data wins (warned). If it can't be taken back, `onLoadFailed` runs (default: warn and kick).
- If the player leaves after a hand-off, nothing is saved in `playerRemoving`; changes made after the hand-off are lost and warned. Make them before `Teleport.send`, or in `Teleport.onHandOff`.
- A release write that errored may still have landed. The retry of that release, and the session's next write after a failed hand-off, accept an unlocked record that holds exactly the data that write stored, instead of treating the lock as lost. Anything else unlocked (another server loaded and changed it) is still a lost lock.

Transactions
- `transaction` applies to all keys in memory at once, then saves them with a two-phase commit (pending marker, each record tagged with the transaction id and its previous data, marker removed = commit). A crash before the commit loads every key with its previous data; after it, with the new data. Until committed, those keys are only saved together. All keys must be loaded on this server and in the same store.

## Recipes

Grant a developer product exactly once. In a game, use `Hydrogen.Receipts` with `Hydrogen.Receipts.fromData(PlayerData)` (receipts.md), which does this for every product and adds retries, game passes and tests. This is what it does underneath, for a game that owns `ProcessReceipt` itself:

```luau
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")

MarketplaceService.ProcessReceipt = function(receipt)
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	if not player or not PlayerData:waitForLoad(player) then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local result = PlayerData:updateOnce(player, receipt.PurchaseId, function(data)
		data.coins += 100
		return nil
	end)
	if result == "applied" or result == "duplicate" then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end
```

Trade an item between two players:

```luau
local function trade(seller: Player, buyer: Player, index: number, price: number): boolean
	return PlayerData:transaction({ seller, buyer }, function(all)
		local item = all[seller].inventory[index]
		if item == nil or all[buyer].coins < price then
			return false
		end
		table.remove(all[seller].inventory, index)
		all[buyer].coins -= price
		all[seller].coins += price
		table.insert(all[buyer].inventory, item)
		return nil
	end)
end
```

Add a field and rename another, with migrations:

```luau
return Hydrogen.Data.player("PlayerData", {
	template = { coins = 0, gems = 0, inventory = {} :: { string } },
	migrations = {
		function(old) -- v1: "money" was renamed to "coins"
			old.coins = old.money
			old.money = nil
			return old
		end,
		-- "gems" needs no migration: missing fields are filled from the template.
	},
})
```

Shared data owned by one server at a time (key store):

```luau
local Guilds = Hydrogen.Data.store("Guilds", { template = { bank = 0, members = {} :: { number } } })

local function deposit(guildId: string, amount: number): boolean
	if not Guilds:isLoaded(guildId) then
		local ok = Guilds:load(guildId) -- yields
		if not ok then
			return false
		end
	end
	return Guilds:update(guildId, function(guild)
		guild.bank += amount
		return nil
	end)
end
```

Reusable helpers that compose inside grants and trades:

```luau
local function addCoins(player: Player, amount: number)
	PlayerData:update(player, function(data)
		data.coins += amount
		return nil
	end)
end

PlayerData:updateOnce(player, purchaseId, function(data)
	addCoins(player, 100) -- joins this updateOnce's pending copy
	table.insert(data.inventory, "Crate")
	return nil
end)
```

Read an offline player's data (admin panel):

```luau
local data = PlayerData:view(userId) -- yields; nil if never saved; does not lock
```

## Mistakes

- Don't mutate `PlayerData:get(player)` (`data.coins += 1`): it is frozen and errors. Do use `PlayerData:update(player, function(data) data.coins += 1 return nil end)`.
- Don't call `task.wait`, `:InvokeClient` or a DataStore inside an update callback. Do the yielding work first, then call `update` with the result.
- Don't connect `Players.PlayerAdded` and read data there. Do read it in the `playerAdded` of a system that `use`s the store, or call `waitForLoad`.
- Don't rely on a store nobody `use`s being loaded. A store a system `use`s is added to the app for you; one you only `require` must be added yourself (`addSystem` / `addSystemsFolders`), or nothing loads.
- Don't grant purchases with `update` + `save`. Do use `updateOnce(player, receipt.PurchaseId, fn)`: it records the id in the same commit and dedupes across servers.
- Don't treat `"failed"` from `updateOnce` as granted. Do return `NotProcessedYet`; Roblox retries and the next call answers `"duplicate"` once stored.
- Don't change two players with two `update` calls for a trade. Do use `transaction`, so a crash can't store one side.
- Don't remove or reorder migrations. Do append new ones; mark one `backwardsCompatible = true` only if older servers can read its output.
- Don't save from a `task.spawn` started in `playerRemoving`. Do the change synchronously in the hook; the store saves after.
- Don't reuse one `Data.memory()` backend across unrelated tests. Do create a fresh one per test (pass `backend =` or call `Data.useBackend`).
- Don't call `get` for a player whose load may have failed when the change must persist. Do check `isLoaded(player)` first: after a failed load, changes are discarded.
- Don't give two stores the same `name` in one game unless they are meant to be the same DataStore.
- Don't call a key store's `get` before `load`. Do `load` (or check `isLoaded`) first.

## Testing

Under Lune and under `Hydrogen.loopback()`, stores use memory automatically. For isolation, give each test its own backend.

```luau
local Hydrogen = require(path.to.hydrogen)

local backend = Hydrogen.Data.memory()
Hydrogen.Data.useBackend(backend) -- or pass `backend = backend` to the store

local net = Hydrogen.loopback()
local alice = net:join("Alice")
local app = Hydrogen.App.new()
app:addSystems({ ShopSystem, PlayerDataStore })
app:start()

assert(PlayerDataStore:waitForLoad(alice))
ShopSystem.buy(alice, "Sword", 0)
assert(PlayerDataStore:get(alice).inventory[1] == "Sword")

net:leave(alice)                                        -- saves and releases
assert(backend:peek("PlayerData", tostring(alice.UserId)).lock == nil)

app:stop()
net:close()
Hydrogen.Data.useBackend(nil)
```

Fakes and controls:
- Failures: `backend:fail(2)` fails the next two requests (retried); `backend:fail(10, "update")` makes saves fail.
- Throttling: `backend:setBudget("update", 0)`, then `backend:setBudget("update", nil)`.
- Latency: `backend.latency = 0.05` makes every request yield, to test leaving mid-load or mid-save.
- Seed old data: `backend:write("PlayerData", "-1", { data = { money = 5 }, version = 0, compatible = 0 })`. Loopback players have UserIds -1, -2, ... in join order.
- Another server: a second `Data.store("PlayerData", { template = ..., backend = backend })` over the same backend holds locks like a different server (`other:load("-1")`).
- Time: replace `Hydrogen.Data.Clock.wait` (e.g. with `function() task.wait() end`) to skip backoff delays, and `Hydrogen.Data.Clock.now` to jump past `lockTimeout`. Restore both after the test.
- Fake the store instead: `app:replace(PlayerDataStore, fake)` with a table implementing the methods your system calls.

## Errors and warnings

Definition time (errors):
- `Data store <name> needs a template table`: pass `template = { ... }`.
- `Data store <name>'s template doesn't match its schema: <cause>`: fix the template or schema.
- `Data store <name>: migration <i> must be a function or { migrate = function }`.
- `Data.player needs a store name` / `Data.store needs a store name`.

Calls (errors):
- `<what>: <name> has no data loaded for <key>` / `<name>:get: no data loaded for <key>`: not loaded yet, already released, or on a client. Use `find`/`waitForLoad`, or read in `playerAdded` of a dependent system.
- `<name> update for <key> rejected, field "<f>" <cause>` (also `updateOnce ... rejected`, `transaction rejected for <key>`): the result fails the schema. Nothing changed.
- `<name> field "<f>" for <key> rejected: <cause>`: a PlayerState write failed the schema.
- `<what> callbacks can't yield; do the yielding work first, then update`.
- `<what> can't run inside another update's callback for the same data; change the data argument instead`, `<name>: updateOnce can't run inside another update's callback`, `<name>: an update nested inside another update can't abort on its own; return false from the outer callback`.
- `transaction: <name> data for <key> isn't usable (<status>)`: a key failed to load or lost its lock.
- `<name> keys are strings, got <type>`: key stores take string keys.
- `<name>: couldn't read <key>: <err>`, `<name>: couldn't check a transaction for <key>: <err>`, `<name> data for <key> <problem>` (from `view`): DataStore failure or data that fails migration/validation.

Warnings:
- `Data store <name> <kind> request failed (attempt n of m), retrying: <err>`: transient; only a problem if it keeps failing.
- `<name> couldn't load <player>: <reason>` (then kick): reasons include `<key> is still open on another server after 30s`, `saved by a newer server (...)`, `migration <i> failed: ...`, `doesn't match the schema: ...`, `couldn't load ...: <DataStore error>`. In Studio, a DataStore error gets a hint: enable API access, or call `Hydrogen.Data.useBackend(Hydrogen.Data.memory())`.
- `Data store <name>: took over <key>, whose lock was abandoned <n>s ago`: the previous server crashed. Expected occasionally.
- `Data store <name>: another server took the lock on <key>; this server stops saving it`: this server stalled past `lockTimeout`. The player is kicked.
- `Data store <name>: autosave of <key> failed: <err>`: retried next interval.
- `Data store <name>: couldn't save <key> on unload, changes since the last save are lost: <err>`.
- `Data store <name>: a transaction including <key> couldn't be saved: <err>` and `a transaction member lost its lock; saving the rest without it`.
- `Data store <name>: changes to <player> made after their data was handed off for a teleport weren't saved; make them before Teleport.send, or in Teleport.onHandOff`.
- `Data store <name>: <player>'s saved data changed while their teleport was in progress; changes made here since the hand-off were dropped`: something wrote the released record before a failed teleport took it back.
- `<name> couldn't take <player>'s data back after a failed teleport: <err>` (passed to `onLoadFailed`; the default warns and kicks).
- `Data changed listener failed: <err>`: your `changed` callback errored; other listeners still ran.

## Works with

- `Hydrogen.PlayerState`: `PlayerState.new(name, { data = PlayerData, ... })` turns the store's fields into saved fields of a per-player state that replicates per field. Writes through the state go to the store, and changes made through the store (`update`, `updateOnce`, `transaction`) show up in the state.
- `Hydrogen.Receipts`: `Hydrogen.Receipts.configure({ store = Hydrogen.Receipts.fromData(PlayerData) })` records each purchase id with its grant through `updateOnce`, so a purchase is granted exactly once. Product handlers get the draft data after the receipt (`function(player, receipt, data)`) and should change it; helpers that call `PlayerData:update` inside a grant also work.
- `Hydrogen.State`: Data itself doesn't replicate. PlayerState replicates its fields through State.
- `Hydrogen.Teleport`: `Teleport.send` hands off every player store (save, release, teleport, take back on failure), so the destination loads without waiting for this server's lock. See teleport.md.
- Test harness and fake clock: all Data timing goes through `Hydrogen.Clock` (`Hydrogen.Data.Clock` forwards to it). Under `Hydrogen.test`, retry and backoff waits, lock waits and autosave ticks only move on `t:advance(seconds)`.
- Core: stores are ordinary systems, so `use`, `app:replace` and the player and stop hooks apply as usual.
