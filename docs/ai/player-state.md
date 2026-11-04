# Hydrogen.PlayerState

> Per-player state as a Hydrogen system: fields that come from a `Hydrogen.Data` store (saved) or live only while the player is in the game (runtime), each replicated with one word, `"owner"` or `"everyone"`. Created on join and dropped on leave, in dependency order.

## Use it when / Don't use it when

Use it when:
- Server systems need per-player values (coins, level, in-combat flag, kill streak) with one place to read and write them.
- Some of those values are saved (from `Hydrogen.Data.player`) and some aren't, and you want both behind one object.
- Clients need some of those values: the owner sees their own coins, and everyone sees each player's level or team.

Don't use it when:
- The value isn't per player (round state, a global leaderboard): use `Hydrogen.State` or a network event.
- You only need saved data on the server and nothing replicates: `Hydrogen.Data.player` alone is enough.
- The value changes every frame (aim direction, positions): replication is coalesced per frame but still sends each change; use an unreliable network event.
- Clients must write the value: PlayerState is server-authoritative. Send a client event and let the server write.

## Quick start

Declare the store and the state in shared modules (both the server and the client require them):

```luau
-- ReplicatedStorage/State/PlayerData.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return Hydrogen.Data.player("PlayerData", {
	template = { coins = 0, level = 1, inventory = {} :: { string } },
	schema = gt.table({
		coins = gt.number({ integer = true, range = "[0, inf]" }),
		level = gt.number({ integer = true }),
		inventory = gt.array(gt.string()),
	}),
})
```

```luau
-- ReplicatedStorage/State/Session.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local PlayerData = require(script.Parent.PlayerData)

return Hydrogen.PlayerState.new("Session", {
	data = PlayerData,                          -- saved fields: coins, level, inventory
	runtime = { inCombat = false, streak = 0 }, -- runtime fields with starting values
	replicate = {
		coins = "owner",       -- only this player's client
		level = "everyone",    -- every client
		inCombat = "everyone",
		-- inventory and streak: not listed, server only
	},
})
```

Boot both sides with the shared folder:

```luau
-- ServerScriptService/Main.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addSystemsFolders(ReplicatedStorage.State, ServerScriptService.Systems)
app:start()
```

```luau
-- StarterPlayerScripts/Main.client.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addSystemsFolders(ReplicatedStorage.State, script.Parent:WaitForChild("Systems"))
app:start()
```

Server system:

```luau
-- ServerScriptService/Systems/Combat.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local SessionState = require(ReplicatedStorage.State.Session)

return Hydrogen.define(function(use)
	local Session = use(SessionState)
	local Combat = {}

	function Combat:playerAdded(player: Player)
		print(Session:get(player).coins) -- exists already (data loaded)
	end

	function Combat.onKill(killer: Player)
		local state = Session:get(killer)
		state.coins += 10   -- validated by PlayerData's schema, saved with the profile, sent to the killer
		state.streak += 1   -- runtime, server only
	end

	return Combat
end)
```

Client system:

```luau
-- StarterPlayerScripts/Systems/CoinsLabel.luau
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local SessionState = require(ReplicatedStorage.State.Session)

return Hydrogen.define(function(use)
	local Session = use(SessionState)
	return {
		start = function()
			Session:changed("coins", function(player: Player, coins: any, _old: any)
				if player == Players.LocalPlayer then
					print("coins:", coins) -- update the UI here
				end
			end)
		end,
	}
end)
```

## API

```luau
Hydrogen.PlayerState.new<D, R>(name: string, options: {
	data: Hydrogen.PlayerStore<D>?,        -- a Data.player store; its fields become saved fields
	runtime: R?,                           -- runtime fields and their starting values
	replicate: { [string]: "owner" | "everyone" }?, -- one word per field; unlisted = server only
}): Hydrogen.Defined<Hydrogen.PlayerState<D & R>>
```

The result is a system: add it to the app on both sides. `name` must be unique among states, and it names the network event.

```luau
type PlayerState<S> = {
	name: string,
	get: (self, player: Player) -> S,
	find: (self, player: Player) -> S?,
	update: (self, player: Player, field: string, fn: (value: any) -> ...any) -> (),
	changed: (self, field: string, fn: (player: Player, value: any, old: any) -> ()) -> () -> (),
	replica: (self, viewer: Player, player: Player) -> { [string]: any }?,
}
```

| Member | Server | Client |
| --- | --- | --- |
| `Session:get(player): S` | The player's state object. Read fields (`state.coins`), assign to write (`state.coins = 5`). Errors before the player's `playerAdded` reached this system or after its `playerRemoving`. | Read-only view of what was replicated for `player`. Errors if nothing arrived yet. Assigning errors. |
| `Session:find(player): S?` | `get` or nil. | `get` or nil (nil until the first update arrives). |
| `Session:update(player, field, fn)` | Edits one field through a mutable copy. Mutate the copy, or return a new value. `fn` must not yield. | Errors. |
| `Session:changed(field, fn): () -> ()` | `fn(player, value, old)` after every change to `field` for any player, whatever caused it. Returns disconnect. | Fires when an update for `field` arrives, including the first (`old` is the default or nil). |
| `Session:replica(viewer, player)` | Testing only: a copy of what `viewer`'s client has received about `player`, or nil. Meaningful under `Hydrogen.loopback()`. | Same lookup. |
| `for field, value in state do` | Iterates every field. | Iterates the replicated fields. |

Field kinds:
- **Saved field**: every key of `data`'s template, plus every field its `gt.table` schema declares. Reads come from the store's data; writes call the store (schema-validated, saved by Data's autosave and on leave).
- **Runtime field**: every key of `runtime`. It starts at the given value on join and is dropped on leave. It is never saved and not validated.
- **Replicated field**: any saved or runtime field named in `replicate`. `"owner"` sends it to that player's client only; `"everyone"` sends it to all clients. Unlisted fields never leave the server.

## Rules

- Define each state in a shared module that both server and client require before `app:start()`. A state with any replicated field registers a network event (`Hydrogen/PlayerState/<name>`); requiring it on one side only shifts network ids and both sides warn `NETWORK MISMATCH`.
- The Data store must be added to the app too (on both sides when shared; it does nothing on clients).
- Order: the state `use`s its store. Its `playerAdded` runs after the store's (data loaded) and before the `playerAdded` of systems that `use` the state. Its `playerRemoving` runs before the store saves and after every system that `use`s the state, so those systems can still read and write in their own `playerRemoving`.
- Values are frozen. `table.insert(state.inventory, x)` errors. Do `Session:update(player, "inventory", function(items) table.insert(items, x) return nil end)` or assign a new table. Assigning copies and freezes the value.
- Assigning a saved field validates it at the assignment and errors there if invalid; the old value stays. Assigning an unknown field errors.
- Assigning a runtime field `nil` clears it, and replicates as cleared. You can't declare a runtime field whose starting value is nil (a table can't hold nil): use `false`, `0` or `""` as the empty value.
- Changes made directly through the store (`PlayerData:update`, `updateOnce`, `transaction`) update the state, fire `changed` and replicate. There is one source of truth: the store.
- Inside a `PlayerData:update`/`updateOnce`/`transaction` callback, assigning a saved field of the same player joins that pending change; the state shows the new value after the callback commits.
- If the player's data failed to load, the state still exists with template values (the player is being kicked). Writes to saved fields aren't persisted. Check `PlayerData:isLoaded(player)` if it matters.
- Reads are a plain table lookup through `__index` (cheap). Writes go through `__newindex`.
- Replication runs on `Hydrogen.State`: each replicated field is a `State.playerValue("<name>/<field>", ...)` visible to `"owner"` or `"everyone"`. Changes in a frame go out once at the end of the frame, only changed fields, only to allowed clients. A joining player receives their own owner and everyone fields plus every other player's everyone fields; leaving players are removed from every client. Under `Hydrogen.test`, the end of the frame is the next `t:advance`.
- On the client, the state is read-only. `get(player)` returns a live view for any player in the game: fields read their defaults until the server's values arrive, and fields the client can't see read `nil`. `get` errors (and `find` returns `nil`) only for a player who isn't in the game. Use `changed` to react when values arrive.
- Under `Hydrogen.loopback()` (one VM is server and clients), `get`/`find`/`changed` act as the server. Use `replica(viewer, player)` to assert what a client received.
- Each replicated field registers a State network object named `State/<name>/<field>`, so declare PlayerState in a shared module that both sides `require` before `app:start()`.

## Recipes

Owner-only currency, public level:

```luau
Hydrogen.PlayerState.new("Session", {
	data = PlayerData,
	replicate = { coins = "owner", level = "everyone" },
})
```

Runtime-only round state with no Data store:

```luau
local RoundState = Hydrogen.PlayerState.new("RoundState", {
	runtime = { kills = 0, alive = true, team = "" },
	replicate = { kills = "everyone", team = "everyone" },
})
-- server
RoundState:get(player).kills += 1
```

Leaderstats on the server from changes:

```luau
function Leaderstats:start()
	Session:changed("level", function(player: Player, level: any)
		local stats = player:FindFirstChild("leaderstats")
		local value = stats and stats:FindFirstChild("Level")
		if value and value:IsA("IntValue") then
			value.Value = level
		end
	end)
end
```

Edit a nested saved field:

```luau
Session:update(player, "inventory", function(items: { string })
	table.insert(items, "Sword")
	return nil
end)
Session:update(player, "level", function(level: number)
	return level + 1 -- returning a value replaces the field
end)
```

Grant from a purchase and see it replicate (no PlayerState call needed):

```luau
PlayerData:updateOnce(player, receipt.PurchaseId, function(data)
	data.coins += 100 -- Session's coins changes and is sent to the owner
	return nil
end)
```

Last word on leave:

```luau
function Combat:playerRemoving(player: Player)
	local state = Session:get(player) -- still exists here
	if state.inCombat then
		state.coins = math.max(0, state.coins - 10) -- saved: the store saves after this hook
	end
end
```

## Mistakes

- Don't define the state in a server-only module when anything replicates. Do define it (and its Data store) in a shared module both sides require.
- Don't mutate nested values (`state.inventory[1] = "x"`). Do use `Session:update(player, "inventory", fn)` or assign a new table.
- Don't write to the state on the client. Do fire a client event and write on the server.
- Don't call `Session:get(player)` on the client at startup. Do use `Session:find(player)` or `Session:changed(field, fn)`.
- Don't list a field in both `runtime` and the Data template. Do pick one (definition errors otherwise).
- Don't write `replicate = { coins = "all" }` or `"client"`. Do use exactly `"owner"` or `"everyone"`.
- Don't keep a separate copy of saved values in your system. Do read `Session:get(player).field` each time; it is cheap.
- Don't use `replicate` for secrets you'd rather keep server-side ("owner" still reaches that player's client, so exploiters can read it).
- Don't forget to add both the state and its store to the app on both sides.
- Don't rely on `changed` firing for the starting values on the server. On the server it fires only for changes after creation; read starting values in `playerAdded`.

## Testing

```luau
local Hydrogen = require(path.to.hydrogen)

local backend = Hydrogen.Data.memory()
local PlayerData = Hydrogen.Data.player("PlayerData", { template = { coins = 0, level = 1 }, backend = backend })
local Session = Hydrogen.PlayerState.new("TestSession", { -- unique name per test (network registration)
	data = PlayerData,
	runtime = { inCombat = false },
	replicate = { coins = "owner", level = "everyone" },
})

local net = Hydrogen.loopback()
local alice = net:join("Alice")
local bob = net:join("Bob")
local app = Hydrogen.App.new()
app:addSystems({ Session, PlayerData })
app:start()
assert(PlayerData:waitForLoad(alice) and PlayerData:waitForLoad(bob))

Session:get(alice).coins = 9
task.wait() -- replication goes out at the end of the frame
task.wait()
local aliceSees = Session:replica(alice, alice) :: any
local bobSees = Session:replica(bob, alice) :: any
assert(aliceSees.coins == 9 and bobSees.coins == nil and bobSees.level == 1)

app:stop()
net:close()
```

- State names register network events, so use a different `name` in each test. A name registered twice errors.
- Validation errors are synchronous at the assignment: `pcall(function() Session:get(alice).coins = -1 end)`.
- To test a system without real Data, `app:replace(PlayerDataStore, fake)`. The fake must implement what PlayerState calls: `get(player)`, `setField(player, field, value)` and `changed(fn) -> disconnect`.

## Errors and warnings

- `PlayerState.new needs a name`.
- `PlayerState <name>: data must be a store made with Hydrogen.Data.player`.
- `PlayerState <name>: "<field>" is both a saved field and a runtime field`: remove it from `runtime` or the template.
- `PlayerState <name>: replicate.<field> must be "owner" or "everyone", got <x>`.
- `PlayerState <name>: replicate names "<field>", which is neither a saved nor a runtime field`: typo, or add it to `runtime`/the template.
- `PlayerState <name> has no field "<field>"`: assignment to, or `changed` on, an undeclared field.
- `PlayerState <name> has no state for <player> (not added yet, or already removed)`: called before the player reached this system's `playerAdded` or after its `playerRemoving`. Use `find`, or `use` the state so ordering guarantees it.
- `PlayerState <name>: <player> isn't in the game (or nothing is replicated); use find` (client).
- `PlayerState is read-only on the client; change it on the server`.
- `<store> field "<field>" for <player> rejected: <cause>`: the value fails the Data schema; the old value stays.
- `PlayerState changed listener failed: <err>` (warning): your `changed` callback errored; others still ran.
- Data's own messages (load failures, kicks) are in `data.md`.

## Works with

- `Hydrogen.Data`: `data = <Data.player store>` provides saved fields. Writes go through the store, and any store change shows up in the state and replicates.
- `Hydrogen.Receipts`: with `Hydrogen.Receipts.fromData(PlayerData)`, grants are made through the store's `updateOnce`, so they update and replicate the state automatically.
- `Hydrogen.State`: the replication layer under PlayerState (one `State.playerValue` per replicated field, with `visibleTo` from `replicate`).
- `Hydrogen.Scope` / test harness: no special integration. The state is an ordinary system, so `app:replace` and the harness apply, and the harness resets State between tests.
