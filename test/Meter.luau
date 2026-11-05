--!strict

-- Hydrogen.State.meter / playerMeter through Hydrogen.test: segments replicate only on changes,
-- get() extrapolates on each side from Clock.serverNow(), and the owner can predict.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")

local gt = Hydrogen.gt
local State = Hydrogen.State

-- Defined when the suite starts, before any network runs.
local defs: {
	Stamina: Hydrogen.PlayerMeter,
	Heat: Hydrogen.StateMeter,
	Posture: Hydrogen.PlayerMeter,
	Hunger: Hydrogen.PlayerMeter,
	Sprint: Hydrogen.ClientEvent<boolean>,
	RecipeStamina: Hydrogen.PlayerMeter,
	RecipeSprint: Hydrogen.ClientEvent<boolean>,
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
	}
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

		test.case("bad writes and definitions error with a fix", function()
			Hydrogen.test({ players = { "Alice" } }, function(_t, alice)
				local Stamina, Heat = defs.Stamina, defs.Heat
				local function fails(fn: (...any) -> ...any, text: string)
					local ok, err = pcall(fn)
					check.equal(ok, false)
					if not string.find(tostring(err), text, 1, true) then
						error(`expected an error with "{text}", got {err}`, 2)
					end
					check.not_nil((string.find(tostring(err), "[HYDROGEN]", 1, true)))
				end

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
			return nil
		end)

		return nil
	end)
	return nil
end
