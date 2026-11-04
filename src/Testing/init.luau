--!strict

-- Hydrogen.test: one call sets up a loopback network, a fake clock and an app, applies fakes,
-- joins players and starts it, runs the test, and always tears everything down again.
-- Expectations error when they fail, so this works with any test framework, or none.

local App = require("./App")
local Clock = require("./Clock")
local Log = require("./Log")
local Network = require("./Network")
local Runtime = require("./Network/Runtime")
local Expect = require("@self/Expect")

export type Expectation = Expect.Expectation
export type Delivery = Expect.Delivery
type App = typeof(App.new())

export type TestOptions = {
	-- Systems added to the app.
	systems: { any }?,
	-- Fakes, as { [OriginalSystem] = fake }. Applied with app:replace.
	replace: { [any]: any }?,
	-- Fake clients joined before the app starts: their names, or how many. The test function
	-- receives them after the harness: function(t, alice, bob).
	players: ({ string } | number)?,
	-- Start the app before the test function runs. Defaults to true; with false, call t:start().
	start: boolean?,
	-- Options for App.new, e.g. { debug = true }.
	app: App.AppOptions?,
	-- A fake clock is installed by default, so time only moves on t:advance. false keeps
	-- real time; a table sets the fake clock's starting values.
	clock: (boolean | Clock.FakeClockOptions)?,
}

export type Harness = {
	app: App,
	net: Network.Loopback,
	-- nil when the harness was opened with clock = false.
	clock: Clock.FakeClock?,
	-- In an expected argument list, matches any one value: firedTo(alice, "sword", t.any).
	any: any,

	-- Setup. Systems added after the app started are booted right away.
	add: (self: Harness, ...any) -> (),
	replace: (self: Harness, original: any, fake: { [any]: any }) -> (),
	start: (self: Harness) -> (),

	-- Players, as on the loopback.
	join: (self: Harness, name: string?) -> Player,
	leave: (self: Harness, player: Player) -> (),
	as: (self: Harness, player: Player, fn: (...any) -> ...any, ...any) -> ...any,
	player: (self: Harness, name: string) -> Player,
	players: (self: Harness) -> { Player },

	-- Moves the fake clock forward, running every timer due by then.
	advance: (self: Harness, seconds: number) -> (),

	-- Expectations on a network object's deliveries since the start (or the last t:clear()).
	expect: (self: Harness, object: any) -> Expectation,
	expectNothingFired: (self: Harness) -> (),
	-- A warning containing text (plain text, not a pattern) was emitted. Marks every match
	-- as expected.
	expectWarning: (self: Harness, text: string) -> (),
	-- No warnings were emitted, apart from ones an expectWarning matched.
	expectNoWarnings: (self: Harness) -> (),
	warnings: (self: Harness) -> { string },
	-- Every delivery, oldest first, optionally only one object's.
	deliveries: (self: Harness, object: any?) -> { Delivery },
	-- Forgets the deliveries recorded so far, e.g. after setup.
	clear: (self: Harness) -> (),

	-- Stops the app, closes the loopback and puts the real clock back. Warnings no
	-- expectWarning matched are printed now. Safe to call more than once.
	close: (self: Harness) -> (),
}

type Warning = { text: string, expected: boolean }

-- How long close waits for app:stop() before giving up on a hook that never returns.
local STOP_TIMEOUT = 5

local Testing = {}

local open: Harness? = nil
-- The players each harness joined from its options, handed to the test function.
local initialPlayers: { [Harness]: { Player } } = setmetatable({}, { __mode = "k" }) :: any

local function objectName(object: any): string?
	if type(object) ~= "table" then
		return nil
	end
	return Runtime.Objects[object]
end

-- Runs app:stop() and, since its playerRemoving and stop hooks may wait on the fake clock,
-- steps the clock until they finish.
local function stopApp(app: App, clock: Clock.FakeClock?)
	local finished = false
	local failure: any = nil
	task.spawn(function()
		local ok, err = pcall(app.stop, app)
		if not ok then
			failure = err
		end
		finished = true
	end)

	local began = os.clock()
	while not finished do
		if clock then
			if clock:pending() > 0 then
				clock:next()
			else
				clock:advance(0)
			end
		end
		if finished then
			break
		end
		if os.clock() - began > STOP_TIMEOUT then
			Log.warn(`[HYDROGEN] app:stop() was still waiting {STOP_TIMEOUT}s after the test ended; a playerRemoving or stop hook is yielding forever`)
			break
		end
		task.wait()
	end

	if failure ~= nil then
		error(failure, 0)
	end
end

-- Opens a harness for frameworks with setup and teardown hooks. Call t:close() when the test
-- ends (e.g. in afterEach); Hydrogen.test does both for you.
function Testing.harness(options: TestOptions?): Harness
	if open then
		Log.warn(`[HYDROGEN] A test harness was never closed; closing it before opening the next one`)
		open:close()
	end

	local settings: TestOptions = options or {}
	if type(settings) ~= "table" then
		error(`[HYDROGEN] Hydrogen.test options must be a table`, 2)
	end

	local harness = {} :: Harness
	local deliveries: { Delivery } = {}
	-- Function calls still running, so their return values land on the right delivery.
	local running: { [Runtime.Observation]: Delivery } = setmetatable({}, { __mode = "k" }) :: any
	local warnings: { Warning } = {}
	local joined: { Player } = {}
	local started = false
	-- The app's start returned, so its stop hooks have something to stop.
	local booted = false
	local closed = false
	local uncapture: (() -> ())? = nil

	local function isPlayer(value: any): boolean
		return harness.net ~= nil and harness.net:owns(value)
	end

	local function record(observation: Runtime.Observation)
		local call = running[observation]
		if call then
			running[observation] = nil
			call.returns = if observation.returns then Expect.copyArgs(observation.returns, isPlayer) else nil
			return
		end

		local delivery: Delivery = {
			name = observation.name,
			kind = observation.kind,
			player = observation.player,
			args = Expect.copyArgs(observation.args, isPlayer),
			returns = nil,
		}
		if observation.kind == "ClientFunction" or observation.kind == "ServerFunction" then
			running[observation] = delivery
		end
		table.insert(deliveries, delivery)
	end

	local function deliveriesOf(name: string?): { Delivery }
		if name == nil then
			return deliveries
		end
		local list = {}
		for _, delivery in deliveries do
			if delivery.name == name then
				table.insert(list, delivery)
			end
		end
		return list
	end

	harness.any = Expect.ANY

	function harness:add(...: any)
		for _, system in { ... } do
			self.app:addSystem(system)
		end
	end

	function harness:replace(original: any, fake: { [any]: any })
		if started then
			error(`[HYDROGEN] t:replace must come before the app starts: pass replace = \{ [Original] = fake } in the options, or start = false`, 2)
		end
		self.app:replace(original, fake)
	end

	function harness:start()
		if started then
			error(`[HYDROGEN] The app already started; Hydrogen.test starts it unless the options say start = false`, 2)
		end
		started = true
		self.app:start()
		booted = true
	end

	function harness:join(name: string?): Player
		return self.net:join(name)
	end

	function harness:leave(player: Player)
		self.net:leave(player)
	end

	function harness:as(player: Player, fn: (...any) -> ...any, ...: any): ...any
		return self.net:as(player, fn, ...)
	end

	function harness:player(name: string): Player
		for _, player in self.net:players() do
			if player.Name == name then
				return player
			end
		end
		error(`[HYDROGEN] No player named {name} is in the test`, 2)
	end

	function harness:players(): { Player }
		return self.net:players()
	end

	function harness:advance(seconds: number)
		local clock = self.clock
		if not clock then
			error(`[HYDROGEN] t:advance needs the fake clock, but this test was opened with clock = false`, 2)
		end
		clock:advance(seconds)
	end

	function harness:expect(object: any): Expectation
		local name = objectName(object)
		if not name then
			error(`[HYDROGEN] t:expect expects a network object made with clientEvent, serverEvent, clientFunction or serverFunction`, 2)
		end
		return Expect.new({
			name = name,
			kind = object._kind,
			deliveries = function()
				return deliveriesOf(name)
			end,
			isPlayer = isPlayer,
		})
	end

	function harness:expectNothingFired()
		if #deliveries > 0 then
			error(`[HYDROGEN] Expected nothing to be fired, but {#deliveries} {if #deliveries == 1 then "message was" else "messages were"} delivered:\n{Expect.describeAll(deliveries, isPlayer)}`, 2)
		end
	end

	function harness:expectWarning(text: string)
		local found = false
		for _, warning in warnings do
			if string.find(warning.text, text, 1, true) then
				warning.expected = true
				found = true
			end
		end
		if not found then
			local lines = {}
			for _, warning in warnings do
				table.insert(lines, `  {warning.text}`)
			end
			local seen = if #lines == 0 then "no warnings were emitted" else `the warnings were:\n{table.concat(lines, "\n")}`
			error(`[HYDROGEN] Expected a warning containing "{text}", but {seen}`, 2)
		end
	end

	function harness:expectNoWarnings()
		local lines = {}
		for _, warning in warnings do
			if not warning.expected then
				table.insert(lines, `  {warning.text}`)
			end
		end
		if #lines > 0 then
			error(`[HYDROGEN] Expected no warnings, but got:\n{table.concat(lines, "\n")}`, 2)
		end
	end

	function harness:warnings(): { string }
		local list = {}
		for _, warning in warnings do
			table.insert(list, warning.text)
		end
		return list
	end

	function harness:deliveries(object: any?): { Delivery }
		if object == nil then
			return table.clone(deliveries)
		end
		local name = objectName(object)
		if not name then
			error(`[HYDROGEN] t:deliveries expects a network object, or nothing for every delivery`, 2)
		end
		return table.clone(deliveriesOf(name))
	end

	function harness:clear()
		table.clear(deliveries)
	end

	-- Each step runs even if an earlier one failed; the first error is raised at the end.
	function harness:close()
		if closed then
			return
		end
		closed = true
		if open == harness then
			open = nil
		end

		local firstError: any = nil
		local function step(fn: () -> ())
			local ok, err = pcall(fn)
			if not ok and firstError == nil then
				firstError = err
			end
		end

		if booted then
			step(function()
				stopApp(self.app, self.clock)
			end)
		end
		if self.net then
			step(function()
				self.net:close()
			end)
		end
		if Runtime.Observer == record then
			Runtime.Observer = nil
		end
		if uncapture then
			uncapture()
		end
		if self.clock then
			step(function()
				(self.clock :: Clock.FakeClock):restore()
			end)
		end

		-- Unexpected warnings still reach the output, after the test, so nothing is hidden.
		for _, warning in warnings do
			if not warning.expected then
				Log.warn(warning.text)
			end
		end

		if firstError ~= nil then
			error(firstError, 0)
		end
	end

	-- Anything that fails during setup closes what was opened before it.
	local ok, err = pcall(function()
		local clockOption = settings.clock
		if clockOption ~= false then
			harness.clock = Clock.fake(if type(clockOption) == "table" then clockOption else nil)
		end

		harness.net = Network.loopback()
		Runtime.Observer = record
		uncapture = Log.capture(function(message: string): boolean?
			table.insert(warnings, { text = message, expected = false })
			return true
		end)

		harness.app = App.new(settings.app)
		for _, system in settings.systems or {} :: { any } do
			harness.app:addSystem(system)
		end
		for original, fake in settings.replace or {} :: { [any]: any } do
			harness.app:replace(original, fake)
		end

		local players = settings.players
		if type(players) == "number" then
			for _ = 1, players do
				table.insert(joined, harness.net:join())
			end
		elseif type(players) == "table" then
			for _, name in players do
				table.insert(joined, harness.net:join(name))
			end
		end

		if settings.start ~= false then
			harness:start()
		end
	end)

	if not ok then
		pcall(harness.close, harness)
		error(err, 0)
	end

	open = harness
	initialPlayers[harness] = joined
	return harness
end

type Body = (t: Harness, ...Player) -> ()

-- Runs body with a fresh harness and always closes it, even when body errors.
local function test(optionsOrBody: TestOptions | Body, maybeBody: Body?)
	local options: TestOptions? = nil
	local body: Body
	if type(optionsOrBody) == "function" then
		body = optionsOrBody
	else
		options = optionsOrBody
		body = maybeBody :: Body
	end
	if type(body) ~= "function" then
		error(`[HYDROGEN] Hydrogen.test expects a test function: Hydrogen.test(options?, function(t) ... end)`, 2)
	end

	local harness = Testing.harness(options)
	local ok, err = pcall(body, harness, table.unpack(initialPlayers[harness]))
	local closedOk, closeErr = pcall(harness.close, harness)

	if not ok then
		if not closedOk then
			Log.warn(`[HYDROGEN] Closing the test harness also failed: {closeErr}`)
		end
		error(err, 0)
	elseif not closedOk then
		error(closeErr, 0)
	end
end

Testing.test = test :: ((body: Body) -> ()) & ((options: TestOptions, body: Body) -> ())

return Testing
