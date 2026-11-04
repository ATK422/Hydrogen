# Hydrogen.Signal

> A typed, in-process signal (`Signal.new<T...>()`, `Connect`, `Once`, `Wait`, `Fire`) for broadcasting events between systems on the same side (server or client) without them calling each other.

## Use it when / Don't use it when

Use it when:
- One system announces something that happened ("player died", "round ended", "item crafted") and any number of other systems react, and the announcer shouldn't know who listens.
- A system exposes an event for other systems to subscribe to (`Inventory.itemAdded`).
- A test needs to wait for or count an in-process event.

Don't use it when:
- The event must cross the network: use `Hydrogen.serverEvent` / `Hydrogen.clientEvent` (see network.md).
- You need the listener's return value: call a function on the system you `use` instead.
- You are watching replicated state: use `Hydrogen.State`'s `observe`, which also gives you the current value.
- You are watching saved data: use the Data store's `changed`.
- Both sides are in one system: just call a local function.

## Quick start

```luau
-- ReplicatedStorage/Shared/Events.luau (required by server systems)
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

-- The type annotation is what makes Fire/Connect/Wait typed.
local PlayerDied: Hydrogen.Signal<Player, Player?> = Hydrogen.Signal.new("PlayerDied") -- victim, killer

return {
	PlayerDied = PlayerDied,
}
```

```luau
-- ServerScriptService/Systems/Quests.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Events = require(ReplicatedStorage.Shared.Events)

return Hydrogen.define(function(use)
	local Quests = { kills = {} :: { [Player]: number } }

	function Quests:start()
		-- Disconnected on app:stop().
		Hydrogen.Scope.of(self):add(Events.PlayerDied:Connect(function(victim: Player, killer: Player?)
			if killer then
				Quests.kills[killer] = (Quests.kills[killer] or 0) + 1
			end
		end))
	end

	return Quests
end)
```

```luau
-- In the combat system, where a death happens:
Events.PlayerDied:Fire(victim, killer)
```

## API

Module: `local Signal = Hydrogen.Signal`. Types: `Hydrogen.Signal<T...>`, `Hydrogen.Connection`. Works the same on server and client. Methods are PascalCase like `RBXScriptSignal`.

```luau
Signal.new<T...>(name: string?): Signal<T...>
-- A new signal. Annotate the variable to fix T...: local s: Hydrogen.Signal<number, string> = Signal.new()
-- name appears in listener error warnings.

Signal.is(value: any): boolean
-- True for a Hydrogen signal.

signal:Connect(listener: (T...) -> ()): Connection
-- Calls listener(...) on every Fire, in connection order.

signal:Once(listener: (T...) -> ()): Connection
-- Like Connect; the connection is disconnected before the listener runs.

signal:Wait(): T...
-- YIELDS until the next Fire; returns its arguments. Errors on a destroyed signal.

signal:Fire(...: T...): ()
-- Runs every listener connected when Fire starts, now. Does not yield. Never throws a listener's error.

signal:FireDeferred(...: T...): ()
-- Fire via task.defer: listeners run after the current thread yields.

signal:DisconnectAll(): ()
-- Disconnects every listener. The signal keeps working.

signal:Destroy(): ()
-- DisconnectAll, and from now on Connect/Once return a disconnected connection and Fire does nothing.

connection:Disconnect(): ()
-- Stops the listener. Idempotent. scope:add(connection) calls it on cleanup.

connection.Connected: boolean  -- read-only; false after Disconnect, Once firing, DisconnectAll or Destroy
```

## Rules

- **Immediate dispatch.** `Fire` returns after every listener has run or reached its first yield. Listeners run one after another, in connection order.
- **Yields are isolated.** Listeners share one reused thread per `Fire`. If a listener yields, that thread stays with it and `Fire` continues the remaining listeners on a new thread. A yielding listener never delays the others or the firer.
- **Errors are isolated.** A listener that errors (before or after yielding) is reported with `Log.warn` as `[HYDROGEN] Listener of signal <name> failed: <message + traceback>` (or `Signal listener failed:` without a name). The other listeners still run. `Hydrogen.test` captures the warning.
- **Connect during Fire:** the new listener is not called by the `Fire` in progress, only by later ones.
- **Disconnect during Fire:** a listener disconnected before the in-progress `Fire` reached it is not called. Self-disconnect never skips the next listener. `DisconnectAll` during a `Fire` skips the rest.
- **Nested Fire:** `Fire` from inside a listener runs all listeners (with the inner arguments) before the outer `Fire` moves on: `a1, a2, b2, b1`.
- **Arguments** are passed as-is, `nil`s included; tables are not copied. Don't mutate a table after firing it if a listener might have yielded with it.
- **Memory:** disconnecting removes the listener from the signal and clears the connection's reference to the function, so a kept connection doesn't keep the closure alive. A signal with no listeners holds nothing.
- **Wait on a signal that is destroyed or never fires again** never resumes.
- **One side only.** A signal is a Lua object; server and client each get their own copy of a shared module.
- **Types:** `Signal.new()` infers `T...` from the annotated variable or field. Without an annotation the signal is untyped.
- **Cost:** in Roblox Studio, one `Fire` takes about 0.9 µs with 1 listener, 1.9 µs with 5 and 3.6 µs with 20. A BindableEvent takes 2.3 µs and 5.4 µs with 1 and 5; a thread-per-listener signal 4.8 µs and 15 µs with 5 and 20; a plain table of callbacks 0.05 µs per listener. `Connect` + `Disconnect` takes about 0.6 µs. Disconnecting is O(listeners).

## Recipes

### A system exposes an event

```luau
return Hydrogen.define(function(use)
	local itemAdded: Hydrogen.Signal<Player, string> = Hydrogen.Signal.new("Inventory.itemAdded")
	local Inventory = { itemAdded = itemAdded }

	function Inventory.give(player: Player, item: string)
		-- ...store it...
		itemAdded:Fire(player, item)
	end

	return Inventory
end)

-- Another system:
-- local Inventory = use(InventorySystem)
-- Scope.of(self):add(Inventory.itemAdded:Connect(function(player, item) ... end))
```

### Per-player listener that stops when the player leaves

```luau
function Achievements:playerAdded(player: Player)
	Hydrogen.Scope.of(self, player):add(Inventory.itemAdded:Connect(function(owner: Player, item: string)
		if owner == player and item == "Legendary Sword" then
			unlock(player, "Legend")
		end
	end))
end
```

### Wait for the next event, with a timeout

```luau
local function waitForRoundEnd(timeout: number): boolean
	local thread = coroutine.running()
	local connection = RoundEnded:Once(function()
		task.spawn(thread, true)
	end)
	local timer = Hydrogen.Scheduler.after(timeout, function()
		connection:Disconnect()
		task.spawn(thread, false)
	end)
	local ended = coroutine.yield()
	timer:cancel()
	return ended
end
```

### Fire after the current work finishes

```luau
-- Listeners see the inventory only after the whole batch is applied.
for _, item in items do
	addWithoutNotifying(player, item)
end
InventoryChanged:FireDeferred(player)
```

## Mistakes

- Don't write `local s = Signal.new()` and expect typed listeners. Do annotate: `local s: Hydrogen.Signal<Player, number> = Signal.new()`.
- Don't `signal:Connect(fn)` in a hook and drop the connection. Do `Scope.of(self):add(signal:Connect(fn))` (or the player scope).
- Don't use a Signal to talk to the other side of the network. Do use `Hydrogen.serverEvent` / `clientEvent`.
- Don't rely on `pcall(signal.Fire, signal, ...)` to see listener errors; `Fire` never throws them. Do check warnings (`t:expectWarning` in tests).
- Don't do long yielding work inline in many listeners expecting it to run in parallel and finish before `Fire` returns. It does run concurrently, but `Fire` returns at the first yield. Do signal completion with another signal or a callback.
- Don't call `signal:Wait()` on the test's main thread under the fake clock expecting time to pass. Do `Fire` from the test, or `task.spawn` the waiter, then `Fire`.
- Don't connect inside a listener on every `Fire` without disconnecting (listeners pile up). Do use `Once`, or connect once outside.

## Testing

Signals need no setup: fire them from the test and assert on the next line, because dispatch is immediate.

```luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Events = require(ReplicatedStorage.Shared.Events)
local Quests = require(ServerScriptService.Systems.Quests)

Hydrogen.test({ systems = { Quests }, players = { "Alice", "Bob" } }, function(t, alice, bob)
	Events.PlayerDied:Fire(bob, alice)
	assert(Quests.kills[alice] == 1)
end)
-- app:stop() at the end of the test destroyed Quests' scope, so the listener is gone.
```

- Listener errors become warnings that `Hydrogen.test` captures: `t:expectWarning("Listener of signal PlayerDied failed")`.
- To count fires, connect in the test: `local n = 0; signal:Connect(function() n += 1 end)`.
- To wait in a test, run the waiter in `task.spawn(function() result = signal:Wait() end)`, then fire.
- `FireDeferred` listeners run after the test's thread yields (`task.wait()`).

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `[HYDROGEN] Listener of signal <name> failed: <error + traceback>` (warning) | A listener connected to the named signal errored. Other listeners still ran. | Fix the listener; the traceback points at it. |
| `[HYDROGEN] Signal listener failed: <error + traceback>` (warning) | Same, for a signal made without a name. | Pass a name to `Signal.new(name)` to find it faster. |
| `[HYDROGEN] signal:Connect expects a function, got <type>` (error) | `Connect` was given a non-function, often `nil` from a typo. | Pass the function. |
| `[HYDROGEN] signal:Once expects a function, got <type>` (error) | Same, for `Once`. | Pass the function. |
| `[HYDROGEN] signal:Wait() on a destroyed signal would never resume` (error) | `Wait` was called after `Destroy`. | Don't wait on a destroyed signal; check your lifetimes. |

## Works with

- **Scope** (scope.md): `scope:add(signal:Connect(fn))` disconnects with the system or player lifetime. `scope:connect(signal, fn)` also works at runtime, but its type is declared for `RBXScriptSignal`, so prefer `add` in strict mode.
- **Scheduler** (scheduler.md): combine `Once` with `Scheduler.after` for a wait with a timeout.
- **Network** (network.md): use network events across the client/server boundary; a server system can relay a network event into a Signal for other server systems.
- **State** (state.md) and **Data** (data.md): their `observe` / `changed` return disconnect functions and are the right way to watch state and saved data; use a Signal for events that aren't state.
- **Hydrogen.test** (testing.md): captures listener-error warnings; fire signals directly from tests.
