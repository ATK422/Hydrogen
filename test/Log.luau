--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Clock = require("../src/Clock")
local Log = require("../src/Log")

local gt = Hydrogen.gt

return function()
	-- What the console wrote, by channel, while a test swapped the outputs in.
	local printed: { string } = {}
	local warned: { string } = {}
	local realOutput = Log.output
	local realInfoOutput = Log.infoOutput
	local snapshot = Log._snapshot()

	local function swapOutputs()
		table.clear(printed)
		table.clear(warned)
		Log.output = function(message: string)
			table.insert(warned, message)
		end
		Log.infoOutput = function(message: string)
			table.insert(printed, message)
		end
	end

	-- Records every line a sink would see.
	local function record(): ({ Log.Line }, () -> ())
		local lines: { Log.Line } = {}
		local remove = Log.addSink(function(line)
			table.insert(lines, line)
		end)
		return lines, remove
	end

	test.on_test_leave(function()
		Log.output = realOutput
		Log.infoOutput = realInfoOutput
		Log._restore(snapshot)
		local fake = Clock.active()
		if fake then
			fake:restore()
		end
	end)

	test.suite("Log", function()
		test.case("tagged lines carry the name and fields, and go to print or warn by level", function()
			swapOutputs()
			local log = Hydrogen.Log.of("Shop")
			log:info("bought", { item = "sword", price = 50 })
			log:warn("couldn't charge", { player = "Alice", reason = "not enough coins" })
			log:error("inventory desynced")

			check.equal(printed[1], "[Shop] bought item=sword price=50")
			check.equal(warned[1], `[Shop] couldn't charge player=Alice reason="not enough coins"`)
			check.equal(warned[2], "[Shop] error: inventory desynced")
			check.equal(#printed, 1)
			check.equal(#warned, 2)
			return nil
		end)

		test.case("the same target gives the same logger", function()
			check.equal(Hydrogen.Log.of("Shop"), Hydrogen.Log.of("Shop"))
			check.not_equal(Hydrogen.Log.of("Shop"), Hydrogen.Log.of("Trade"))
			check.should_error(function()
				Hydrogen.Log.of("")
				return nil
			end)
			check.should_error(function()
				Hydrogen.Log.of(5 :: any)
				return nil
			end)
			return nil
		end)

		test.case("a system's logger is named after its id, even when made in its constructor", function()
			swapOutputs()
			local made: Log.Logger? = nil
			local Shop = Hydrogen.define("LogShop", function()
				local system = {}
				made = Hydrogen.Log.of(system)
				return system
			end)

			local log = Hydrogen.Log.of(Shop)
			check.equal(log, made)
			check.equal(log:name(), "LogShop")
			log:info("ready")
			check.equal(printed[1], "[LogShop] ready")
			return nil
		end)

		test.case("field values: plain words unquoted, strings with spaces quoted, tables and nesting", function()
			check.equal(Log.format({ b = 2, a = "x y", c = true }), ` a="x y" b=2 c=true`)
			check.equal(Log.format({ list = { 1, 2 }, map = { k = "v" } }), ` list=\{1, 2} map=\{k = "v"}`)
			check.equal(Log.format({ empty = "" }), ` empty=""`)
			check.equal(Log.format({ eq = "a=b" }), ` eq="a=b"`)
			check.equal(Log.format(nil), "")
			check.equal(Log.format({}), "")
			local long = Log.format({ text = string.rep("a", 500) })
			check.not_nil(string.find(long, "(500 chars)", 1, true))
			check.equal(#long < 300, true)
			return nil
		end)

		test.case("debug is off by default outside Studio, and the global level changes that", function()
			swapOutputs()
			local log = Hydrogen.Log.of("Levels")
			check.equal(Hydrogen.Log.level(), "info")
			log:debug("hidden")
			check.equal(#printed, 0)
			check.equal(log:enabled("debug"), false)
			check.equal(log:enabled("info"), true)

			Hydrogen.Log.setLevel("debug")
			log:debug("shown")
			check.equal(printed[1], "[Levels] debug: shown")
			check.equal(log:enabled("debug"), true)

			Hydrogen.Log.setLevel("off")
			log:error("nothing")
			check.equal(#warned, 0)

			Hydrogen.Log.setLevel(nil)
			check.equal(Hydrogen.Log.level(), "info")
			return nil
		end)

		test.case("a name's level overrides the global one", function()
			swapOutputs()
			local shop = Hydrogen.Log.of("OverShop")
			local trade = Hydrogen.Log.of("OverTrade")

			Hydrogen.Log.setLevel("warn", "OverShop")
			shop:info("hidden")
			trade:info("shown")
			check.equal(#printed, 1)
			check.equal(printed[1], "[OverTrade] shown")
			check.equal(Hydrogen.Log.level("OverShop"), "warn")
			check.equal(Hydrogen.Log.level("OverTrade"), "info")

			shop:setLevel("debug")
			shop:debug("now shown")
			check.equal(printed[2], "[OverShop] debug: now shown")

			-- A logger made from the name sees the same override.
			Hydrogen.Log.setLevel("error", "OverShop")
			check.equal(Hydrogen.Log.of("OverShop"):enabled("warn"), false)

			shop:setLevel(nil)
			shop:info("back to global")
			check.equal(printed[3], "[OverShop] back to global")
			return nil
		end)

		test.case("levels set by system follow its id", function()
			swapOutputs()
			local Quiet = Hydrogen.define("LogQuiet", function()
				return {}
			end)
			Hydrogen.Log.setLevel("off", Quiet)
			Hydrogen.Log.of(Quiet):error("hidden")
			Hydrogen.Log.of("LogQuiet"):error("hidden too")
			check.equal(#warned, 0)
			check.equal(Hydrogen.Log.level(Quiet), "off")
			return nil
		end)

		test.case("bad levels and targets error with the fix", function()
			local ok, err = pcall(function()
				Hydrogen.Log.setLevel("verbose" :: any)
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), `"debug", "info", "warn", "error" or "off"`, 1, true))

			check.should_error(function()
				Hydrogen.Log.of("X"):enabled("off" :: any)
				return nil
			end)
			check.should_error(function()
				Hydrogen.Log.setLevel("info", {})
				return nil
			end)
			check.should_error(function()
				Hydrogen.Log.of("X"):with(5 :: any)
				return nil
			end)
			return nil
		end)

		test.case("a filtered line never builds its message or reads its fields", function()
			swapOutputs()
			local log = Hydrogen.Log.of("Lazy")
			local built = 0
			local formatted = 0
			local value = newproxy(true)
			getmetatable(value).__tostring = function()
				formatted += 1
				return "value"
			end

			log:debug(function()
				built += 1
				return "expensive", { value = value }
			end)
			log:debug("cheap", { value = value })
			check.equal(built, 0)
			check.equal(formatted, 0)
			check.equal(#printed, 0)

			Hydrogen.Log.setLevel("debug")
			log:debug(function()
				built += 1
				return "expensive", { value = value }
			end, { extra = 1 })
			check.equal(built, 1)
			check.equal(formatted, 1)
			check.equal(printed[1], "[Lazy] debug: expensive extra=1 value=value")
			return nil
		end)

		test.case("a filtered call with a constant message allocates nothing", function()
			local log = Hydrogen.Log.of("Alloc")
			log:debug("warm up")
			local before = gcinfo()
			for _ = 1, 100000 do
				log:debug("filtered")
			end
			-- In KB; a table or string per call would be several MB.
			check.equal(gcinfo() - before < 16, true)
			return nil
		end)

		test.case("a message function that errors is reported and logging carries on", function()
			swapOutputs()
			local log = Hydrogen.Log.of("Broken")
			log:info(function(): string
				error("boom")
			end)
			log:info("after")
			check.not_nil(string.find(warned[1], "[HYDROGEN] A log message function failed in Broken", 1, true))
			check.equal(printed[1], "[Broken] after")
			return nil
		end)

		test.case("non-string messages are converted", function()
			swapOutputs()
			Hydrogen.Log.of("Num"):info(42 :: any)
			check.equal(printed[1], "[Num] 42")
			return nil
		end)

		test.case("with() adds fields to every line and follows the parent's level", function()
			swapOutputs()
			local log = Hydrogen.Log.of("Round")
			local round = log:with({ round = 3 })
			round:info("started", { map = "Castle" })
			check.equal(printed[1], "[Round] started map=Castle round=3")
			check.equal(round:name(), "Round")

			local nested = round:with({ wave = 2 })
			nested:info("spawned", { round = 4 })
			check.equal(printed[2], "[Round] spawned round=4 wave=2")

			log:setLevel("warn")
			round:info("hidden")
			check.equal(#printed, 2)
			return nil
		end)

		test.case("a player's logger adds the player's name and is reused", function()
			swapOutputs()
			local player = { Name = "Alice" } :: any
			local log = Hydrogen.Log.of("Trade", player)
			check.equal(log, Hydrogen.Log.of("Trade", player))
			log:info("offered", { item = "shield" })
			check.equal(printed[1], "[Trade] offered item=shield player=Alice")
			check.should_error(function()
				Hydrogen.Log.of("Trade", 5 :: any)
				return nil
			end)
			return nil
		end)

		test.case("sinks get the frozen line with level, tag, fields and the clock's time", function()
			swapOutputs()
			local fake = Clock.fake({ now = 7 })
			local lines, remove = record()
			Hydrogen.Log.of("Sink"):warn("low stock", { item = "sword" })
			fake:restore()

			local line = lines[1]
			check.equal(line.level, "warn")
			check.equal(line.tag, "Sink")
			check.equal(line.message, "low stock")
			check.equal(line.fields and line.fields.item, "sword")
			check.equal(line.text, "[Sink] low stock item=sword")
			check.equal(line.at, 7)
			check.equal(table.isfrozen(line), true)

			remove()
			Hydrogen.Log.of("Sink"):warn("again")
			check.equal(#lines, 1)
			return nil
		end)

		test.case("a sink that errors is reported once and doesn't stop other sinks", function()
			swapOutputs()
			local fail = true
			local failures = 0
			Hydrogen.Log.addSink(function()
				if fail then
					failures += 1
					error("sink exploded")
				end
			end)
			local lines = record()

			local log = Hydrogen.Log.of("Sinks")
			log:info("one")
			log:info("two")
			check.equal(failures, 2)
			check.equal(#lines, 2)
			check.equal(#printed, 2)
			check.equal(#warned, 1)
			check.not_nil(string.find(warned[1], "[HYDROGEN] A log sink failed", 1, true))
			check.not_nil(string.find(warned[1], "sink exploded", 1, true))

			-- After it works again, a new failure is reported again.
			fail = false
			log:info("three")
			fail = true
			log:info("four")
			check.equal(#warned, 2)
			return nil
		end)

		test.case("a sink that yields doesn't hold up the caller", function()
			swapOutputs()
			local resumed = false
			Hydrogen.Log.addSink(function()
				task.wait()
				resumed = true
			end)
			Hydrogen.Log.of("Slow"):info("sent")
			check.equal(resumed, false)
			check.equal(printed[1], "[Slow] sent")
			return nil
		end)

		test.case("a line logged inside a sink goes to the console only", function()
			swapOutputs()
			local log = Hydrogen.Log.of("Loop")
			local calls = 0
			Hydrogen.Log.addSink(function(line)
				calls += 1
				log:info(`saw {line.message}`)
			end)
			log:info("first")
			check.equal(calls, 1)
			check.equal(printed[1], "[Loop] first")
			check.equal(printed[2], "[Loop] saw first")
			return nil
		end)

		test.case("removing the console silences it; sinks still see lines", function()
			swapOutputs()
			local lines = record()
			Hydrogen.Log.removeSink(Hydrogen.Log.console)
			Hydrogen.Log.of("Silent"):warn("only sinks")
			check.equal(#warned, 0)
			check.equal(#lines, 1)
			Hydrogen.Log.addSink(Hydrogen.Log.console)
			Hydrogen.Log.of("Silent"):warn("console again")
			check.equal(warned[1], "[Silent] console again")
			check.should_error(function()
				Hydrogen.Log.addSink(5 :: any)
				return nil
			end)
			return nil
		end)

		test.case("a buffer keeps the most recent lines, oldest first", function()
			swapOutputs()
			local recent = Hydrogen.Log.buffer(3)
			local log = Hydrogen.Log.of("Buf")
			check.equal(#recent:lines(), 0)
			log:info("1")
			log:warn("2")
			check.equal(#recent:lines(), 2)
			log:info("3")
			log:error("4")
			log:info("5")

			local lines = recent:lines()
			check.equal(#lines, 3)
			check.equal(lines[1].message, "3")
			check.equal(lines[2].message, "4")
			check.equal(lines[3].message, "5")
			check.equal(recent:total(), 5)

			local serious = recent:lines("warn")
			check.equal(#serious, 1)
			check.equal(serious[1].message, "4")

			recent:clear()
			check.equal(#recent:lines(), 0)
			log:info("6")
			check.equal(recent:lines()[1].message, "6")

			recent:stop()
			log:info("7")
			check.equal(#recent:lines(), 1)
			check.equal(recent:total(), 6)

			check.should_error(function()
				Hydrogen.Log.buffer(0)
				return nil
			end)
			check.should_error(function()
				recent:lines("loud" :: any)
				return nil
			end)
			return nil
		end)

		test.case("rate limiting drops repeats and reports how many when the window ends", function()
			swapOutputs()
			local fake = Clock.fake()
			local lines = record()
			Hydrogen.Log.rateLimit({ burst = 3, window = 10 })
			local log = Hydrogen.Log.of("Spam")

			for _ = 1, 10 do
				log:warn("frame dropped")
				log:info("other line")
				fake:advance(0.1)
			end
			-- Three of each, the rest dropped.
			check.equal(#warned, 3)
			check.equal(#printed, 3)

			fake:advance(10)
			check.equal(#warned, 4)
			check.equal(warned[4], "[Spam] frame dropped (repeated 7 more times in 10s)")
			check.equal(printed[4], "[Spam] other line (repeated 7 more times in 10s)")
			check.equal(lines[#lines].repeated, 7)

			-- A new window lets lines through again.
			log:warn("frame dropped")
			check.equal(#warned, 5)

			-- Different fields make a different line.
			for index = 1, 5 do
				log:warn("hit", { index = index })
			end
			check.equal(#warned, 10)
			return nil
		end)

		test.case("turning rate limiting off reports what it was holding", function()
			swapOutputs()
			Clock.fake()
			Hydrogen.Log.rateLimit({ burst = 1, window = 60 })
			local log = Hydrogen.Log.of("Off")
			log:warn("again")
			log:warn("again")
			log:warn("again")
			check.equal(#warned, 1)
			Hydrogen.Log.rateLimit(false)
			check.equal(warned[2], "[Off] again (repeated 2 more times in 60s)")
			log:warn("again")
			check.equal(#warned, 3)

			check.should_error(function()
				Hydrogen.Log.rateLimit({ burst = 0 })
				return nil
			end)
			check.should_error(function()
				Hydrogen.Log.rateLimit({ window = -1 })
				return nil
			end)
			return nil
		end)

		test.case("rate limiting survives the clock being swapped", function()
			swapOutputs()
			local fake = Clock.fake({ now = 1000 })
			Hydrogen.Log.rateLimit({ burst = 1, window = 10 })
			local log = Hydrogen.Log.of("Swap")
			log:warn("x")
			log:warn("x")
			fake:restore()
			-- The pending timer died with the fake clock; the next line notices the window ended.
			Clock.fake({ now = 0 })
			log:warn("x")
			check.equal(warned[2], "[Swap] x (repeated 1 more time in 10s)")
			check.equal(warned[3], "[Swap] x")
			return nil
		end)

		test.case("Log.warn keeps Hydrogen's text exactly and tags it HYDROGEN", function()
			swapOutputs()
			local lines = record()
			Log.warn("[HYDROGEN] Something odd: 5")
			Log.warn("bare message")
			check.equal(warned[1], "[HYDROGEN] Something odd: 5")
			check.equal(warned[2], "bare message")
			check.equal(lines[1].tag, "HYDROGEN")
			check.equal(lines[1].message, "Something odd: 5")
			check.equal(lines[1].level, "warn")
			check.equal(lines[2].tag, nil)

			Hydrogen.Log.setLevel("error", "HYDROGEN")
			Log.warn("[HYDROGEN] filtered")
			check.equal(#warned, 2)
			return nil
		end)

		test.case("Log.capture sees warn and error lines first and can keep them from the console", function()
			swapOutputs()
			local lines = record()
			local seen: { string } = {}
			local levels: { string } = {}
			local uncapture = Log.capture(function(message, line)
				table.insert(seen, message)
				table.insert(levels, line.level)
				return true
			end)

			Log.warn("[HYDROGEN] captured")
			Hydrogen.Log.of("Cap"):error("also captured")
			Hydrogen.Log.of("Cap"):info("not a warning")
			uncapture()
			Log.warn("[HYDROGEN] printed")

			check.equal(seen[1], "[HYDROGEN] captured")
			check.equal(seen[2], "[Cap] error: also captured")
			check.equal(levels[2], "error")
			check.equal(#seen, 2)
			check.equal(#warned, 1)
			check.equal(warned[1], "[HYDROGEN] printed")
			-- Capturing only keeps lines from the console; sinks see all of them.
			check.equal(#lines, 4)
			return nil
		end)

		test.case("a capture that doesn't claim a warning lets it through", function()
			swapOutputs()
			local seen = 0
			local uncapture = Log.capture(function()
				seen += 1
				return nil
			end)
			Log.warn("[HYDROGEN] through")
			uncapture()
			check.equal(seen, 1)
			check.equal(warned[1], "[HYDROGEN] through")
			return nil
		end)

		test.case("Hydrogen.test: expectLog, expectWarning on loggers, and logLevel", function()
			swapOutputs()
			local Shop = Hydrogen.define("LogHarnessShop", function()
				local Shop = {}
				local log = Hydrogen.Log.of(Shop)
				function Shop:start()
					log:debug("stocking", { items = 3 })
					log:info("open", { items = 3 })
					log:warn("low stock", { item = "sword" })
				end
				return Shop
			end)

			Hydrogen.test({ systems = { Shop }, logLevel = "debug" }, function(t)
				t:expectLog("debug", "[LogHarnessShop] debug: stocking items=3")
				t:expectLog("info", "open")
				check.should_error(function()
					t:expectLog("info", "low stock")
					return nil
				end)
				check.should_error(function()
					t:expectNoWarnings()
					return nil
				end)
				t:expectLog("warn", "low stock")
				t:expectNoWarnings()
				check.equal(#t:logs(), 3)
				check.equal(#t:logs("warn"), 1)
				check.equal(t:logs("info")[1].fields and t:logs("info")[1].fields.items, 3)
				check.equal(Hydrogen.Log.level(), "debug")
			end)
			check.equal(Hydrogen.Log.level(), "info")

			Hydrogen.test({ systems = { Shop } }, function(t)
				t:expectWarning("low stock")
				local ok, err = pcall(function()
					t:expectLog("debug", "stocking")
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), `pass logLevel = "debug"`, 1, true))
				check.should_error(function()
					t:expectLog("loud" :: any, "x")
					return nil
				end)
			end)
			return nil
		end)

		test.case("Hydrogen.test: error lines count as warnings", function()
			Hydrogen.test(function(t)
				Hydrogen.Log.of("Errs"):error("bad state")
				check.equal(t:warnings()[1], "[Errs] error: bad state")
				t:expectLog("error", "bad state")
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("Hydrogen.test puts levels, sinks and the rate limit back", function()
			local outside = 0
			Hydrogen.test(function()
				Hydrogen.Log.setLevel("off", "Leak")
				Hydrogen.Log.rateLimit({ burst = 1 })
				Hydrogen.Log.addSink(function()
					outside += 1
				end)
			end)
			check.equal(Hydrogen.Log.level("Leak"), "info")
			swapOutputs()
			Hydrogen.Log.of("Leak"):info("a")
			Hydrogen.Log.of("Leak"):info("a")
			check.equal(#printed, 2)
			check.equal(outside, 0)
			return nil
		end)

		test.case("Hydrogen.test still prints unexpected warnings when it closes", function()
			swapOutputs()
			Hydrogen.test(function()
				Hydrogen.Log.of("Late"):warn("nobody expected this")
			end)
			check.equal(warned[1], "[Late] nobody expected this")
			return nil
		end)

		test.case("Hydrogen.logger() writes traffic through Hydrogen.Log by default", function()
			swapOutputs()
			local Chat = Hydrogen.clientEvent("log-Chat", gt.string())
			Hydrogen.test({ players = { "Tester" } }, function(t, tester)
				Hydrogen.useMiddleware(Hydrogen.logger({
					filter = function(context)
						return context.name == "log-Chat"
					end,
				}))
				Chat:On(function() end)
				t:as(tester, function()
					Chat:Fire("hi")
				end)
				t:expectLog("info", `[HYDROGEN] -> log-Chat: "hi"`)
				t:expectLog("info", `[HYDROGEN] <- log-Chat from Tester: "hi"`)
				local line = t:logs("info")[1]
				check.equal(line.tag, "HYDROGEN")
			end)
			return nil
		end)

		test.case("Hydrogen.logger() with an output keeps writing there", function()
			local lines: { string } = {}
			local middleware = Hydrogen.logger({
				output = function(message)
					table.insert(lines, message)
				end,
			})
			middleware({ name = "X", kind = "ClientEvent", direction = "outgoing", payload = "event" }, 1)
			check.equal(lines[1], "[HYDROGEN] -> X: 1")
			return nil
		end)
	end)
end
