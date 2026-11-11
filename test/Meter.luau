--!strict

-- Hydrogen.State.meter / playerMeter through Hydrogen.test: segments replicate only on changes,
-- get() extrapolates on each side from Clock.serverNow(), and the owner can predict.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Store = require("../src/State/Store")

local gt = Hydrogen.gt
local State = Hydrogen.State
local Clock = Hydrogen.Clock
local Guards = Hydrogen.Guards

-- Defined when the suite starts, before any network runs.
local defs: {
	Stamina: Hydrogen.PlayerMeter,
	Heat: Hydrogen.StateMeter,
	Posture: Hydrogen.PlayerMeter,
	Hunger: Hydrogen.PlayerMeter,
	Sprint: Hydrogen.ClientEvent<boolean>,
	RecipeStamina: Hydrogen.PlayerMeter,
	RecipeSprint: Hydrogen.ClientEvent<boolean>,
	Mana: Hydrogen.PlayerMeter,
	Charge: Hydrogen.StateMeter,
	Fulgur: Hydrogen.PlayerMeter,
	CastFulgur: Hydrogen.ClientEvent<number>,
} = nil :: any

local function define()
	if defs then
		return
	end
	defs = {
		Stamina = State.playerMeter("MeterStamina", { max = 100, predict = true, predictTimeout = 1 }),
		-- Packed into a buffer, to check the segment survives encoding.
		Heat = State.meter("MeterHeat", { min = -50, max = 50, value = 0, encode = true }),
		Posture = State.playerMeter("MeterPosture", { max = 10, value = 0, visibleTo = "everyone" }),
		Hunger = State.playerMeter("MeterHunger", { max = 100, rate = -1 }),
		Sprint = Hydrogen.clientEvent("MeterSprint", gt.boolean()),
		-- As in the stamina recipe in docs/ai/state.md.
		RecipeStamina = State.playerMeter("MeterRecipeStamina", { max = 100, rate = 10, predict = true }),
		RecipeSprint = Hydrogen.clientEvent("MeterRecipeSprint", gt.boolean()),
		-- With a past for getAt.
		Mana = State.playerMeter("MeterMana", { max = 100, value = 0, history = 1.5 }),
		Charge = State.meter("MeterCharge", { max = 10, value = 0, history = 2 }),
		-- As in the "judge an action at the moment the player acted" recipe in docs/ai/state.md.
		Fulgur = State.playerMeter("MeterFulgurMana", { max = 100, value = 0, history = 1.5 }),
		CastFulgur = Hydrogen.clientEvent("MeterCastFulgur", gt.number()),
	}
end

-- The past segments a meter's server cell keeps for getAt.
local function history(state: any, player: Player?): { any }?
	local cell = if player then state.players[Store.SERVER][player] else state.global[Store.SERVER]
	local aux = cell and cell.aux
	return aux and aux.history
end

local function fails(fn: (...any) -> ...any, text: string)
	local ok, err = pcall(fn)
	check.equal(ok, false)
	if not string.find(tostring(err), text, 1, true) then
		error(`expected an error with "{text}", got {err}`, 2)
	end
	check.not_nil((string.find(tostring(err), "[HYDROGEN]", 1, true)))
end

local function near(actual: number, expected: number)
	if math.abs(actual - expected) > 1e-6 then
		error(`expected {expected}, got {actual}`, 2)
	end
end

-- Counts the messages a state sends.
local function sent(state: any): { count: number }
	local record = { count = 0 }
	state.event:Use(function(context: Hydrogen.MiddlewareContext, ...: any)
		if context.direction == "outgoing" then
			record.count += 1
		end
		return ...
	end)
	return record
end

local function clock(t: Hydrogen.Harness): Hydrogen.FakeClock
	return t.clock :: Hydrogen.FakeClock
end

return function()
	test.on_suite_enter(function(suite)
		if suite.name == "Meter" then
			define()
		end
	end)

	test.suite("Meter", function()
		test.case("time passing extrapolates on both sides and sends nothing", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 1000 } }, function(t, alice)
				local Stamina = defs.Stamina
				local record = sent(Stamina)

				Stamina:set(alice, 50)
				Stamina:setRate(alice, -10)
				t:advance(0)
				-- Two writes in one frame: one segment.
				check.equal(record.count, 1)
				near(Stamina:get(alice), 50)
				near(t:as(alice, Stamina.get, Stamina, alice), 50)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), -10)

				t:advance(2)
				near(Stamina:get(alice), 30)
				near(t:as(alice, Stamina.get, Stamina, alice), 30)

				-- Clamped at min, however long it runs.
				t:advance(60)
				check.equal(Stamina:get(alice), 0)
				check.equal(t:as(alice, Stamina.get, Stamina, alice), 0)
				check.equal(record.count, 1)

				-- The rate carries on from the clamped value, not from where it would have been.
				Stamina:setRate(alice, 5)
				t:advance(2)
				near(Stamina:get(alice), 10)
				near(t:as(alice, Stamina.get, Stamina, alice), 10)
				check.equal(record.count, 2)
			end)
			return nil
		end)

		test.case("writes clamp, and no-op writes send nothing", function()
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local Stamina = defs.Stamina
				local record = sent(Stamina)

				Stamina:set(alice, 150)
				check.equal(Stamina:get(alice), 100)
				-- Already full: nothing changed, nothing to send.
				t:advance(0)
				check.equal(record.count, 0)

				Stamina:add(alice, -30)
				check.equal(Stamina:get(alice), 70)
				Stamina:add(alice, -500)
				check.equal(Stamina:get(alice), 0)
				Stamina:setRate(alice, 0)
				t:advance(0)
				check.equal(record.count, 1)
				check.equal(t:as(alice, Stamina.get, Stamina, alice), 0)

				Stamina:set(alice, 80)
				Stamina:setRange(alice, 0, 50)
				check.equal(Stamina:get(alice), 50)
				local min, max = Stamina:getRange(alice)
				check.equal(min, 0)
				check.equal(max, 50)
				t:advance(0)
				local clientMin, clientMax = t:as(alice, Stamina.getRange, Stamina, alice)
				check.equal(clientMin, 0)
				check.equal(clientMax, 50)
				check.equal(t:as(alice, Stamina.get, Stamina, alice), 50)
			end)
			return nil
		end)

		test.case("a global meter reaches everyone, and late joiners get the current segment", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 500 } }, function(t, alice)
				local Heat = defs.Heat
				local record = sent(Heat)

				Heat:setRate(4)
				t:advance(0)
				t:advance(5)
				near(Heat:get(), 20)
				near(t:as(alice, Heat.get, Heat), 20)

				-- Bob gets the segment written at 500, not a value: he extrapolates it himself.
				local bob = t:join("Bob")
				near(t:as(bob, Heat.get, Heat), 20)
				t:advance(2.5)
				near(t:as(bob, Heat.get, Heat), 30)
				-- One change for Alice, one snapshot for Bob.
				check.equal(record.count, 2)
			end)
			return nil
		end)

		test.case("a client with a skewed clock never runs a segment backwards", function()
			Hydrogen.test({ players = { "Alice", "Bob" }, clock = { serverNow = 1000 } }, function(t, alice, bob)
				local Posture = defs.Posture
				clock(t):setServerOffset(-0.5, alice)
				clock(t):setServerOffset(0.5, bob)

				Posture:set(alice, 8)
				Posture:setRate(alice, -2)
				t:advance(0)

				-- Alice's clock is half a second behind the segment's time: it holds at 8 until she
				-- reaches it, then drains. Bob's is ahead, so he sees it half a second on.
				near(t:as(alice, Posture.get, Posture, alice), 8)
				near(t:as(bob, Posture.get, Posture, alice), 7)
				near(Posture:get(alice), 8)

				t:advance(1)
				near(Posture:get(alice), 6)
				near(t:as(alice, Posture.get, Posture, alice), 7)
				near(t:as(bob, Posture.get, Posture, alice), 5)
			end)
			return nil
		end)

		test.case("owner-only meters reach only their owner; visibleTo everyone reaches all", function()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				local Stamina, Posture = defs.Stamina, defs.Posture
				Stamina:set(alice, 40)
				Posture:set(alice, 3)
				t:advance(0)

				check.equal(t:as(alice, Stamina.get, Stamina, alice), 40)
				-- Bob never receives Alice's stamina: he sees the initial value.
				check.equal(t:as(bob, Stamina.get, Stamina, alice), 100)
				check.equal(t:as(bob, Posture.get, Posture, alice), 3)
			end)
			return nil
		end)

		test.case("observers fire on changes, not as time passes", function()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				local Posture = defs.Posture
				local server: { { number } } = {}
				local onBob: { { any } } = {}

				Posture:observe(alice, function(value, rate)
					table.insert(server, { value, rate })
				end)
				t:as(bob, function()
					Posture:observeAll(function(player, value, rate)
						table.insert(onBob, { player :: any, value, rate })
					end)
				end)
				check.equal(#server, 1)
				check.equal(server[1][1], 0)

				Posture:setRate(alice, 1)
				check.equal(#server, 2)
				check.equal(server[2][2], 1)
				t:advance(0)
				check.equal(#onBob, 1)
				check.equal(onBob[1][1], alice)
				check.equal(onBob[1][3], 1)

				t:advance(3)
				check.equal(#server, 2)
				check.equal(#onBob, 1)

				Posture:add(alice, 2)
				t:advance(0)
				check.equal(#server, 3)
				near(server[3][1], 5)
				check.equal(#onBob, 2)
				near(onBob[2][2], 5)
			end)
			return nil
		end)

		test.case("a prediction shows at once and the server's update replaces it", function()
			local Server = Hydrogen.define("MeterSprintServer", function()
				return {
					start = function()
						defs.Sprint:On(function(player: Player, sprinting: boolean)
							if sprinting then
								defs.Stamina:setRate(player, -20)
							else
								defs.Stamina:setRate(player, 0)
							end
						end)
					end,
				}
			end)

			Hydrogen.test({ systems = { Server }, players = { "Alice" }, clock = { serverNow = 100 } }, function(t, alice)
				local Stamina = defs.Stamina
				local record = sent(Stamina)
				local seen: { { number } } = {}
				t:as(alice, function()
					Stamina:observe(alice, function(value, rate)
						table.insert(seen, { value, rate })
					end)
				end)

				-- The client's latency: its server clock reads a little ahead.
				clock(t):setServerOffset(0.05, alice)
				t:as(alice, function()
					Stamina:predictRate(alice, -20)
					defs.Sprint:Fire(true)
				end)
				-- Shown on the client straight away; the server hasn't sent anything yet.
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), -20)
				check.equal(#seen, 2)
				check.equal(seen[2][2], -20)
				check.equal(record.count, 0)

				t:advance(0)
				-- Confirmed: the server's segment replaced the prediction.
				check.equal(record.count, 1)
				check.equal(Stamina:getRate(alice), -20)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), -20)
				near(t:as(alice, Stamina.get, Stamina, alice), 99)

				-- The confirmation keeps it past the prediction's timeout.
				t:advance(2)
				near(Stamina:get(alice), 60)
				near(t:as(alice, Stamina.get, Stamina, alice), 59)

				-- Correction: the client predicts, the server decides otherwise.
				t:as(alice, function()
					Stamina:predictAdd(alice, -30)
				end)
				near(t:as(alice, Stamina.get, Stamina, alice), 29)
				Stamina:setRate(alice, 0)
				t:advance(0)
				near(t:as(alice, Stamina.get, Stamina, alice), 60)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), 0)
			end)
			return nil
		end)

		test.case("a prediction the server never answers is dropped after its timeout", function()
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local Stamina = defs.Stamina
				local seen: { number } = {}
				t:as(alice, function()
					Stamina:observe(alice, function(_value, rate)
						table.insert(seen, rate)
					end)
					Stamina:predictRate(alice, -10)
				end)
				t:advance(0.5)
				near(t:as(alice, Stamina.get, Stamina, alice), 95)

				t:advance(0.6)
				-- Back to the server's view.
				check.equal(t:as(alice, Stamina.get, Stamina, alice), 100)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), 0)
				check.equal(seen[#seen], 0)
				check.equal(#seen, 3)

				-- sync corrects at once instead of waiting for the timeout.
				t:as(alice, function()
					Stamina:predictRate(alice, -10)
				end)
				t:advance(0.5)
				Stamina:sync(alice)
				t:advance(0)
				check.equal(t:as(alice, Stamina.get, Stamina, alice), 100)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), 0)
			end)
			return nil
		end)

		test.case("only the owning client predicts, and only when the meter allows it", function()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				local Stamina, Posture = defs.Stamina, defs.Posture

				local ok, err = pcall(function()
					Stamina:predictRate(alice, -10)
				end)
				check.equal(ok, false)
				check.not_nil((string.find(tostring(err), "runs on the client that owns the meter", 1, true)))
				check.not_nil((string.find(tostring(err), "test.Meter:%d")))

				ok, err = pcall(t.as, t, bob, function()
					Stamina:predictRate(alice, -10)
				end)
				check.equal(ok, false)
				check.not_nil((string.find(tostring(err), "can only predict its own meter", 1, true)))

				ok, err = pcall(t.as, t, alice, function()
					Posture:predictAdd(alice, 1)
				end)
				check.equal(ok, false)
				check.not_nil((string.find(tostring(err), "needs predict = true", 1, true)))

				ok, err = pcall(t.as, t, alice, function()
					Stamina:predictRate(alice, 0 / 0)
				end)
				check.equal(ok, false)
				check.not_nil((string.find(tostring(err), "finite number", 1, true)))

				-- Nothing reached the server.
				check.equal(Stamina:get(alice), 100)
			end)
			return nil
		end)

		test.case("onLimit fires when the value gets there, with one timer", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 0 } }, function(t, alice)
				local Stamina = defs.Stamina
				local server: { string } = {}
				local client: { string } = {}
				Stamina:onLimit(alice, function(limit)
					table.insert(server, limit)
				end)
				t:as(alice, function()
					Stamina:onLimit(alice, function(limit)
						table.insert(client, limit)
					end)
				end)
				-- Already full: not reported.
				check.equal(#server, 0)
				-- No rate, nothing to time.
				check.equal(clock(t):pending(), 0)

				Stamina:setRate(alice, -25)
				t:advance(0)
				-- One timer per watching side.
				check.equal(clock(t):pending(), 2)
				t:advance(3.9)
				check.equal(#server, 0)
				check.equal(#client, 0)
				t:advance(0.1)
				check.equal(server[1], "min")
				check.equal(client[1], "min")
				check.equal(clock(t):pending(), 0)

				-- Arriving by a write counts too, but staying there doesn't repeat it.
				Stamina:setRate(alice, 0)
				Stamina:set(alice, 100)
				check.equal(server[2], "max")
				Stamina:add(alice, -100)
				check.equal(server[3], "min")
				Stamina:add(alice, -5)
				check.equal(#server, 3)
				t:advance(0)
				check.equal(client[#client], "min")

				-- Filling up: reported when it gets to max.
				Stamina:setRate(alice, 50)
				t:advance(2)
				check.equal(server[#server], "max")
			end)
			return nil
		end)

		test.case("a disconnected onLimit listener leaves no timer", function()
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local Stamina = defs.Stamina
				local fired = 0
				local disconnect = Stamina:onLimit(alice, function()
					fired += 1
				end)
				Stamina:setRate(alice, -10)
				check.equal(clock(t):pending(), 1)
				disconnect()
				check.equal(clock(t):pending(), 0)
				t:advance(20)
				check.equal(fired, 0)
			end)
			return nil
		end)

		test.case("a player leaving mid-change stops their meter on other clients", function()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				local Posture = defs.Posture
				local record = sent(Posture)
				local bobSaw: { string } = {}
				Posture:setRate(alice, 1)
				t:advance(0)
				t:as(bob, function()
					Posture:onLimit(alice, function(limit)
						table.insert(bobSaw, limit)
					end)
				end)

				-- Leaves while the meter is still filling, with a change pending.
				Posture:add(alice, 2)
				local before = record.count
				t:leave(alice)
				t:advance(0)
				check.equal(record.count, before)
				check.equal(t:as(bob, Posture.get, Posture, alice), 0)

				-- The server still reads it (a playerRemoving save) and keeps extrapolating.
				t:advance(3)
				near(Posture:get(alice), 5)
				Posture:set(alice, 1)
				t:advance(0)
				check.equal(record.count, before)

				-- Bob's limit timer for Alice went with her state.
				t:advance(20)
				check.equal(#bobSaw, 0)
			end)
			return nil
		end)

		test.case("an initial rate starts when the player joins", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 0 } }, function(t, alice)
				local Hunger = defs.Hunger
				near(t:as(alice, Hunger.get, Hunger, alice), 100)
				t:advance(10)
				near(Hunger:get(alice), 90)
				near(t:as(alice, Hunger.get, Hunger, alice), 90)
				check.equal(t:as(alice, Hunger.getRate, Hunger, alice), -1)

				local bob = t:join("Bob")
				t:advance(5)
				near(Hunger:get(bob), 95)
				near(t:as(bob, Hunger.get, Hunger, bob), 95)
			end)
			return nil
		end)

		test.case("computed state built on a meter follows its changes", function()
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local Stamina = defs.Stamina
				local tired = State.computed(function(): boolean
					return Stamina:getRate(alice) < 0
				end)
				local seen: { boolean } = {}
				tired:observe(function(value)
					table.insert(seen, value)
				end)
				Stamina:setRate(alice, -5)
				check.equal(seen[#seen], true)
				t:advance(1)
			end)
			return nil
		end)

		test.case("the documented stamina recipe works end to end", function()
			local Stamina, Sprint = defs.RecipeStamina, defs.RecipeSprint
			local DRAIN = -25
			local REFILL = 10
			local Sprinting = Hydrogen.define("MeterRecipeSprinting", function()
				local Sprinting = {}

				function Sprinting:init()
					Sprint:On(function(player: Player, sprinting: boolean)
						if not sprinting then
							Stamina:setRate(player, REFILL)
						elseif Stamina:get(player) > 0 then
							Stamina:setRate(player, DRAIN)
						else
							Stamina:sync(player)
						end
					end)
				end

				function Sprinting:playerAdded(player: Player)
					Hydrogen.Scope.of(self, player):add(Stamina:onLimit(player, function(limit: Hydrogen.MeterLimit)
						if limit == "min" then
							Stamina:setRate(player, REFILL)
						end
					end))
				end

				return Sprinting
			end)

			Hydrogen.test({ systems = { Sprinting }, players = { "Alice" }, clock = { serverNow = 0 } }, function(t, alice)
				-- The Testing example.
				Stamina:set(alice, 50)
				Stamina:setRate(alice, -10)
				t:advance(0)
				t:advance(2)
				check.equal(Stamina:get(alice), 30)
				check.equal(t:as(alice, Stamina.get, Stamina, alice), 30)
				clock(t):setServerOffset(0.1, alice)
				t:as(alice, function()
					Stamina:predictRate(alice, 10)
					Sprint:Fire(false)
				end)
				t:advance(0)
				check.equal(Stamina:getRate(alice), 10)
				clock(t):setServerOffset(0, alice)

				-- Sprint until empty: the server stops it on time and the client follows.
				t:advance(10)
				check.equal(Stamina:get(alice), 100)
				t:as(alice, function()
					Stamina:predictRate(alice, DRAIN)
					Sprint:Fire(true)
				end)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), DRAIN)
				t:advance(0)
				t:advance(4)
				check.equal(Stamina:get(alice), 0)
				check.equal(Stamina:getRate(alice), REFILL)
				t:advance(0)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), REFILL)

				-- Asking to sprint while empty is refused, and sync corrects the prediction at once.
				Stamina:setRate(alice, 0)
				t:advance(0)
				t:as(alice, function()
					Stamina:predictRate(alice, DRAIN)
					Sprint:Fire(true)
				end)
				t:advance(0)
				check.equal(t:as(alice, Stamina.getRate, Stamina, alice), 0)
				check.equal(t:as(alice, Stamina.get, Stamina, alice), 0)
			end)
			return nil
		end)

		test.case("getAt reads the segment in force at a past server time", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 1000 } }, function(t, alice)
				local Mana = defs.Mana
				Mana:set(alice, 20)
				Mana:setRate(alice, 10) -- same instant: one segment from 1000
				t:advance(0.5)
				Mana:add(alice, -10) -- 25 -> 15 at 1000.5
				t:advance(0.5)
				Mana:setRate(alice, -20) -- from 20 at 1001
				t:advance(0.25)
				near(Mana:get(alice), 15)

				near(Mana:getAt(alice, 1000.25) :: number, 22.5)
				near(Mana:getAt(alice, 1000.5) :: number, 15) -- a write's own time reads the new segment
				near(Mana:getAt(alice, 1000.75) :: number, 17.5)
				near(Mana:getAt(alice, 1001.1) :: number, 18)
				near(Mana:getAt(alice, 1001.25) :: number, 15)
				-- Before the first write: the initial value, at rest.
				check.equal(Mana:getAt(alice, 999.8), 0)
				-- More than history (1.5 s) ago: nil, whatever is kept.
				check.equal(Mana:getAt(alice, 999.7), nil)

				-- setRange clamps from its own time on; before it, the old range held.
				Mana:set(alice, 90)
				Mana:setRate(alice, 0)
				t:advance(0.5)
				Mana:setRange(alice, 0, 50)
				check.equal(Mana:get(alice), 50)
				check.equal(Mana:getAt(alice, 1001.5), 90)
				check.equal(Mana:getAt(alice, 1001.75), 50)
				-- sync sends again but changes nothing, so the past reads the same.
				Mana:sync(alice)
				check.equal(Mana:getAt(alice, 1001.5), 90)
				check.equal(Mana:getAt(alice, 1001.75), 50)
			end)
			return nil
		end)

		test.case("getAt clamps mid-segment and extrapolates a stamp a little in the future", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 1000 } }, function(t, alice)
				local Charge = defs.Charge
				Charge:set(8)
				Charge:setRate(2) -- full at 1001
				t:advance(1.5)
				Charge:setRate(-1)
				t:advance(0.5)
				near(Charge:get(), 9.5)

				near(Charge:getAt(1000.5) :: number, 9)
				check.equal(Charge:getAt(1001.25), 10) -- clamped at max inside the segment
				check.equal(Charge:getAt(1001.5), 10)
				-- Ahead of the server's clock (Guards.timestamp allows 0.05 s): the current segment
				-- extrapolated, clamped like get().
				near(Charge:getAt(1002.05) :: number, 9.45)
				check.equal(Charge:getAt(1002 + 60), 0)
				-- history = 2: 1000 is the oldest time it answers for.
				check.equal(Charge:getAt(1000), 8)
				check.equal(Charge:getAt(999.99), nil)

				-- The server only: a client has no past to read.
				fails(function()
					t:as(alice, function()
						Charge:getAt(1001)
					end)
				end, "getAt reads the server's past values and runs on the server only")
			end)
			return nil
		end)

		test.case("history is pruned by time on writes, with a hard cap", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 1000 } }, function(t, alice)
				local Mana, Stamina = defs.Mana, defs.Stamina
				-- A write every frame for 5 seconds keeps about history (1.5 s) of segments.
				for frame = 1, 300 do
					Mana:setRate(alice, if frame % 2 == 0 then 1 else -1)
					t:advance(1 / 60)
				end
				local kept = #(history(Mana, alice) :: { any })
				check.is_true(kept >= 89 and kept <= 92)
				local now = Clock.serverNow()
				check.not_nil(Mana:getAt(alice, now - 1.45))
				check.equal(Mana:getAt(alice, now - 1.55), nil)

				-- Writes at one instant replace each other: nothing to keep for a segment never in force.
				Mana:set(alice, 1)
				local before = #(history(Mana, alice) :: { any })
				for index = 2, 50 do
					Mana:set(alice, index)
				end
				check.equal(#(history(Mana, alice) :: { any }), before)
				check.equal(Mana:getAt(alice, Clock.serverNow()), 50)

				-- Hundreds of writes inside the window: capped at 128, and the dropped time reads nil.
				for index = 1, 400 do
					Mana:set(alice, index % 100)
					t:advance(0.001)
				end
				local past = history(Mana, alice) :: { any }
				check.equal(#past, 128)
				now = Clock.serverNow()
				check.equal(Mana:getAt(alice, past[1].at - 0.0005), nil)
				check.not_nil(Mana:getAt(alice, past[1].at))
				check.not_nil(Mana:getAt(alice, now - 0.05))

				-- A meter without the option keeps nothing.
				Stamina:set(alice, 10)
				t:advance(0.1)
				Stamina:set(alice, 20)
				check.equal(history(Stamina, alice), nil)
			end)
			return nil
		end)

		test.case("a player leaving drops their meter's past", function()
			Hydrogen.test({ players = { "Alice" }, clock = { serverNow = 1000 } }, function(t, alice)
				local Mana = defs.Mana
				Mana:set(alice, 50)
				Mana:setRate(alice, 10)
				t:advance(0.5)
				Mana:setRate(alice, 0)
				t:advance(0.5)
				near(Mana:getAt(alice, 1000.25) :: number, 52.5)

				t:leave(alice)
				check.equal(history(Mana, alice), nil)
				check.equal(Mana:getAt(alice, 1000.25), nil)
				-- The current segment stays readable for playerRemoving hooks.
				check.equal(Mana:getAt(alice, 1001), 55)
				-- Writes after leaving keep nothing.
				Mana:set(alice, 10)
				t:advance(0.5)
				Mana:set(alice, 20)
				check.equal(history(Mana, alice), nil)
			end)
			return nil
		end)

		test.case("the spell-window recipe judges a cast at the moment it was made", function()
			local Mana, Cast = defs.Fulgur, defs.CastFulgur
			local verdicts: { string } = {}
			local Spells = Hydrogen.define("MeterRecipeSpells", function()
				local Spells = {}
				local spentAt: { [Player]: number } = setmetatable({}, { __mode = "k" }) :: any

				function Spells:init()
					-- Drops stamps older than ping (capped at 1 s) + 0.2 s, or from the future.
					Cast:Use(Guards.timestamp())
					Cast:On(function(player: Player, castAt: number)
						if castAt < (spentAt[player] or -math.huge) then
							table.insert(verdicts, "refused: before the last cast was paid")
							return
						end
						local mana = Mana:getAt(player, castAt)
						local seen = `at {string.format("%.1f", mana or -1)} (now {string.format("%.1f", Mana:get(player))})`
						if mana == nil or mana < 85 or mana > 95 then
							table.insert(verdicts, `refused {seen}`)
							Mana:sync(player)
							return
						end
						table.insert(verdicts, `cast {seen}`)
						Mana:add(player, -40)
						spentAt[player] = Clock.serverNow()
					end)
				end

				return Spells
			end)

			Guards.configure({
				ping = function(_player: Player): number?
					return 0.3
				end,
			})
			Hydrogen.test({ systems = { Spells }, players = { "Alice" }, clock = { serverNow = 1000 } }, function(t, alice)
				Mana:set(alice, 80)
				Mana:setRate(alice, 10)
				t:advance(0)
				t:advance(1.6) -- the server is at 96: outside 85-95, so get() would refuse

				-- Alice's view is 0.3 s behind (her ping): she sees 93 and casts.
				clock(t):setServerOffset(-0.3, alice)
				t:as(alice, function()
					near(Mana:get(alice), 93)
					Cast:Fire(Clock.serverNow())
				end)
				t:advance(0)
				check.equal(#verdicts, 1)
				check.equal(verdicts[1], "cast at 93.0 (now 96.0)")
				near(Mana:get(alice), 56)

				-- A second cast stamped before the first was paid for would read the mana it spent
				-- (getAt(1001.35) is 93.5): the recipe refuses it.
				clock(t):setServerOffset(-0.25, alice)
				t:as(alice, function()
					Cast:Fire(Clock.serverNow())
				end)
				t:advance(0)
				check.equal(verdicts[2], "refused: before the last cast was paid")
				near(Mana:getAt(alice, 1001.35) :: number, 93.5)

				-- A stamp backdated past ping + tolerance never reaches the handler.
				clock(t):setServerOffset(-1, alice)
				t:as(alice, function()
					Cast:Fire(Clock.serverNow())
				end)
				t:advance(0)
				check.equal(#verdicts, 2)

				-- Out of the window at the stamp: refused, and the client corrected.
				clock(t):setServerOffset(0, alice)
				t:as(alice, function()
					Cast:Fire(Clock.serverNow())
				end)
				t:advance(0)
				check.equal(verdicts[3], "refused at 56.0 (now 56.0)")
			end)
			Guards.resetConfiguration()
			return nil
		end)

		test.case("bad writes and definitions error with a fix", function()
			Hydrogen.test({ players = { "Alice" } }, function(_t, alice)
				local Stamina, Heat, Mana = defs.Stamina, defs.Heat, defs.Mana

				fails(function()
					Stamina:set(alice, 0 / 0)
				end, "set expects a finite number, got NaN")
				fails(function()
					Stamina:setRate(alice, math.huge)
				end, "setRate expects a finite number, got inf")
				fails(function()
					Heat:add("5" :: any)
				end, "add expects a finite number, got string")
				fails(function()
					Heat:setRange(10, 0)
				end, "setRange got min (10) greater than max (0)")
				fails(function()
					(Stamina :: any):set(5)
				end, "pass the player first")
				fails(function()
					Stamina:getAt(alice, Clock.serverNow())
				end, `getAt needs history in the meter options, e.g. State.playerMeter("MeterStamina", \{ max = 100, history = 1.5 })`)
				fails(function()
					Heat:getAt(Clock.serverNow())
				end, `State.meter("MeterHeat"`)
				fails(function()
					Mana:getAt(alice, 0 / 0)
				end, "getAt expects a server time (a finite number from Clock.serverNow()), got NaN")
				fails(function()
					Mana:getAt(alice, "now" :: any)
				end, "got string")
				fails(function()
					(Mana :: any):getAt(Clock.serverNow())
				end, "pass the player first")
				local okAt, errAt = pcall(function()
					Mana:getAt(alice, math.huge)
				end)
				check.equal(okAt, false)
				check.not_nil((string.find(tostring(errAt), "test.Meter:%d")))

				local ok, err = pcall(function()
					Stamina:setRate(alice, 0 / 0)
				end)
				check.equal(ok, false)
				check.not_nil((string.find(tostring(err), "test.Meter:%d")))
				check.equal(Stamina:get(alice), 100)
			end)

			local function rejects(fn: (...any) -> ...any, text: string)
				local ok, err = pcall(fn)
				check.equal(ok, false)
				if not string.find(tostring(err), text, 1, true) then
					error(`expected an error with "{text}", got {err}`, 2)
				end
			end
			rejects(function()
				State.meter("MeterNoMax", {} :: any)
			end, "meter option max must be a finite number, e.g. { max = 100 }")
			rejects(function()
				State.meter("MeterBackwards", { min = 10, max = 0 })
			end, "meter min (10) is greater than max (0)")
			rejects(function()
				State.meter("MeterNaN", { max = 0 / 0 })
			end, "got NaN")
			rejects(function()
				State.meter("MeterOutside", { max = 10, value = 11 })
			end, "outside the meter's range (0 to 10)")
			rejects(function()
				State.meter("MeterRate", { max = 10, rate = math.huge })
			end, "meter option rate must be a finite number")
			rejects(function()
				State.meter("MeterTypo", { maximum = 10 } :: any)
			end, "unknown meter option maximum")
			rejects(function()
				State.meter("MeterPredict", { max = 10, predict = true } :: any)
			end, "predict only applies to State.playerMeter")
			rejects(function()
				State.playerMeter("MeterTimeout", { max = 10, predictTimeout = 2 })
			end, "predictTimeout only applies with predict = true")
			rejects(function()
				State.meter("MeterVisible", { max = 10, visibleTo = "everyone" } :: any)
			end, "visibleTo only applies to per-player state")
			rejects(function()
				State.meter("MeterHistoryZero", { max = 10, history = 0 })
			end, "history must be a positive number of seconds, e.g. history = 1.5, got 0")
			rejects(function()
				State.playerMeter("MeterHistoryNaN", { max = 10, history = 0 / 0 })
			end, "history must be a positive number of seconds, e.g. history = 1.5, got NaN")
			rejects(function()
				State.meter("MeterHistoryString", { max = 10, history = "1" :: any })
			end, "got string")
			return nil
		end)

		return nil
	end)
	return nil
end
