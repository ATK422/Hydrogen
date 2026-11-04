# Hydrogen.test

> One call per test of Hydrogen systems. It opens a loopback network (one VM plays the server and fake clients) and installs a fake clock. It boots an app with your systems and fakes, joins fake players, runs your test function, and always tears everything down. Expectations check what network objects delivered.

## Use it when / Don't use it when

Use it when:
- Testing systems (`Hydrogen.define`), alone or as server and client systems talking over the network.
- Replacing a dependency (e.g. a DataStore-backed `Data` system) with a fake.
- Checking what was fired to or by which player, what a function returned, or which warnings were printed.
- Testing timeouts, cooldowns, autosaves or retries without waiting: use `t:advance(seconds)`.

Don't use it when:
- Testing a pure function or module with no systems or network: call it directly.
- Testing the real remotes, `Players.PlayerAdded` or `BindToClose`: those only exist in a running Roblox server (use a Studio play test).
- Inside a running game (play mode with your real app already started): the loopback needs the network not to be running.

## Quick start

```luau
-- ReplicatedStorage/Network/Shop.luau (shared)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Buy = Hydrogen.clientEvent("Buy", gt.string()),
	Bought = Hydrogen.serverEvent("Bought", gt.string(), gt.number()),
}
```

```luau
-- ServerScriptService/Systems/Shop.luau (server)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Remotes = require(ReplicatedStorage.Network.Shop)
local DataSystem = require(script.Parent.Data) -- has Data.getCoins(player): number

return Hydrogen.define(function(use)
	local Data = use(DataSystem)
	local Shop = {}

	function Shop:init()
		Remotes.Buy:On(function(player, item)
			Remotes.Bought:Fire(player, item, Data.getCoins(player))
		end)
	end

	return Shop
end)
```

```luau
-- Tests/Shop.spec.luau (test; works in any framework, or none)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Remotes = require(ReplicatedStorage.Network.Shop)
local Shop = require(ServerScriptService.Systems.Shop)
local DataSystem = require(ServerScriptService.Systems.Data)

Hydrogen.test({
	systems = { Shop },
	replace = { [DataSystem] = { getCoins = function(_player: Player): number
		return 500
	end } },
	players = { "Alice", "Bob" },
}, function(t, alice, bob)
	t:as(alice, function()
		Remotes.Buy:Fire("sword") -- client code, sent as Alice
	end)

	t:expect(Remotes.Buy):firedBy(alice, "sword")
	t:expect(Remotes.Bought):firedTo(alice, "sword", 500):firedTimes(1)
	t:expect(Remotes.Bought):notFired(bob)
end)
```

In TestEZ or Jest-Lua, put the `Hydrogen.test(...)` call inside `it("...", function() ... end)`. In frktest, put it inside `test.case(...)`. A failed expectation is an ordinary error, so the framework reports it as a failure.

## API

Everything here runs in tests only. One VM acts as server and every client, so none of it is server-only or client-only.

```luau
Hydrogen.test: ((body: (t: Harness, ...Player) -> ()) -> ())
	& ((options: TestOptions, body: (t: Harness, ...Player) -> ()) -> ())
-- Sets up, runs body(t, ...joinedPlayers), always closes. Re-raises body's error after teardown. Yields if body yields.

Hydrogen.harness(options: TestOptions?): Harness
-- Same setup without a body; you must call t:close() (e.g. in afterEach).

export type TestOptions = {
	systems: { any }?,                         -- added to the app
	replace: { [any]: any }?,                  -- { [OriginalSystem] = fake }, applied with app:replace
	players: ({ string } | number)?,           -- fake clients joined before start; names or a count ("Player1", ...)
	start: boolean?,                           -- default true: app started before body runs
	app: Hydrogen.AppOptions?,                 -- passed to App.new, e.g. { debug = true }
	clock: (boolean | Hydrogen.FakeClockOptions)?, -- default: fake clock; false = real time; table = fake start values
	logLevel: Hydrogen.LogThreshold?,          -- Hydrogen.Log global level during the test, e.g. "debug"
}
```

Harness `t`:

```luau
t.app: Hydrogen.App                 -- the app under test
t.net: Hydrogen.Loopback            -- the loopback (t.net:client() tells fake clients apart)
t.clock: Hydrogen.FakeClock?        -- nil when clock = false
t.any: any                          -- matcher: equals any one value in an expected argument list

t:add(...: any): ()                 -- add systems; after start they init+start immediately
t:replace(original: any, fake: { [any]: any }): ()   -- only before start (start = false)
t:start(): ()                       -- only with start = false; errors if already started
t:join(name: string?): Player       -- new fake client; playerAdded runs; handshake delivers queued events
t:leave(player: Player): ()         -- characterRemoving, then playerRemoving (after that player's playerAdded finished); destroys a fake character
t:spawnCharacter(player: Player, character: Model?): Model  -- like LoadCharacter: old character removed, player.Character set, characterAdded runs
t:removeCharacter(player: Player): ()  -- characterRemoving runs; player.Character = nil
t:streamCharacter(player: Player, streamedIn: boolean): ()  -- character leaves the DataModel (false) or returns (true), as with client streaming
t:as(player: Player, fn: (...any) -> ...any, ...any): ...any  -- run client code as that player
t:player(name: string): Player      -- look up a joined player; errors if none
t:players(): { Player }             -- players still in
t:advance(seconds: number): ()      -- move the fake clock (see Rules); errors with clock = false
t:expect(object: any): Expectation  -- object = a clientEvent/serverEvent/clientFunction/serverFunction
t:expectNothingFired(): ()          -- no event or call delivered since start / last clear
t:expectWarning(text: string): ()   -- some captured warning contains text (plain substring); marks all matches expected
t:expectNoWarnings(): ()            -- no captured warning that isn't marked expected
t:warnings(): { string }            -- every captured warning
t:expectLog(level: Hydrogen.LogLevel, text: string): ()  -- a Hydrogen.Log line at exactly level contains text (plain); marks warn/error matches expected
t:logs(level: Hydrogen.LogLevel?): { Hydrogen.LogLine }   -- every Hydrogen.Log line emitted during the test, oldest first
t:deliveries(object: any?): { Hydrogen.Delivery }  -- recorded deliveries, oldest first
t:clear(): ()                       -- forget recorded deliveries (not warnings)
t:close(): ()                       -- teardown; idempotent; may yield (waits for app:stop)
```

Expectation (methods return the same Expectation, so they chain):

```luau
:fired(...any): Expectation               -- events: delivered at least once, to/from anyone
:firedTo(player: Player, ...any): Expectation   -- serverEvent reached that client
:firedBy(player: Player, ...any): Expectation   -- server received that clientEvent from that client
:notFired(player: Player?): Expectation   -- never delivered (to/from player if given)
:firedTimes(count: number): Expectation   -- exactly count deliveries (FireAll to 3 clients = 3)
:called(...any): Expectation              -- functions: handler ran with these args
:calledBy(player: Player, ...any): Expectation  -- clientFunction called by player / serverFunction answered by player
:returned(...any): Expectation            -- some call returned exactly these values
:notCalled(): Expectation
:calledTimes(count: number): Expectation
:deliveries(): { Hydrogen.Delivery }      -- the raw records

export type Delivery = {
	name: string,                 -- network name (with namespace prefix)
	kind: "ClientEvent" | "ServerEvent" | "ClientFunction" | "ServerFunction",
	player: Player?,              -- receiving client (serverEvent), sender (clientEvent), caller/answerer (functions)
	args: { [number]: any, n: number },
	returns: { [number]: any, n: number }?,  -- functions; nil if the handler errored or is still running
}
```

Lune runtime (`src/Testing/Lune.luau`, required with Lune's own `require`, not exported from `Hydrogen`):

```luau
Lune.install(options: { server: boolean?, client: boolean? }?): ()  -- set Roblox globals; idempotent
Lune.require(path: string): any     -- load a module with Roblox require rules, relative to the calling file
Lune.modules: { [any]: any }        -- ModuleScript Instance -> what require(instance) returns (= _G.instanceModules)
```

## Rules

- **Teardown always runs.** `Hydrogen.test` closes the harness even when the body or the boot errors, then re-raises the body's error. Closing stops the app (playerRemoving for remaining players, then stop hooks), closes the loopback (removes listeners and middleware added since it opened, stops the network) and restores the real clock. Then it prints warnings no expectation matched.
- **Setup order:** fake clock, loopback, app, `systems` added, `replace` applied, `players` joined, then `app:start()`. The players are in the game when the app starts, so `playerAdded` runs for them during start and queued events reach them through the handshake.
- **Only one harness or loopback at a time.** Opening a harness while one is open closes the old one with a warning. Opening a loopback starts from an empty network, so events queued by earlier tests are dropped.
- **Register network objects before the app starts.** Create them at module top level (as shared modules do) or before `Hydrogen.test`. Objects created after the network starts are ignored with a warning.
- **Expectations look at deliveries:** what the receiving listeners or handler got, after middleware and schema validation. Messages dropped by middleware, `Hydrogen.rateLimit`, validation, or sent to a player who left are not recorded.
- **Delivery is synchronous under loopback.** When `Fire` returns, listeners have already run up to their first yield, so expect right after firing. Each event handler runs in its own thread; an error in one prints `[HYDROGEN] Loopback event handler failed` instead of reaching the sender.
- **Argument matching:** with no expected args, any args match. With args, the count must match exactly, tables compare deeply by value, players compare by identity, and `t.any` matches one value. Recorded args are deep copies made before listeners run.
- **Which client?** With exactly one fake client, client code needs no `t:as`. With two or more, every client send must be inside `t:as(player, fn)`, or it errors. All fake clients share the same client-side listeners; inside one, `t.net:client()` is the receiving client. While the server handles a client's message, `t.net:client()` is `nil`.
- **Fake players are tables**, not Instances, with `Name`, `DisplayName`, `UserId` (negative), `Parent` and `Kick()`, which makes them leave. Instance methods such as `player:IsA()` don't exist on them.
- **Fake clock, which is on by default:** time moves only on `t:advance(seconds)`. Each timer due by then runs in due order, and `Clock.now()` reads that timer's due time while it runs. Then heartbeat fires once with `dt = seconds`, and threads in `Clock.wait()` (no argument) resume. Only code that uses `Hydrogen.Clock` sees fake time; direct `task.wait` / `task.delay` / `os.clock` keep real time. Hydrogen's server-function timeout (10 s default) and `Hydrogen.rateLimit` refill use the clock. See clock.md.
- **`t:advance` doesn't yield.** Code waiting on real time (e.g. App's internal polling loops) does not advance with it.
- **Player leaving mid-hook:** `playerRemoving` for a player runs only after all of that player's `playerAdded` hooks returned, each system exactly once.
- **Teardown steps the fake clock** while `app:stop()` waits, so `playerRemoving` / `stop` hooks that `Clock.wait` (saves with retry delays) finish. It gives up after 5 real seconds with a warning. Other threads still waiting on the fake clock are never resumed after the test.
- **Systems are module singletons.** State a system keeps in upvalues or its own table survives between tests in the same VM. Reset it in `init`, or key it by player and clear it in `playerRemoving`.
- **Replacements:** the fake runs in the original's place in the boot order, and while the app runs the original table forwards every field to the fake. Don't copy fields out of a dependency at construction time (`local getCoins = use(Data).getCoins`), because the copy keeps pointing at the original.
- **Warnings:** while a harness is open, warnings sent through Hydrogen's log are captured, not printed. That includes `Hydrogen.Log` warn and error lines (error lines count as warnings). Under the Lune runtime every `warn()` call is captured. In Studio, only Hydrogen's and `Hydrogen.Log`'s are.
- **Log lines:** every `Hydrogen.Log` line is recorded for `t:expectLog` / `t:logs`. Debug lines are off by default under Lune (it runs as a live server): pass `logLevel = "debug"`. Log levels, sinks and the rate limit set during a test are put back when it closes. See log.md.

## Recipes

### Test a system with a faked dependency
See Quick start: `replace = { [DataSystem] = fake }`, where the fake only needs the fields the system under test uses. To set up by hand, pass `start = false`, then call `t:add(Shop)`, `t:replace(DataSystem, fake)`, `t:join("Alice")` and `t:start()`.

### Client-server round trip with two players

```luau
local SendMessage = Hydrogen.clientEvent("Chat/Send", gt.string())
local MessagePosted = Hydrogen.serverEvent("Chat/Posted", gt.string(), gt.string())

local ChatServer = Hydrogen.define("ChatServer", function()
	return {
		init = function()
			SendMessage:On(function(player, text)
				MessagePosted:FireAll(player.Name, text)
			end)
		end,
	}
end)

Hydrogen.test({ systems = { ChatServer }, players = { "Alice", "Bob" } }, function(t, alice, bob)
	local inbox: { [Player]: { string } } = {}
	MessagePosted:On(function(author, text) -- client-side listener, shared by all fake clients
		local client = t.net:client() :: Player
		inbox[client] = inbox[client] or {}
		table.insert(inbox[client], `{author}: {text}`)
	end)

	t:as(bob, function()
		SendMessage:Fire("hi")
	end)

	t:expect(SendMessage):firedBy(bob, "hi")
	t:expect(MessagePosted):firedTo(alice, "Bob", "hi"):firedTo(bob, "Bob", "hi"):firedTimes(2)
	assert(inbox[alice][1] == "Bob: hi")
end)
```

### Cooldown with `advance`

```luau
local Clock = Hydrogen.Clock
local Claim = Hydrogen.clientEvent("Daily/Claim")
local Granted = Hydrogen.serverEvent("Daily/Granted", gt.number())

local Daily = Hydrogen.define("Daily", function()
	local COOLDOWN = 60
	local lastClaim: { [Player]: number } = {}
	return {
		init = function()
			Claim:On(function(player)
				local now = Clock.now() -- not os.clock(): the fake clock must reach it
				local last = lastClaim[player]
				if last and now - last < COOLDOWN then
					return
				end
				lastClaim[player] = now
				Granted:Fire(player, 100)
			end)
		end,
		playerRemoving = function(_, player: Player)
			lastClaim[player] = nil
		end,
	}
end)

Hydrogen.test({ systems = { Daily }, players = 1 }, function(t, player)
	Claim:Fire()
	Claim:Fire()
	t:expect(Granted):firedTimes(1)
	t:advance(59)
	Claim:Fire()
	t:expect(Granted):firedTimes(1)
	t:advance(1)
	Claim:Fire()
	t:expect(Granted):firedTo(player, 100):firedTimes(2)
end)
```

### Server function timeout

```luau
local Confirm = Hydrogen.serverFunction("Trade/Confirm", gt.string())(gt.boolean())

local SlowClient = Hydrogen.define("SlowClient", function()
	return {
		init = function()
			Confirm:On(function(_offer)
				Hydrogen.Clock.wait(30) -- the client takes too long
				return true
			end)
		end,
	}
end)

Hydrogen.test({ systems = { SlowClient }, players = { "Alice" } }, function(t, alice)
	local ok: boolean? = nil
	local err: any = nil
	task.spawn(function() -- Fire yields until the answer or the timeout
		ok, err = pcall(Confirm.Fire, Confirm, alice, "2 swords")
	end)
	t:advance(9)
	assert(ok == nil)
	t:advance(1)
	assert(ok == false and string.find(tostring(err), "timed out after 10s", 1, true))
	t:expect(Confirm):calledBy(alice, "2 swords")
end)
```

### Player leaving mid-operation

```luau
local log: { string } = {}
local Profiles = Hydrogen.define("Profiles", function()
	return {
		playerAdded = function(_, player: Player)
			Hydrogen.Clock.wait(2) -- stands in for a DataStore load
			table.insert(log, `loaded {player.Name}`)
		end,
		playerRemoving = function(_, player: Player)
			Hydrogen.Clock.wait(1) -- stands in for a DataStore save
			table.insert(log, `saved {player.Name}`)
		end,
	}
end)

Hydrogen.test({ systems = { Profiles }, players = { "Alice" } }, function(t, alice)
	t:leave(alice) -- before her load finished
	t:advance(2)   -- load finishes; playerRemoving only starts after it
	assert(log[1] == "loaded Alice")
end)
-- Teardown stepped the fake clock until the save finished.
assert(table.concat(log, ", ") == "loaded Alice, saved Alice")
```

### Expect a warning (invalid payload from a client)

```luau
local SetName = Hydrogen.clientEvent("SetName", gt.string())

Hydrogen.test({ players = 1 }, function(t)
	SetName:Use(function(context, value) -- what an exploiter could send
		if context.direction == "outgoing" then
			return 42 :: any
		end
		return value
	end)
	SetName:Fire("ok")
	t:expect(SetName):notFired()
	t:expectWarning("Dropped invalid SetName")
	t:expectNoWarnings()
end)
```

### Frameworks with beforeEach/afterEach

```luau
local t: Hydrogen.Harness
beforeEach(function()
	t = Hydrogen.harness({ systems = { Shop }, players = { "Alice" } })
end)
afterEach(function()
	t:close()
end)
it("buys", function()
	local alice = t:player("Alice")
	t:as(alice, function()
		Remotes.Buy:Fire("sword")
	end)
	t:expect(Remotes.Bought):firedTo(alice, "sword", t.any)
end)
```

### Run game tests under Lune

Under Lune, game code must use string requires (`require("../Network/Shop")`), or every ModuleScript it requires by Instance must be registered in `Lune.modules`. `ReplicatedStorage.roblox_packages.hydrogen` does not exist there. Require Hydrogen by path instead, e.g. `require("../roblox_packages/hydrogen")`.

```luau
-- test/run.luau; run with: lune run test/run
local process = require("@lune/process")
local Lune = require("../roblox_packages/.pesde/atk422+hydrogen/<version>/hydrogen/src/Testing/Lune")
Lune.install() -- before any game code is loaded

local function require(path: string): any
	return Lune.require(path) -- Roblox rules: ./ relative to this file, @self, .luaurc aliases, script.Parent
end

local ok, err = pcall(function()
	require("./Shop.spec")
end)
if not ok then
	print(err)
end
process.exit(if ok then 0 else 1) -- exit explicitly; leftover timers can keep Lune alive
```

Under Lune, `RunService:IsServer()` and `IsClient()` return false, Heartbeat never fires (use the fake clock), and modules are named like Roblox full names (`src.Systems.Shop`), so `Hydrogen.define` infers ids as in Studio.

## Mistakes

- Don't call `app:stop()` and `net:close()` by hand around `Hydrogen.loopback()`. Do use `Hydrogen.test`, which can't forget to.
- Don't fire client code outside `t:as` when two or more players joined. Do `t:as(player, function() Remote:Fire(...) end)`.
- Don't use `firedTo` on a clientEvent or `firedBy` on a serverEvent. Do: serverEvent → `firedTo(player, ...)`, clientEvent → `firedBy(player, ...)`, functions → `called` / `calledBy` / `returned`.
- Don't use `task.wait(60)` or `os.clock()` in systems you want to test with `advance`. Do use `Hydrogen.Clock.wait(60)` and `Hydrogen.Clock.now()`.
- Don't store `local now = Hydrogen.Clock.now`. Do call `Hydrogen.Clock.now()` each time.
- Don't call `t:replace` after the app started. Do pass `replace = { [Original] = fake }`, or use `start = false`.
- Don't call a `serverFunction:Fire` that will time out directly in the test thread and then try to `advance`: the thread is blocked. Do `task.spawn` it, then `t:advance`.
- Don't create network objects inside a system's `init` or after start. Do create them at module top level, or before `Hydrogen.test`.
- Don't expect `firedTo(player)` to count a send to a player who left. Sends to departed players are dropped.
- Don't pass `nil` (e.g. a misspelt `t:player` result) as the player. The expectation errors with `expects a player from the test`.
- Don't rely on system state being fresh between tests. Do reset it in `init`, or key it by player and clear it in `playerRemoving`.
- Don't call Instance methods on fake players (`player:IsA`, `player.Character`). Do keep player logic to `Name`, `UserId` and `Kick`, or fake that part.

## Testing

This file is the testing module itself. The tools under it, `app:replace(original, fake)` and `Hydrogen.loopback()`, can be used directly; see the core testing doc. With them you must call `app:stop()` and `net:close()` yourself. Hydrogen's own suite (`test/Testing.luau`, `test/Clock.luau` in the repository) has more runnable examples.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `Expected <name> to be fired to <player> with (...), but it was fired N times:` + list | Expectation failed; the list shows what was delivered | Fix the code or the expected args (count and values must match exactly; use `t.any`) |
| `Expected <name> to be fired ..., but it was never fired` | Nothing was delivered | Check the message wasn't dropped (look at `t:warnings()`), the right player was used, the network object was registered before start |
| `Expected <name> not to be fired..., but ...` / `to be called N times` / `to return (...)` | Other expectation failures | As above |
| `Expected nothing to be fired, but N messages were delivered:` | `t:expectNothingFired()` failed | Call `t:clear()` after setup traffic |
| `<method> is for serverEvents; <name> is a clientEvent, use firedBy` (and similar) | Wrong expectation for the object's kind | Use the method named in the message |
| `<method> expects a player from the test (...), got nil` | `firedTo` / `firedBy` / `calledBy` / `notFired` got a non-player | Pass a player from `t:join`, `t:player` or the test function's arguments |
| `Expected a warning containing "<text>", but no warnings were emitted` / `the warnings were:` | `t:expectWarning` found no match | Match a substring of an actual warning (plain text, not a pattern) |
| `Expected no warnings, but got:` | Unexpected warnings | Fix the cause, or `t:expectWarning(text)` it first |
| `Expected a <level> line containing "<text>", but ...` | `t:expectLog` found no line at that level containing text; for debug it says the current level | Match a substring of `line.text`; pass `logLevel = "debug"` for debug lines |
| `t:expect expects a network object made with clientEvent, serverEvent, clientFunction or serverFunction` | Passed something else | Pass the network object itself |
| `t:replace must come before the app starts: pass replace = { [Original] = fake } in the options, or start = false` | Replace after start | As the message says |
| `The app already started; Hydrogen.test starts it unless the options say start = false` | `t:start()` called twice or without `start = false` | Remove the call or pass `start = false` |
| `t:advance needs the fake clock, but this test was opened with clock = false` | `advance` with real time | Drop `clock = false` |
| `No player named <name> is in the test` | `t:player` lookup failed | Join the player first; names are case-sensitive |
| `Hydrogen.test expects a test function: Hydrogen.test(options?, function(t) ... end)` | No body function | Pass one, or use `Hydrogen.harness` |
| `Hydrogen.test options must be a table` | Bad options | Pass a table |
| warning `A test harness was never closed; closing it before opening the next one` | A `Hydrogen.harness` wasn't closed | Call `t:close()` in afterEach |
| warning `app:stop() was still waiting 5s after the test ended; a playerRemoving or stop hook is yielding forever` | A hook never returns (often real `task.wait` or a wait on something that never happens) | Make the hook finish; use `Hydrogen.Clock` for delays |
| warning `Closing the test harness also failed: <error>` | Both body and teardown errored; the body error is raised | Fix the teardown error (often a `stop` hook) |
| `<N> loopback clients have joined; wrap client code in loopback:as(player, fn) to say which one is sending` | Client send with several clients outside `t:as` | Wrap it in `t:as(player, fn)` |
| `A client sent a message over loopback before any client joined; call loopback:join() first` | Client code ran with no players | Pass `players = ...` or `t:join()` first |
| `Can't invoke <name>: the player has left` | `serverFunction:Fire` to a departed fake player | Don't call functions on players who left |
| `A loopback is already open; close it before opening another` | You opened `Hydrogen.loopback()` yourself inside a harness test | Use `t.net` instead |
| `Open the loopback before app:start(); the network is already running` | A real app is running (Studio play mode) | Run tests in a VM where your game's app isn't started |
| `A fake clock is already installed; restore it before installing another` | `Hydrogen.Clock.fake()` inside a harness test | Use `t.clock` / `t:advance` |
| warning `Loopback event handler failed: <error>` | A listener errored during delivery | Fix the listener; the sender isn't affected |
| warning `Dropped invalid <name> from <player>: <cause>` | A payload failed the schema | Expected for exploit tests (`t:expectWarning`); otherwise fix the sender |
| `Network function <name> called before the network started; call functions from start or later` | Function fired in `init` or before start | Fire from `start` or later |
| `Network function <name> timed out after <s>s waiting for <player>` | The fake client didn't answer in time | Expected in timeout tests; otherwise `t:advance` less, or make the client answer |
| `Can't find module <path> (looked for <file>) required from <file>` | Lune runtime: bad require path | Fix the path; relative to the requiring file (in an `init.luau`, `./` is the folder's sibling) |
| `Lune can't run ModuleScript <name>; register what it returns in Lune.modules[moduleScript]` | Lune runtime: `require(instance)` of an unregistered ModuleScript | Use string requires, or set `Lune.modules[moduleScript] = value` |
| `Unknown require alias @<alias> in <file>; add it to a .luaurc` | Lune runtime: alias missing | Add it to the nearest `.luaurc` `aliases` |
| `Cyclic require of <file>` | Lune runtime: two modules require each other | Break the cycle |

## Works with

- **Hydrogen.Log** (log.md): every log line is recorded (`t:expectLog`, `t:logs`); warn and error lines are captured as warnings; `logLevel` sets the level for the test.
- **Hydrogen.Clock** (clock.md): the harness installs `Hydrogen.Clock.fake()`, available as `t.clock`. Any code using `Hydrogen.Clock` advances with `t:advance`.
- **Network** (clientEvent, serverEvent, clientFunction, serverFunction, middleware, `Hydrogen.rateLimit`): all run unchanged over the loopback. `App.new({ batching = true })` is accepted but batching is skipped under loopback.
- **Character hooks** (character.md): fake players have no character until `t:spawnCharacter(player)`. The harness destroys the models it built when it closes.
- **Kit modules (Data, PlayerState, State, Scope, Receipts)** are systems or use systems: pass them in `systems` and fake their stores with `replace`. Their timers use `Hydrogen.Clock`, so `t:advance` drives autosaves, retries, cooldowns and State's end-of-frame send. The harness calls `Hydrogen.State.reset()` and `Hydrogen.Config.reset()` when it closes (Config: overrides, live values, flag results and the environment). Config's live-source refresh also runs on `Hydrogen.Clock`.
