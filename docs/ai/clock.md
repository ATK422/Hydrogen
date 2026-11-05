# Hydrogen.Clock

> The time source for Hydrogen, its kit modules and your systems: `now`, `time`, `serverNow`, `wait`, `delay`, `cancel` and `heartbeat`. In a game they are the Roblox built-ins. In tests `Clock.fake()` replaces them, so timeouts, cooldowns, autosaves and retries run instantly and deterministically.

## Use it when / Don't use it when

Use it when:
- Server and client compare timestamps (when an ability started, where a meter was at a moment): `Clock.serverNow()` is one clock on both sides, and the fake clock can skew it per client.
- A system measures durations or cooldowns (`Clock.now()`), schedules work later (`Clock.delay`), waits (`Clock.wait`), runs per frame (`Clock.heartbeat`) or stamps saved data (`Clock.time()`), and you want to test that code with `t:advance`.
- You write a kit module or library on Hydrogen: all its time must go through `Clock`, so the test harness can control it.

Don't use it when:
- Measuring real performance (profiling, benchmarks): use `os.clock()` directly, because fake time would lie.
- You need `task.spawn` or `task.defer`: those aren't time-based and `Clock` doesn't wrap them.
- You want repeating work (autosaves, ticks, regen): use `Hydrogen.Scheduler` (`every`, `fixed`), which runs on `Clock` and stops with a scope. Don't hand-roll `while true do Clock.wait(n) end` loops.
- You need calendar or time-zone handling: use `DateTime`, built from `Clock.time()` if it should be fakeable (`DateTime.fromUnixTimestamp(Clock.time())`).

## Quick start

```luau
-- ServerScriptService/Systems/Shield.luau (server)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Clock = Hydrogen.Clock

local COOLDOWN = 10
local DURATION = 3

return Hydrogen.define(function()
	local Shield = {}
	local lastUse: { [Player]: number } = {}
	-- Server time, so a client sent this value can draw the shield ending by itself.
	local endsAt: { [Player]: number } = {}

	function Shield.tryRaise(player: Player): boolean
		local now = Clock.now()
		local last = lastUse[player]
		if last and now - last < COOLDOWN then
			return false
		end
		lastUse[player] = now
		endsAt[player] = Clock.serverNow() + DURATION
		Clock.delay(DURATION, function()
			endsAt[player] = nil
		end)
		return true
	end

	function Shield.isUp(player: Player): boolean
		return endsAt[player] ~= nil
	end

	function Shield:playerRemoving(player: Player)
		lastUse[player] = nil
		endsAt[player] = nil
	end

	return Shield
end)
```

```luau
-- Tests/Shield.spec.luau (test)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Shield = require(ServerScriptService.Systems.Shield)

Hydrogen.test({ systems = { Shield }, players = 1 }, function(t, player)
	assert(Shield.tryRaise(player))
	assert(not Shield.tryRaise(player)) -- on cooldown
	t:advance(3) -- the Clock.delay runs, instantly
	assert(not Shield.isUp(player))
	t:advance(7)
	assert(Shield.tryRaise(player))
end)
```

For repeating work, use `Hydrogen.Scheduler.every(60, save):bind(self)` rather than a `Clock.wait` loop in `task.spawn`: it runs on `Clock`, so `t:advance` drives it the same way, and it stops when the system does.

## API

Same on server and client. In a game every field is the Roblox built-in itself (`Clock.now == os.clock`).

```luau
Clock.now(): number
-- Seconds on a monotonic clock (os.clock). For durations, cooldowns, rate limits.

Clock.time(): number
-- Unix seconds, an integer (os.time). For timestamps you save and dates.

Clock.serverNow(): number
-- Seconds on the server's clock, the same on the server and every client (workspace:GetServerTimeNow()).
-- For timestamps one side sets and the other compares. Under the Lune runtime (no Roblox server clock)
-- it reads os.clock, since one process plays both sides.

Clock.wait(seconds: number?): number
-- YIELDS. task.wait: resumes after seconds, or on the next frame without them (or with seconds <= 0).
-- Returns the seconds actually waited.

Clock.delay<A...>(seconds: number, fn: ((A...) -> ()) | thread, A...): thread
-- task.delay: runs fn(...) after seconds in a new thread. fn may be a suspended thread,
-- which is resumed with the arguments. Returns the thread (pass it to Clock.cancel).

Clock.cancel(thread: thread): ()
-- task.cancel: stops a delayed thread before it runs.

Clock.heartbeat(fn: (dt: number) -> ()): () -> ()
-- Calls fn(dt) at the end of every frame (RunService.Heartbeat). Returns a function that
-- disconnects it (a function, not an RBXScriptConnection).

Clock.fake(options: FakeClockOptions?): FakeClock
-- Tests only. Replaces the fields above until restore(). Errors if a fake is already installed.
-- Hydrogen.test installs one for you (t.clock).

Clock.active(): FakeClock?
-- The installed fake clock, or nil.

export type FakeClockOptions = {
	now: number?,        -- what Clock.now() starts at; default 0
	time: number?,       -- what Clock.time() starts at (Unix seconds); default the real os.time()
	serverNow: number?,  -- what Clock.serverNow() starts at; default the time value
}

export type FakeClock = {
	advance: (self: FakeClock, seconds: number) -> (),  -- move time; runs due timers, then one frame
	next: (self: FakeClock) -> number?,                  -- jump to the next timer and run it; seconds advanced, or nil if none
	pending: (self: FakeClock) -> number,                -- delays and timed waits still scheduled
	now: (self: FakeClock) -> number,                    -- same as Clock.now()
	serverNow: (self: FakeClock) -> number,              -- Clock.serverNow() as the server sees it (no client offset)
	setServerOffset: (self: FakeClock, seconds: number, player: Player?) -> (),
	-- shifts Clock.serverNow() for code running as that loopback client (t:as, its listeners) to simulate
	-- skew and latency; without a player, every client with no offset of its own; 0 clears
	restore: (self: FakeClock) -> (),                    -- put the built-ins back; idempotent
}
```

Types are exported as `Hydrogen.FakeClock` and `Hydrogen.FakeClockOptions`. Inside the Hydrogen package, core and kit modules require it as `require("../Clock")` from `src/<Module>/<File>.luau`, or `require("./Clock")` from `src/<Module>/init.luau`.

## Rules

- **Look fields up at call time.** Write `Clock.now()`, `Clock.wait(1)`. Never `local now = Clock.now`, `local wait = Hydrogen.Clock.wait`, or `{ clock = os.clock }` captured when the module loads: the fake replaces the fields on the `Clock` table, and a copy keeps real time.
- **Zero overhead in a game:** the fields are the built-ins, so `Clock.now()` costs one table lookup more than `os.clock()`. Nothing is created and nothing connects until you call something.
- **Only code that uses `Clock` is faked.** `task.wait`, `task.delay`, `os.clock`, `os.time`, `tick()`, `time()` and `RunService.Heartbeat:Connect` in your code keep real time under the fake clock.
- **Hydrogen itself uses it:** the `serverFunction:Fire` timeout (`Clock.delay`/`Clock.cancel`, 10 s by default), the `Hydrogen.rateLimit` refill (`Clock.now()`) and the batching flush (`Clock.heartbeat`).
- **Fake time moves only on `advance(seconds)` (or `t:advance`).** It never moves on its own, so a thread waiting on the fake clock in a test waits until the test advances.
- **`advance(seconds)` order:**
  1. Every timer due by `now + seconds` runs, in due-time order, with ties in scheduling order. Timers scheduled while it runs also count if they fall inside the window, so `while true do Clock.wait(60) end` runs 5 times in `advance(300)`.
  2. While a timer runs, `Clock.now()` returns that timer's due time.
  3. `now` becomes the target time.
  4. Heartbeat listeners fire **once** with `dt = seconds`.
  5. Threads in `Clock.wait()` with no argument (next frame) resume once.
- **`advance(0)`** runs what is due now and steps exactly one frame. To simulate frames, loop: `for _ = 1, 60 do t:advance(1 / 60) end`.
- **`advance` doesn't yield;** resumed threads run until their next yield before it returns. It rejects negative or NaN seconds. More than 100000 timers in one advance errors, which catches a timer that reschedules itself with no delay.
- **Fake `Clock.time()`** is `floor(time + elapsed)`, an integer like `os.time()`.
- **Fake `Clock.serverNow()`** is `serverNow + elapsed`, plus the offset of the loopback client the code runs as. An offset applies only inside that client's code: `t:as(player, fn)` and the listeners of events sent to it. Client code outside `t:as` (allowed with one fake client) has no known client, so it reads the server's time.
- **`serverNow` vs `now`:** `Clock.now()` is per machine and starts anywhere, so never send it to the other side. `Clock.serverNow()` is shared, so it is what you replicate (`endsAt = Clock.serverNow() + 3`). On a real client it is an estimate that can be a few milliseconds off and may step; measure short durations on one side with `now`.
- **Errors in timers and heartbeat listeners** are reported like errors in `task.spawn` threads and don't stop `advance`.
- **`restore()`** puts the built-ins back and abandons every thread still waiting on the fake clock; they are never resumed. `Hydrogen.test` restores for you.
- **One fake at a time,** VM-wide (like the loopback).
- **Under the Lune runtime there are no frames:** the real `Clock.heartbeat` never fires and real `Clock.wait()` uses Lune's scheduler. Use the fake clock in tests.

## Recipes

### Cooldown

```luau
local COOLDOWN = 5
local lastUse: { [Player]: number } = {}

local function tryUse(player: Player): boolean
	local now = Hydrogen.Clock.now()
	local last = lastUse[player]
	if last and now - last < COOLDOWN then
		return false
	end
	lastUse[player] = now
	return true
end
-- Clear lastUse[player] in the system's playerRemoving.
```

### Debounce: run once after activity stops

```luau
local Clock = Hydrogen.Clock
local pending: thread? = nil

local function touch()
	if pending then
		Clock.cancel(pending)
	end
	pending = Clock.delay(0.5, function()
		pending = nil
		flush()
	end)
end
-- Test: touch(); t:advance(0.3); touch(); t:advance(0.3) -> not flushed; t:advance(0.2) -> flushed once.
```

### Retry with backoff

```luau
local function saveWithRetry(save: () -> boolean): boolean
	local delay = 1
	for _ = 1, 5 do
		if save() then
			return true
		end
		Hydrogen.Clock.wait(delay) -- yields
		delay *= 2
	end
	return false
end
-- Test: run it in task.spawn, then t:advance(1), t:advance(2), ... and check the attempts.
```

### Per-frame work, stopped on shutdown

```luau
local Ticker = Hydrogen.define("Ticker", function()
	local Ticker = { elapsed = 0 }
	local disconnect: (() -> ())? = nil

	function Ticker:start()
		disconnect = Hydrogen.Clock.heartbeat(function(dt)
			Ticker.elapsed += dt
		end)
	end

	function Ticker:stop()
		if disconnect then
			disconnect()
		end
	end

	return Ticker
end)
-- Test: for _ = 1, 60 do t:advance(1 / 60) end -> Ticker.elapsed is about 1.
```

### A timestamp both sides agree on

```luau
-- server: send when the cast ends, once
CastEnds:FireAll(player, Hydrogen.Clock.serverNow() + castTime)
-- client: draw the bar every frame from the shared clock, with no more traffic
local remaining = math.max(0, endsAt - Hydrogen.Clock.serverNow())
-- Test with skew: t.clock:setServerOffset(0.15, player), then read it inside t:as(player, fn)
```

### Saved timestamps

```luau
data.lastLogin = Hydrogen.Clock.time()
local isNewDay = Hydrogen.Clock.time() // 86400 > data.lastLogin // 86400
-- Test: Hydrogen.test({ clock = { time = 1700000000 } }, function(t) ... t:advance(86400) ... end)
```

### A fake clock without the harness

```luau
local fake = Hydrogen.Clock.fake({ now = 0 })
local ok, err = pcall(function()
	local fired = false
	Hydrogen.Clock.delay(10, function()
		fired = true
	end)
	assert(fake:next() == 10 and fired)
end)
fake:restore() -- always restore, even on failure
assert(ok, err)
```

## Mistakes

- Don't `local now = Hydrogen.Clock.now` at the top of a module. Do call `Hydrogen.Clock.now()` where you need it.
- Don't use `task.wait(60)` / `task.delay` / `os.clock()` in game logic you want to test. Do use `Clock.wait`, `Clock.delay` and `Clock.now()`.
- Don't send `Clock.now()` or `os.clock()` to the other side, or call `workspace:GetServerTimeNow()` directly. Do use `Clock.serverNow()`, which both sides share and the fake clock controls.
- Don't use `Clock.now()` for saved timestamps (it's per-server and starts near 0 in tests). Do use `Clock.time()`.
- Don't treat `Clock.heartbeat`'s return value as a connection (`:Disconnect()`). Do call it: `disconnect()`.
- Don't `Clock.wait` on the test's own thread for a fake delay. It never resumes, because nothing advances. Do call `t:advance(seconds)`.
- Don't expect `advance(1)` to call heartbeat 60 times. It calls it once with `dt = 1`; loop `advance(1/60)` if you need frames.
- Don't install `Clock.fake()` inside `Hydrogen.test`. Do use `t.clock` / `t:advance`.
- Don't forget `restore()` with a hand-made fake. Do `pcall` the test and restore after, or use `Hydrogen.test`.
- Don't start a cooldown table with `last = 0` defaults: under the fake clock `now` starts at 0, so the first use looks like it's on cooldown. Do treat a missing entry as "never used" (`if last and now - last < COOLDOWN`).

## Testing

`Hydrogen.test` installs a fake clock by default. `t:advance(seconds)` moves it, and `t.clock` is the `FakeClock` (`t.clock:next()`, `t.clock:pending()`). Pass `clock = false` for real time, or `clock = { now = ..., time = ... }` for start values. Teardown steps the fake clock while `app:stop()` waits, so `playerRemoving` / `stop` hooks that `Clock.wait` still finish. Outside the harness, use `Hydrogen.Clock.fake()` and `restore()`. See testing.md for the full harness.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `A fake clock is already installed; restore it before installing another` | Second `Clock.fake()` | `restore()` the first, or inside `Hydrogen.test` use `t.clock` |
| `setServerOffset expects a finite number of seconds` | NaN, `math.huge` or a non-number | Pass a finite number; 0 clears it |
| `advance expects a non-negative number of seconds` | `advance(-1)`, `advance(nil)` or NaN | Pass seconds >= 0 |
| `advance ran 100000 timers without reaching the target time; is a timer rescheduling itself with no delay?` | Something calls `Clock.delay(0, ...)` / `Clock.wait(0)`-style rescheduling in a loop inside one advance | Give the loop a real interval, or wait for the next frame with `Clock.wait()` |
| `t:advance needs the fake clock, but this test was opened with clock = false` | Harness opened with real time | Remove `clock = false` |
| `Network function <name> timed out after <s>s waiting for <player>` | Hydrogen's server function timeout fired (real or fake time) | Expected in timeout tests; raise it with `:SetTimeout(seconds)` |

## Works with

- **Hydrogen.test** (testing.md): installs and restores the fake clock; `t:advance` is `t.clock:advance`.
- **Network:** `serverFunction:SetTimeout` timeouts, `Hydrogen.rateLimit` refills and `App.new({ batching = true })` flushes all run on `Clock`.
- **Kit modules (Data autosave and retries, Scope's `scope:delay`, State's per-frame replication, Receipts' retries):** read time through `Clock`, so `t:advance` drives them. Per-frame work (State's coalesced replication) goes out on the next `t:advance` (`t:advance(0)` is one frame).
