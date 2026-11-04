# Hydrogen.Log

> Tagged, levelled, structured logging for game code: `Hydrogen.Log.of(system or name)` gives a logger with `debug`, `info`, `warn` and `error`, whose lines carry the system's name and `key=value` fields, go to pluggable sinks (console, a ring buffer for overlays, your own function), and are captured by `Hydrogen.test`.

## Use it when / Don't use it when

Use it when:
- A system reports what it did or what went wrong: purchases, round changes, failed saves, suspicious client input.
- You want debug output in Studio that stays silent in live servers, without deleting `print` calls.
- You want recent lines in an in-game debug overlay (`Log.buffer`), or sent to an analytics or HTTP endpoint your game controls (`Log.addSink`).
- A test should check that something was logged (`t:expectLog`) or that nothing went wrong (`t:expectNoWarnings`).

Don't use it when:
- You need to stop execution: `log:error` only logs. Use Luau `error()` to throw.
- You log network traffic: use the `Hydrogen.logger()` middleware, which already writes through `Hydrogen.Log`.
- You measure performance: use the microprofiler (`debug.profilebegin`), not timestamps in log lines.

## Quick start

```luau
-- ServerScriptService/Systems/Shop.luau (server)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function()
	local Shop = {}
	-- Fine inside the constructor: the name ("Shop", the system's id) is looked up on the first line.
	local log = Hydrogen.Log.of(Shop)

	function Shop.buy(player: Player, item: string, price: number)
		log:info("bought", { player = player.Name, item = item, price = price })
		-- Console: [Shop] bought item=sword player=Alice price=50
	end

	function Shop:playerAdded(player: Player)
		Hydrogen.Log.of(Shop, player):debug("opened shop") -- [Shop] debug: opened shop player=Alice
	end

	return Shop
end)
```

```luau
-- ServerScriptService/Main.server.luau (server): optional configuration, before app:start()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

Hydrogen.Log.setLevel("warn", "Pathfinding")        -- one noisy system: warnings and errors only
Hydrogen.Log.rateLimit({ burst = 5, window = 10 })  -- collapse lines repeated every frame
```

## API

Same on server and client; each side has its own levels, sinks and buffers. Nothing here yields.

```luau
Hydrogen.Log.of(target: string | System, player: Player?): Logger
-- The logger for a system (named after its id) or a name. Same target -> same logger.
-- With a player, every line also has player=<Name>; cached per player (weak).

logger:debug(message: Message, fields: Fields?): ()
logger:info(message: Message, fields: Fields?): ()
logger:warn(message: Message, fields: Fields?): ()
logger:error(message: Message, fields: Fields?): ()   -- logs at error level; does NOT throw
logger:enabled(level: LogLevel): boolean              -- would a line at level be emitted? one comparison
logger:with(fields: Fields): Logger                   -- same name and level, adds fields to every line
logger:setLevel(level: LogThreshold?): ()             -- override for this logger's name; nil clears
logger:name(): string                                 -- "Shop"

Hydrogen.Log.setLevel(level: LogThreshold?, target: (string | System)?): ()
-- No target: the global level (nil = default: "debug" in Studio, "info" elsewhere).
-- With a target: that name's override (nil clears it).
Hydrogen.Log.level(target: (string | System)?): LogThreshold   -- the effective level

Hydrogen.Log.addSink(sink: (line: LogLine) -> ()): () -> ()   -- returns remove
Hydrogen.Log.removeSink(sink: LogSink): ()
Hydrogen.Log.console: LogSink   -- the default sink: print for debug/info, warn for warn/error
Hydrogen.Log.buffer(capacity: number?): LogBuffer   -- ring buffer sink, default 200 lines, registered now
Hydrogen.Log.rateLimit(options: LogRateLimitOptions | false | nil): ()   -- off by default
Hydrogen.Log.format(fields: Fields?): string   -- " item=sword price=50", as lines print them

buffer:lines(minLevel: LogLevel?): { LogLine }   -- oldest first; only minLevel and above if given
buffer:total(): number                           -- lines written since creation (detect changes cheaply)
buffer:clear(): ()
buffer:stop(): ()                                -- unregister; held lines stay readable
buffer.capacity: number
buffer.sink: LogSink

export type LogLevel = "debug" | "info" | "warn" | "error"
export type LogThreshold = LogLevel | "off"
export type LogFields = { [any]: any }
export type LogMessage = string | () -> (string, LogFields?)   -- a function is only called if emitted
export type LogRateLimitOptions = { burst: number?, window: number? }   -- defaults 5 lines, 10 s
export type LogLine = {
	level: LogLevel,
	tag: string?,        -- "Shop"; "HYDROGEN" for Hydrogen's own lines; nil for a bare warn() under Lune
	message: string,
	fields: LogFields?,  -- merged with with()/player fields; not copied, don't mutate
	text: string,        -- exactly what the console prints
	at: number,          -- Hydrogen.Clock.now() when emitted
	repeated: number?,   -- set on a rate-limit summary line: how many were dropped
}
-- Types from the package: Hydrogen.Logger, Hydrogen.LogLevel, Hydrogen.LogThreshold, Hydrogen.LogFields,
-- Hydrogen.LogMessage, Hydrogen.LogLine, Hydrogen.LogSink, Hydrogen.LogBuffer, Hydrogen.LogRateLimitOptions.
```

Test harness additions (see testing.md):

```luau
TestOptions.logLevel: LogThreshold?                 -- global level during the test
t:expectLog(level: LogLevel, text: string): ()      -- a line at exactly level contains text (plain substring)
t:logs(level: LogLevel?): { LogLine }               -- every line emitted during the test
```

## Rules

- **Line format:** `[Tag] message key=value key=value`. Keys are sorted. Plain words are unquoted (`item=sword`); strings with spaces, quotes or `=` are quoted (`reason="no coins"`); tables print as `{a = 1}`; Instances as `ClassName(Name)`; strings over 200 chars are truncated. Debug lines say `debug:` and error lines `error:` after the tag; info and warn lines don't.
- **Levels, lowest to highest:** debug, info, warn, error; `"off"` emits nothing. A line is emitted when its level is at or above the threshold for its logger's name: the name's override if set, else the global level.
- **Default level:** `"debug"` in Studio, `"info"` in live servers and under Lune. Set it explicitly (`Log.setLevel("info")`) if you want Studio to match live.
- **Overrides are by name.** `Log.of(Shop)`, `Log.of("Shop")`, `Log.of(Shop, player)` and `log:with(...)` children all share the override for `"Shop"`. Hydrogen's own warnings use the name `"HYDROGEN"`.
- **Cost when filtered:** one field read and one comparison. Arguments are still evaluated by Luau before the call, so:
  - `log:debug("constant")` costs nothing more.
  - `log:debug(`x {expensive()}`)` runs `expensive()` and builds the string even when filtered.
  - `log:debug(function() return `x {expensive()}`, { pos = pos } end)` defers all of it; the function runs only if the line is emitted (a closure capturing locals is still allocated).
  - `if log:enabled("debug") then ... end` skips everything, including the closure. Use it in per-frame code.
- **Message functions** run in `pcall`; an error is reported as `[HYDROGEN] A log message function failed in <name>: <err>` and the line is dropped.
- **Sinks can't break logging.** Each sink runs protected: an error is reported once (`A log sink failed`) and the sink keeps receiving lines; once it succeeds, a later failure is reported again. Your sinks run in their own thread, so a sink that yields (an HTTP request) doesn't hold up the caller. Lines logged from inside a sink go to the console only (no recursion).
- **Lines are frozen tables shared by every sink.** `line.fields` is the table you passed (or a merged copy); don't mutate it.
- **The console is a sink.** `Log.removeSink(Log.console)` silences output; your other sinks still get every line. `Log.addSink(Log.console)` brings it back.
- **Rate limiting** (opt-in, global): identical lines (same level and text, fields included) beyond `burst` within `window` seconds are dropped. When the window ends, one summary line is emitted: `<text> (repeated N more times in 10s)`, with `line.repeated = N`. Lines that differ in any field are different lines. Turning it off (`Log.rateLimit(false)`) emits pending summaries.
- **Time** comes from `Hydrogen.Clock`, so the fake clock drives `line.at` and rate-limit windows in tests.
- **Loggers are cached per name forever.** Don't build names from changing data (`Log.of("Round" .. n)`); use `log:with({ round = n })`.
- **Hydrogen's own `[HYDROGEN]` warnings** go through the same pipeline (level `warn`, tag `HYDROGEN`, text unchanged), so sinks, buffers, levels and rate limiting apply to them too.
- **`Hydrogen.logger()`** writes traffic lines at `info` with tag `HYDROGEN` through `Hydrogen.Log` unless you pass `output`.

## Recipes

### Per-player context

```luau
function Trade:playerAdded(player: Player)
	local log = Hydrogen.Log.of(Trade, player)   -- player=<Name> on every line
	log:info("joined trading")
end
```

### Debug lines in a per-frame loop

```luau
local log = Hydrogen.Log.of(Movement)
Hydrogen.Clock.heartbeat(function(dt)
	if log:enabled("debug") then
		log:debug("tick", { dt = dt, speed = humanoid.WalkSpeed })
	end
end)
```

### Recent lines for a debug overlay (client)

```luau
local recent = Hydrogen.Log.buffer(100)
local seen = 0
Hydrogen.Clock.heartbeat(function()
	if recent:total() == seen then
		return -- nothing new: no work this frame
	end
	seen = recent:total()
	for _, line in recent:lines("info") do
		-- render line.text, colour by line.level
	end
end)
```

### Send warnings to your own endpoint (server)

```luau
local HttpService = game:GetService("HttpService")
local queue: { Hydrogen.LogLine } = {}

Hydrogen.Log.addSink(function(line)
	if line.level == "warn" or line.level == "error" then
		table.insert(queue, line) -- no yielding here; batch instead
	end
end)

task.spawn(function()
	while true do
		Hydrogen.Clock.wait(30)
		if #queue > 0 then
			local batch = queue
			queue = {}
			pcall(HttpService.PostAsync, HttpService, "https://example.com/logs", HttpService:JSONEncode(batch))
		end
	end
end)
```

### Quieter live servers

```luau
local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	Hydrogen.Log.setLevel("warn")
	Hydrogen.Log.setLevel("info", "Economy") -- but keep purchases
end
Hydrogen.Log.rateLimit({ burst = 5, window = 10 })
```

## Mistakes

- Don't `print`/`warn` from systems; do `Hydrogen.Log.of(System):info(...)`, so lines are named, levelled and testable.
- Don't interpolate expensive values into debug messages in hot code; do pass a function or guard with `log:enabled("debug")`.
- Don't use `log:error` to stop execution; do call `error()` (and log first if you want the line).
- Don't yield in a sink (`PostAsync` inline); do queue lines and send them from your own thread.
- Don't call `Log.setLevel(level, System)` inside the system's constructor (no id yet, it errors); do call it from `init` or boot code, or pass the name string.
- Don't make a logger per round or per object with a dynamic name; do `log:with({ round = n })`.
- Don't mutate `line.fields` in a sink; do copy if you need to change it.
- Don't call `Hydrogen.Log.of` with a player for anything but a `Player`; do use `with` for other context.

## Testing

`Hydrogen.test` records every line and captures warn and error lines (they aren't printed unless unexpected), and puts levels, sinks and the rate limit back when it closes.

```luau
Hydrogen.test({ systems = { Shop }, logLevel = "debug", players = { "Alice" } }, function(t, alice)
	Shop.buy(alice, "sword", 50)
	t:expectLog("info", "bought item=sword")      -- plain substring of line.text, exact level
	t:expectLog("debug", "opened shop")           -- needs logLevel = "debug" (default is "info" under Lune)
	local line = t:logs("info")[1]
	assert(line.fields and line.fields.price == 50)
	t:expectNoWarnings()
end)
```

- `log:warn` and `log:error` lines count as warnings: `t:expectWarning(text)`, `t:expectNoWarnings()`, `t:warnings()` see them. `t:expectLog("warn" | "error", text)` also marks matches as expected.
- Unexpected warnings are printed when the test ends. Debug and info lines print to the console as usual.
- To test a sink or buffer, create it inside the test; the harness removes sinks added during the test.
- Rate-limit windows run on the fake clock: `t:advance(window)` emits the summary.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `Log.of expects a system (from Hydrogen.define) or a name, got <type>` | Wrong argument | Pass the system table or a non-empty string |
| `Log.of(target, player) expects a Player, got <type>` | Second argument isn't a player | Pass a `Player`, or use `log:with(fields)` |
| `<fn> expects a level: "debug", "info", "warn", "error" or "off", got <x>` | Unknown level string | Use one of those names |
| `log:enabled expects "debug", "info", "warn" or "error", got <x>` | `"off"` or a typo | Pass a line level |
| `Log.setLevel was given a system whose define hasn't returned yet; ...` / `log:setLevel was called before this system's define returned ...` | Called in the constructor, before the id exists | Call it from `init`, boot code, or pass the name |
| `log:with expects a table of fields` | Non-table argument | `log:with({ key = value })` |
| `Log.addSink expects a function that receives each line` | Non-function sink | Pass `function(line) ... end` |
| `Log.buffer expects a whole number of lines, at least 1` | Bad capacity | `Log.buffer(200)` |
| `Log.rateLimit burst must be at least 1` / `window must be a positive number of seconds` | Bad options | `{ burst = 5, window = 10 }` |
| warning `A log message function failed in <name>: <err>` | A lazy message function errored; that line was dropped | Fix the function |
| warning `A log sink failed; it keeps receiving lines, but its errors aren't reported again until it succeeds: <err>` | A sink errored | Fix the sink; wrap risky work in `pcall` |
| `<text> (repeated N more times in Ws)` | Rate-limit summary | Expected with `Log.rateLimit`; fix the spam source |
| `Expected a <level> line containing "<text>", but ...` (test) | `t:expectLog` found no match; for debug it names the current level | Match a substring of `line.text`; pass `logLevel = "debug"` for debug lines |

All are prefixed `[HYDROGEN]` except the summary line, which keeps the original line's prefix.

## Works with

- `Hydrogen.test` (testing.md): `t:expectLog`, `t:logs`, `logLevel`, warning capture.
- `Hydrogen.logger()` (middleware.md): traffic lines go through `Hydrogen.Log`.
- `Hydrogen.Clock` (clock.md): `line.at` and rate-limit windows.
- `Hydrogen.define` (systems.md): a system's id names its logger.
- `Hydrogen.Scope` (scope.md): tie `buffer:stop` or a sink's remove function to a lifetime, e.g. `Scope.of(Overlay):add(Hydrogen.Log.addSink(fn))`.
