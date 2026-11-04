# Hydrogen.Scope

> Cleanup tied to a lifetime: a scope collects connections, threads, Instances and cleanup functions and undoes them all when the system stops, the player leaves, or you destroy it yourself.

## Use it when / Don't use it when

Use it when:
- A system creates something per player (connections, Instances, loops, listeners) that must go away when that player leaves.
- A system creates something for its whole life (a `Heartbeat` connection, a loop) that must stop on `app:stop()` (server shutdown, or the end of a test).
- You need a sub-lifetime: a round, a character, an open UI. Use `scope:child()`.
- Async work (a DataStore load, a `task.delay`) may finish after its player left and must not leak.

Don't use it when:
- The thing is already destroyed with its owner by Roblox (children of the `Player` or the character). Tracking them is harmless but unnecessary.
- You need a value or state store. Scope only cleans things up.
- You want listeners for every player. Register one network listener per system, not one per player (see Mistakes).

## Quick start

```luau
-- ServerScriptService/Systems/Arena.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Scope = Hydrogen.Scope

return Hydrogen.define(function(use)
	local Arena = {}

	function Arena:start()
		-- System scope: destroyed on app:stop(), right after Arena's stop hook.
		Scope.of(self):connect(RunService.Heartbeat, function(dt: number)
			-- per-frame work
		end)
	end

	function Arena:playerAdded(player: Player)
		-- Player scope: destroyed right after Arena's playerRemoving for this player.
		local scope = Scope.of(self, player)

		local arena = scope:add((ServerStorage:WaitForChild("ArenaTemplate") :: Model):Clone())
		arena.Name = `Arena_{player.UserId}`
		arena.Parent = workspace

		scope:connect(player.CharacterAdded, function(character: Model)
			character:PivotTo(arena:GetPivot())
		end)

		scope:spawn(function()
			while true do
				task.wait(1)
				-- regenerate, award, etc.
			end
		end)
	end

	return Arena
end)
```

```luau
-- ServerScriptService/Main.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addSystemsFolders(ServerScriptService.Systems)
app:start() -- on the server, app:stop() is bound to game:BindToClose
```

Client systems use it the same way (`Scope.of(self)`, `Scope.of(self, player)`). Nothing has to be shared between server and client.

## API

Module: `local Scope = Hydrogen.Scope`. Type: `Hydrogen.Scope`. Available on the server and the client. Nothing in the API yields by itself. `destroy`, `remove` and `add` on a destroyed scope run cleanup tasks in the calling thread, so they yield only if a cleanup task yields.

```luau
Scope.new(name: string?): Scope
```
A root scope that you destroy yourself. `name` appears in cleanup warnings.

```luau
Scope.of(system: any, subject: Instance?): Scope
```
`Scope.of(system)` is the system's scope. `Scope.of(system, player)` is the system's scope for that player. `Scope.of(system, character)` is its scope for that character (see `character.md`). Each is created on the first call, and every later call returns the same object. `system` is the table returned by `Hydrogen.define`, so pass `self` inside a hook, or the system table from anywhere else. Errors are listed under Errors and warnings; see Rules for when the call is valid.

Methods on `Scope`:

```luau
scope:add<T>(task: T): T
```
Tracks `task` and returns it unchanged. On cleanup: a `function` is called, a `thread` is cancelled, an `RBXScriptConnection` is disconnected, an `Instance` is destroyed, a `Scope` is destroyed, and any other table or userdata gets its first method found among `Destroy`, `Disconnect`, `destroy`, `disconnect`, `cancel`, `Cancel` called (Trove, Maid, Janitor, signal connections, promises). Anything else errors immediately. Adding the same task twice tracks it once.

```luau
scope:connect<T...>(signal: RBXScriptSignal<T...>, callback: (T...) -> ()): RBXScriptConnection
```
`signal:Connect(callback)`, tracked. At runtime any table with `Connect` (or `connect`) works too, and the result is tracked with `add`.

```luau
scope:spawn<A...>(callback: (A...) -> ...any, A...): thread
```
`task.spawn`. The thread is cancelled if the scope is destroyed first and forgotten once it finishes. If the callback errors, the error is rethrown in that thread (normal error output) and the thread is forgotten.

```luau
scope:delay<A...>(seconds: number, callback: (A...) -> ...any, A...): thread
```
`task.delay`. Cancelled if the scope is destroyed before it runs or while it runs, and forgotten once it finishes.

```luau
scope:child(name: string?): Scope
```
A new scope tracked by this one. It is destroyed with the parent, or earlier with `child:destroy()`, which also removes it from the parent.

```luau
scope:remove(task: any): ()
```
If `task` is tracked, cleans it now and stops tracking it. Otherwise does nothing.

```luau
scope:destroy(): ()
scope:Destroy(): ()  -- alias, so Trove/Maid/Janitor can hold a scope
```
Marks the scope dead, then cleans every task newest first. Calling it again does nothing.

```luau
scope.alive: boolean  -- read-only
scope.name: string?   -- read-only
```
`alive` is `false` once the scope is destroyed. App scopes are named `<system>` and `<system> for <PlayerName>`; a fake installed with `app:replace` shows as `<system> (replaced)`.

## Rules

What is tracked automatically and what isn't:
- **Only what goes through the scope is tracked:** `add`, `connect`, `spawn`, `delay` and `child`. Luau can't intercept `RBXScriptSignal:Connect`, `task.spawn`, `task.delay`, `Instance.new`, `:Clone()` or network `:On`, so calling any of those directly is not tracked and will leak past the lifetime.
- **Automatic:** creating the app scopes on first `Scope.of`, destroying them at the right moment, forgetting `spawn`/`delay` threads that finished, removing a child from its parent when the child is destroyed early, and cleaning anything added to a destroyed scope.
- **Hooks are never given a scope.** Always call `Scope.of(self)` or `Scope.of(self, player)`. A system that never calls `Scope.of` creates no scope and costs nothing.

When `Scope.of` is valid:
- `Scope.of(system)` works once the app that runs the system has started (from `init` on) and returns the same live scope until `app:stop()` runs that system's `stop` hook. After that it returns a destroyed scope. Before any app has started the system (for example, in the `define` constructor body), it errors.
- `Scope.of(system, character)` works from the character's first `characterAdded` until that system's `characterRemoving` for it returns, then hands out a destroyed scope. It's separate from the player scope and always destroyed before it. For a model the app never added, it errors.
- `Scope.of(system, player)` works from the moment the app starts adding the player (before the first `playerAdded`) until that system's `playerRemoving` for the player returns. During `playerRemoving`, the scopes of systems that already ran theirs are destroyed, and the scopes of systems still to run are live. After the player is fully removed, or once the app has stopped, it returns a destroyed scope. For a player the app hasn't added yet, it errors. That happens if you call it from your own `Players.PlayerAdded` connection that runs before Hydrogen's; use `playerAdded` instead.
- A destroyed scope cleans everything added to it immediately, and `spawn`/`delay` on it never run. Late async code is therefore safe, but check `scope.alive` after a yield to skip work that would be wasted.

Cleanup order:
- **Inside one scope:** newest first (reverse order of `add`).
- **Player leaves:** for each system in reverse dependency order: that system's `playerRemoving(player)` runs, then its player scope is destroyed. So a system's player scope is gone before the systems it `use`s run their `playerRemoving` (and `Data` saves last).
- **Player leaves while a `playerAdded` hook is still running (yielded):** removal waits until every `playerAdded` hook for that player has returned, then proceeds as above. A thread started with `scope:spawn` inside `playerAdded` is cancelled when the scope is destroyed.
- **`app:stop()`:** first, for every player still in the game, `playerRemoving` and the player scope destruction above (players in parallel), and stop waits for all of them. Then for each system in reverse dependency order: its `stop` hook runs, then its system scope is destroyed. On the server, this is what `game:BindToClose` runs.
- **A boot that errors (`init`/`start` threw):** the system scopes are destroyed in reverse dependency order and `app:start()` rethrows.
- **`app:replace(original, fake)`:** `Scope.of(original)` and `Scope.of(fake)` return the same scopes, which belong to the slot the fake fills.

Other rules:
- Cleanup runs in the thread that destroys the scope. A task that yields delays the next task, and for a player scope also the next system's `playerRemoving` for that player.
- A task that errors during cleanup is warned with its traceback and the remaining tasks still run. Errors never propagate out of `destroy`.
- Destroyed is final: there is no reset. For repeated lifetimes (rounds, characters), create a new `child()` each time.
- A thread that destroys its own scope (for example, from inside `scope:spawn`) is not cancelled; it runs to completion.
- Limits: none on task count. `add`/`remove` are O(1); `destroy` sorts once, O(n log n).

## Recipes

Per-character lifetime inside the player lifetime:

```luau
function Combat:playerAdded(player: Player)
	local scope = Scope.of(self, player)
	local life: Hydrogen.Scope? = nil

	local function onCharacter(character: Model)
		if life then
			life:destroy()
		end
		local current = scope:child("character")
		life = current
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		current:connect(humanoid.Died, function()
			-- respawn timers, kill credit, ...
		end)
	end

	scope:connect(player.CharacterAdded, onCharacter)
	local character = player.Character
	if character then
		onCharacter(character)
	end
end
```

Async load that may outlive the player:

```luau
local DataStoreService = game:GetService("DataStoreService")
local store = DataStoreService:GetDataStore("Coins")

function Profiles:playerAdded(player: Player)
	local scope = Scope.of(self, player)
	scope:spawn(function()
		-- Yields; the player may leave meanwhile.
		local ok, saved = pcall(store.GetAsync, store, tostring(player.UserId))
		if not scope.alive then
			return -- player gone: don't build anything
		end
		local coins = scope:add(Instance.new("IntValue"))
		coins.Name = "Coins"
		coins.Value = if ok and type(saved) == "number" then saved else 0
		coins.Parent = player
	end)
end
```

A round as a child of the system scope:

```luau
local ServerStorage = game:GetService("ServerStorage")

function Rounds:startRound()
	local round = Scope.of(self):child("round")
	local map = round:add((ServerStorage:WaitForChild("Map") :: Model):Clone())
	map.Parent = workspace
	round:delay(120, function()
		round:destroy() -- ends the round: map, timers and connections go with it
	end)
	return round
end
```

One network listener per system, with per-player state cleaned by the player scope:

```luau
-- Shared module: return { Attack = Hydrogen.clientEvent("Attack", Hydrogen.gt.number()) }
local Remotes = require(ReplicatedStorage.Network.Remotes)

return Hydrogen.define(function(use)
	local Combat = {}
	local lastAttack: { [Player]: number } = {}

	function Combat:start()
		-- One listener for everyone; :On returns a disconnect function.
		Scope.of(self):add(Remotes.Attack:On(function(player: Player, targetId: number)
			local now = os.clock()
			if now - (lastAttack[player] or 0) < 0.5 then
				return
			end
			lastAttack[player] = now
		end))
	end

	function Combat:playerAdded(player: Player)
		Scope.of(self, player):add(function()
			lastAttack[player] = nil
		end)
	end

	return Combat
end)
```

Interop with other cleanup libraries:

```luau
local Trove = require(ReplicatedStorage.Packages.Trove) -- any Trove/Maid/Janitor

local trove = Trove.new()
Scope.of(self, player):add(trove) -- trove:Destroy() runs when the player leaves
trove:Add(Scope.new("ui"))         -- Trove can clean a scope: it has Destroy
```

## Mistakes

- Don't call `player.CharacterAdded:Connect(fn)` (or any raw `:Connect`) in `playerAdded`, because it is never disconnected. Do `Scope.of(self, player):connect(player.CharacterAdded, fn)`.
- Don't `task.spawn(loop)` or `task.delay(t, fn)` for per-player work. Do `scope:spawn(loop)` / `scope:delay(t, fn)` so they are cancelled when the player leaves.
- Don't `Instance.new(...)`/`:Clone()` a per-player object without tracking it. Do `local part = scope:add(Instance.new("Part"))`.
- Don't call `Remote:On(fn)` and drop the returned function. Do `scope:add(Remote:On(fn))`.
- Don't call `scope:connect(Remote, fn)` on a Hydrogen network object; it errors. Do `scope:add(Remote:On(fn))`.
- Don't register a network listener per player inside `playerAdded` (every listener hears every player). Do register once with `Scope.of(self)` in `start`, and check the `player` argument.
- Don't call `Scope.of(self)` in the `define` constructor body; it errors because no app runs the system yet. Do call it in `init`, `start` or later.
- Don't call `Scope.of(self, player)` from your own `Players.PlayerAdded:Connect`; it can run before Hydrogen adds the player and error. Do use the `playerAdded` hook.
- Don't write `function S:playerAdded(player, scope)` and expect a scope; hooks get no scope argument. Do `local scope = Scope.of(self, player)`.
- Don't keep building after a yield without checking. Do `if not scope.alive then return end` after a yield.
- Don't reuse a scope after `destroy` (adds are cleaned immediately). Do create a new `child()` for each round or character.
- Don't save player data from a player-scope cleanup function. Do save in `Data`'s `playerRemoving`; scopes are for undoing things, and they run after that system's `playerRemoving`.
- Don't keep your own `{ [Player]: Scope }` map. Do call `Scope.of(self, player)` wherever you need it; it is a table lookup and always returns the right scope (or a destroyed one after the player left).

## Testing

Run a real app headlessly with `Hydrogen.loopback()`. Fake players get `playerAdded`, and `net:leave` runs `playerRemoving` and destroys their scopes:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Arena = require(script.Parent.Systems.Arena)

local net = Hydrogen.loopback()
local alice = net:join("Alice")

local app = Hydrogen.App.new()
app:addSystem(Arena)
app:start()

local scope = Hydrogen.Scope.of(Arena, alice)
assert(scope.alive)

net:leave(alice)
assert(not scope.alive)                          -- destroyed after Arena's playerRemoving
assert(not Hydrogen.Scope.of(Arena, alice).alive) -- late calls get a destroyed scope

app:stop()                                       -- destroys Arena's system scope
assert(not Hydrogen.Scope.of(Arena).alive)
net:close()
```

- Always `app:stop()` at the end of a test. That destroys every system and player scope, so connections and loops don't leak into the next test.
- With `app:replace(Original, fake)`, the fake's hooks can call `Scope.of(self)` / `Scope.of(self, player)` and get the same scopes as `Scope.of(Original)`.
- Test standalone logic with `Scope.new()`: add tasks, call `destroy()`, and assert that your cleanup ran.
- To check that something was cleaned, add a function that sets a flag (`scope:add(function() cleaned = true end)`) or assert `scope.alive`.
- Fakes shipped: none needed. `scope:delay` runs on `Hydrogen.Clock`, so under `Hydrogen.test` it fires on `t:advance(seconds)`.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `[HYDROGEN] Cleanup failed in scope <name>: <error + traceback>` (warning) | A cleanup task errored while scope `<name>` was being destroyed (or on `remove`, or when added to a destroyed scope). The other tasks still ran. | Fix the task; the traceback points at it. `<name>` is the system, `<system> for <Player>`, or your `Scope.new(name)`. |
| `[HYDROGEN] Scope cleanup failed: <error + traceback>` (warning) | Same, for an unnamed scope (`Scope.new()` with no name, or an add to the shared destroyed scope a finished lifetime hands out). | Same; name your scopes to find them faster. |
| `[HYDROGEN] A scope can't clean a <type>. Add a function, connection, Instance, thread, scope, or an object with Destroy, Disconnect or cancel` (error from `add`) | You added a value with no way to clean it (a number, string, plain table, `nil`). | Add the connection/Instance/function itself, or wrap it: `scope:add(function() ... end)`. |
| `[HYDROGEN] A scope can't be added to itself` (error) | `scope:add(scope)`. | Add a `child()` instead. |
| `[HYDROGEN] scope:connect takes a signal. For a Hydrogen network object use scope:add(object:On(callback))` (error) | You passed a Hydrogen network object to `connect`. | `scope:add(Remote:On(callback))`. |
| `[HYDROGEN] scope:connect expects a signal with Connect, got <type>` (error) | The first argument isn't a signal (often `nil` from a typo'd event name). | Pass an `RBXScriptSignal` or a signal object with `Connect`. |
| `[HYDROGEN] Scope.of: <system> isn't running in an app. Ask for its scope from init or later` (error) | The system isn't in any started app: called at require/constructor time, or the system was never added to an app. | Call from `init`/`start`/hooks or later, and add the system to the app. |
| `[HYDROGEN] Scope.of: <Name> hasn't been added to the app yet. Ask for a player's scope from playerAdded or later` (error) | The app doesn't know this player yet (your own `PlayerAdded` connection ran first, or a fake player object the app never saw). | Use the `playerAdded` hook; in tests use `net:join` (loopback). |
| `[HYDROGEN] Scope.of: <model> isn't a character (or other subject) the app has added. Ask for its scope from characterAdded or later` (error) | `Scope.of(system, model)` for a model that isn't a character the app has added. | Ask from `characterAdded`, and in tests give the player a character with `t:spawnCharacter`. |

An error inside a `scope:spawn`/`scope:delay` callback is not a `[HYDROGEN]` message. It is rethrown in that thread as `<error>` plus a traceback, like any `task.spawn` error.

## Works with

- **Systems (`Hydrogen.define`, `App`)**: Scope's lifetimes are the app's. Player scopes follow `playerAdded`/`playerRemoving`, character scopes follow `characterAdded`/`characterRemoving` (`character.md`), and system scopes follow `start`/`stop`, all in dependency order. `app:replace` fakes share the original's scopes.
- **Network**: every `:On` returns a disconnect function, so `scope:add(Remote:On(fn))` ties a listener to a lifetime. Prefer system-scope listeners and check the `player` argument.
- **Data / PlayerState**: load inside `playerAdded` (for example `PlayerData:waitForLoad(player)`, which yields and returns `false` if the player left or the load failed), then check `Scope.of(self, player).alive` before building. Keep saving in `playerRemoving`, not in scope cleanup.
- **State**: `observe` returns a disconnect function, so `Scope.of(self, player):add(Coins:observe(player, fn))` stops observing when the player leaves. On the client, put UI observers in `Scope.of(self)` or a `child()` per screen.
- **Testing harness / `Hydrogen.Clock`**: `scope:delay` runs on `Hydrogen.Clock`, so a fake clock's `advance` drives it. Stopping the app in the harness destroys all scopes.
- **Receipts** (kit): no direct interaction. Receipts doesn't need per-player cleanup from you.
