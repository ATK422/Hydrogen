# Hydrogen.Scheduler

> Timers tied to lifetimes: `after`, `every`, `fixed` (a fixed-timestep game loop with catch-up), `debounce` and `throttle`. They run on `Hydrogen.Clock`, so `t:advance` drives them in tests, and `timer:bind(self)` cancels them with a system or player.

## Use it when / Don't use it when

Use it when:
- Something runs repeatedly (regeneration, spawning waves, autosave pings): `every`.
- Something runs once later (respawn, buff expiry, round timer): `after`.
- Gameplay simulation must step at a fixed rate (projectiles, AI, a 20 Hz server loop): `fixed`.
- Bursts of calls should collapse into one (save after edits stop: `debounce`; at most N per second: `throttle`).
- The timer belongs to a system or player and must stop when it ends: `:bind(self)` / `:bind(self, player)`.

Don't use it when:
- Work must run every rendered frame (camera, visual interpolation): use `RunService.RenderStepped` / `Clock.heartbeat` in a scope.
- A thread just needs to pause inside a coroutine: `Hydrogen.Clock.wait(seconds)` is simpler.
- You need a cooldown check ("can this player attack yet?"): compare `Hydrogen.Clock.now()` against a stored time; no timer needed.

## Quick start

```luau
-- ServerScriptService/Systems/Health.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Scheduler = Hydrogen.Scheduler

return Hydrogen.define(function(use)
	local Health = { hp = {} :: { [Player]: number } }

	function Health:playerAdded(player: Player)
		Health.hp[player] = 100
		-- Regenerate 5 HP a second until the player leaves.
		Scheduler.every(1, function()
			Health.hp[player] = math.min((Health.hp[player] or 0) + 5, 100)
		end):bind(self, player)
	end

	function Health:playerRemoving(player: Player)
		Health.hp[player] = nil
	end

	return Health
end)
```

```luau
-- Tests/Health.spec.luau
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Health = require(ServerScriptService.Systems.Health)

Hydrogen.test({ systems = { Health }, players = { "Alice" } }, function(t, alice)
	Health.hp[alice] = 50
	t:advance(3)
	assert(Health.hp[alice] == 65)
end)
```

## API

Module: `local Scheduler = Hydrogen.Scheduler`. Types: `Hydrogen.Timer`, `Hydrogen.EveryOptions`, `Hydrogen.FixedOptions`. Server and client. Nothing here yields.

```luau
Scheduler.after(seconds: number, fn: () -> ()): Timer
-- fn() once, after seconds (>= 0).

Scheduler.every(seconds: number, fn: (elapsed: number) -> (), options: EveryOptions?): Timer
-- fn(elapsed) every seconds (> 0), first after one interval. elapsed = time since the last run (or creation).
export type EveryOptions = { jitter: number? }  -- add random 0..jitter seconds to each interval

Scheduler.fixed(seconds: number, fn: (dt: number) -> (), options: FixedOptions?): Timer
-- Fixed timestep: fn(seconds) once per step; step k is due at creation + k * seconds.
export type FixedOptions = { maxSteps: number? }  -- most steps per catch-up after a hitch; default 5

Scheduler.debounce<A...>(seconds: number, fn: (A...) -> ()): ((A...) -> (), () -> ())
-- Returns call, cancel. call(...) (re)starts a seconds countdown; fn runs once with the last call's args.

Scheduler.throttle<A...>(seconds: number, fn: (A...) -> ()): ((A...) -> (), () -> ())
-- Returns call, cancel. call(...) runs fn now if seconds passed since the last run (synchronously, in the
-- caller's thread); otherwise it schedules one trailing run at the end of the window with the last args.

Scheduler.count(): number
-- Timers waiting to run (paused ones excluded). For leak checks in tests.

timer:cancel(): ()             -- stops for good; idempotent; safe inside its own callback
timer:pause(): ()              -- stops the countdown, keeps the time left
timer:resume(): ()             -- continues with the time left (fixed: steps continue from now, paused time not caught up)
timer:bind(scope: Scope): Timer                    -- scope:add(timer); returns timer
timer:bind(system: any, player: Player?): Timer    -- Scope.of(system, player):add(timer); returns timer
timer.active: boolean          -- read-only; false once cancelled or once an after timer ran
timer.paused: boolean          -- read-only
```

## Rules

- **Clock:** every timer reads `Hydrogen.Clock` (`now`, `delay`, `cancel`) at call time. Under `Hydrogen.test`, `t:advance(seconds)` runs every timer due in that window, in order, and `Clock.now()` inside a callback is that timer's own due time. `t:advance(300)` runs `every(60)` five times, and `t:advance(1)` runs `fixed(1/20)` 20 times.
- **Order:** timers run by due time. Ties run in creation order. They interleave correctly with `Clock.delay` and `Clock.wait` in the same advance. A timer created inside a callback with a due time of now (`after(0)`) runs right after that pass, still in the same `advance`.
- **Errors:** a callback error is warned as `[HYDROGEN] Scheduler: <kind>(<seconds>) callback failed: <error + traceback>` (`debounce(…)` / `throttle(…)` for those). The timer keeps running and other timers are unaffected. A throttle's immediate run is called in the caller's thread, so its errors propagate to the caller.
- **Yields:** callbacks run on a reused thread. A callback that yields keeps that thread, and other timers continue. A repeating timer (`every`, `fixed`) whose previous run is still yielded **skips** its runs until that run returns, with one warning per timer: `skipped a run because its last run yielded`. Runs never overlap or queue up.
- **Late wake-ups (server hitch, long callback):** `every` keeps its phase if less than one interval was missed. Otherwise it runs once and its next run is a full interval after that, with no burst. `fixed` runs the missed steps back to back, up to `maxSteps`, drops the rest, and continues at the next step boundary after now. All steps of one catch-up see the same `Clock.now()`.
- **Cost:** all timers share one min-heap and **one** pending `Clock.delay` (for the earliest timer). There is no Heartbeat connection and no per-frame work. With no active timers, nothing is scheduled at all. Create, cancel and fire are O(log n). Requiring the module does nothing.
- **Lifetimes:** a timer not bound to a scope runs until cancelled. `bind` on a destroyed scope cancels the timer immediately. `bind(system, player)` follows `Scope.of` rules: valid from `init` / `playerAdded` on, and it errors outside a running app.
- **Fake clock swaps:** when a test installs or restores a fake clock, timers created on the previous clock are dropped (they become `active = false`), just as the fake clock drops its waiting threads. In a game the clock never changes.
- `every` and `fixed` need `seconds > 0`; `after` and `debounce` accept 0. NaN and infinity are rejected.
- Jitter uses `math.random`.

## Recipes

### Round timer with a countdown, cancelled when the round ends

```luau
function Rounds:startRound()
	local round = Hydrogen.Scope.of(self):child("round")
	local left = 120
	Scheduler.every(1, function()
		left -= 1
		RoundState:set(left) -- e.g. a Hydrogen.State value
	end):bind(round)
	Scheduler.after(120, function()
		round:destroy() -- ends the countdown too
		self:startRound()
	end):bind(round)
end
```

### 20 Hz server simulation

```luau
function Projectiles:start()
	Scheduler.fixed(1 / 20, function(dt: number)
		for _, projectile in Projectiles.active do
			projectile.position += projectile.velocity * dt
		end
	end, { maxSteps = 4 }):bind(self)
end
```

### Save after edits stop

```luau
function Builder:playerAdded(player: Player)
	local save, cancel = Scheduler.debounce(2, function()
		PlayerData:save(player)
	end)
	Hydrogen.Scope.of(self, player):add(cancel)
	Builder.saveSoon[player] = save -- call saveSoon[player]() after each edit
end
```

### Rate-limit a broadcast

```luau
local broadcastScore, cancelBroadcast = Scheduler.throttle(0.25, function(score: number)
	ScoreChanged:FireAll(score)
end)
-- broadcastScore(n) as often as you like: at most 4 sends a second, and the last value always goes out.
```

### Pause timers while the game is paused

```luau
local spawner = Scheduler.every(10, spawnWave):bind(self)
GamePaused:Connect(function(paused: boolean)
	if paused then
		spawner:pause()
	else
		spawner:resume()
	end
end)
```

### Spread out many identical timers

```luau
-- 50 NPCs created in the same frame think at different moments instead of all at once.
for _, npc in npcs do
	Scheduler.every(2, function()
		think(npc)
	end, { jitter = 0.5 }):bind(self)
end
```

## Mistakes

- Don't call `Scheduler.every(...)` in `playerAdded` without binding. It keeps running after the player leaves. Do `:bind(self, player)`.
- Don't write `while true do task.wait(1) ... end` loops in systems. Do `Scheduler.every(1, fn):bind(self)`: it's cancelled with the system, testable with `t:advance`, and isn't a thread per loop.
- Don't use `task.delay` / `task.wait` for game timers you want to test. Do use `Scheduler` (or `Hydrogen.Clock`).
- Don't yield in an `every` / `fixed` callback (DataStore calls, `WaitForChild`, `task.wait`). Runs are skipped while it waits. Do `task.spawn` the slow part, or chain `Scheduler.after` calls.
- Don't use `fixed` for one-off delays or slow intervals. Do use `after` / `every`; `fixed` exists for simulation steps.
- Don't expect `fixed` to catch up after a long pause or hitch. It runs at most `maxSteps` steps and drops the rest, by design. Raise `maxSteps` if you need more.
- Don't write `Scheduler.fixed(20, fn)` for 20 Hz. `seconds` is the step length: `Scheduler.fixed(1 / 20, fn)`.
- Don't forget the second return value of `debounce` / `throttle`. Do add `cancel` to the scope that owns them.
- Don't keep `Clock.now()` deltas across a `pause`. Do rely on `elapsed` / `dt` passed to the callback.

## Testing

`Hydrogen.test` installs the fake clock, so timers fire only on `t:advance` and exactly on schedule:

```luau
Hydrogen.test({ systems = { Projectiles } }, function(t)
	t:advance(1) -- fixed(1/20): exactly 20 steps
	assert(Scheduler.count() > 0)
end)
assert(Hydrogen.Scheduler.count() == 0) -- app:stop() destroyed the system scope and cancelled bound timers
```

- `t:advance(seconds)` runs each due timer at its own time. `t:advance(0)` runs what is due now.
- `t.clock:pending()` counts one entry for all scheduler timers together (the single armed delay).
- Callback errors and the "skipped a run" warning are captured: `t:expectWarning("callback failed")`.
- `Scheduler.count()` after the test checks that bound timers were cleaned up.
- The fake clock never runs late, so `fixed` catch-up can't be triggered with `t:advance`. Hydrogen's own tests swap `Clock.now` / `Clock.delay` / `Clock.cancel` for a clock that delivers wake-ups late. You only need that to test catch-up itself.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `[HYDROGEN] Scheduler: <kind>(<s>) callback failed: <error + traceback>` (warning) | A timer's callback errored; the timer keeps running. | Fix the callback; the traceback points at it. |
| `[HYDROGEN] Scheduler: <kind>(<s>) skipped a run because its last run yielded and is still running. Don't yield in repeating timers; task.spawn the slow part` (warning, once per timer) | An `every` / `fixed` callback yielded past its next due time. | Move yielding work into `task.spawn`, or use `after` chains. |
| `[HYDROGEN] Scheduler.<fn> expects seconds > 0, got <x>` (error) | `every` / `fixed` / `throttle` got 0, a negative number, NaN, infinity or a non-number. | Pass a positive, finite number of seconds. |
| `[HYDROGEN] Scheduler.<fn> expects seconds >= 0, got <x>` (error) | `after` / `debounce` got a negative number, NaN, infinity or a non-number. | Pass a finite number >= 0. |
| `[HYDROGEN] Scheduler.<fn> expects a function, got <type>` (error) | The callback is missing. | Pass the function. |
| `[HYDROGEN] Scheduler.every: jitter must be a number >= 0, got <x>` (error) | Bad `jitter` option. | Use a non-negative number. |
| `[HYDROGEN] Scheduler.fixed: maxSteps must be a whole number >= 1, got <x>` (error) | Bad `maxSteps` option. | Use 1 or more. |
| `[HYDROGEN] timer:bind expects a scope or a system, got nil` (error) | `bind(nil)`, often `self` outside a method. | Pass `self`, a system, or a scope. |
| `[HYDROGEN] Scope.of: ...` (error from `bind(system, player)`) | The system isn't running, or the player hasn't been added. | See scope.md; bind from `init` / `start` / `playerAdded` or later. |

## Works with

- **Clock** (clock.md): the scheduler's only time source. `Clock.fake` / `t:advance` drive it; `Clock.delay` and scheduler timers interleave in due order.
- **Scope** (scope.md): `timer:bind(self)` / `bind(self, player)` / `bind(scope)`, or `scope:add(timer)`. Use `scope:child()` for rounds and sub-lifetimes.
- **Signal** (signal.md): `Once` plus `Scheduler.after` makes a wait with a timeout. Timers can `Fire` signals to announce ticks or expiries.
- **State** (state.md): update replicated countdowns from `every`. State coalesces replication per frame, so frequent writes are cheap.
- **Data** (data.md): `debounce` coalesces saves; Data already autosaves, so use it for explicit "save soon" requests only.
- **Hydrogen.test** (testing.md): installs the fake clock and captures scheduler warnings; stopping the app cancels bound timers.
