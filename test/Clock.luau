--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Clock = require("../src/Clock")

return function()
	-- A failing test must not leave the fake clock installed for the next one.
	test.on_test_leave(function()
		local fake = Clock.active()
		if fake then
			fake:restore()
		end
	end)

	test.suite("Clock", function()
		test.case("uses the built-ins until a fake is installed", function()
			check.equal(Clock.now, os.clock)
			check.equal(Clock.time, os.time)
			check.equal(Clock.wait, task.wait)
			check.equal(Clock.delay, task.delay)
			check.equal(Clock.active(), nil)

			local fake = Clock.fake()
			check.not_equal(Clock.now, os.clock)
			check.equal(Clock.active(), fake)

			fake:restore()
			check.equal(Clock.now, os.clock)
			check.equal(Clock.wait, task.wait)
			check.equal(Clock.active(), nil)
			return nil
		end)

		test.case("only one fake clock at a time", function()
			local fake = Clock.fake()
			check.should_error(function()
				Clock.fake()
				return nil
			end)
			fake:restore()
			fake:restore()
			Clock.fake():restore()
			return nil
		end)

		test.case("time only moves on advance", function()
			local fake = Clock.fake({ now = 100, time = 1700000000 })
			check.equal(Clock.now(), 100)
			check.equal(Clock.time(), 1700000000)

			fake:advance(2.5)
			check.equal(Clock.now(), 102.5)
			check.equal(fake:now(), 102.5)
			check.equal(Clock.time(), 1700000002)

			check.should_error(function()
				fake:advance(-1)
				return nil
			end)
			return nil
		end)

		test.case("timers run in due order, ties in scheduling order", function()
			local fake = Clock.fake()
			local order = {}
			local at = {}

			Clock.delay(2, function(label: string)
				table.insert(order, label)
				table.insert(at, Clock.now())
			end, "two")
			Clock.delay(1, function()
				table.insert(order, "one-a")
				table.insert(at, Clock.now())
			end)
			Clock.delay(1, function()
				table.insert(order, "one-b")
				table.insert(at, Clock.now())
			end)
			check.equal(fake:pending(), 3)

			fake:advance(0.5)
			check.equal(#order, 0)

			fake:advance(5)
			check.equal(table.concat(order, ","), "one-a,one-b,two")
			-- Each timer sees its own due time, not the end of the advance.
			check.equal(at[1], 1)
			check.equal(at[3], 2)
			check.equal(Clock.now(), 5.5)
			check.equal(fake:pending(), 0)
			return nil
		end)

		test.case("waits resume with the seconds waited, and loops run once per interval", function()
			local fake = Clock.fake()
			local saves = 0
			local waited = 0

			task.spawn(function()
				while true do
					waited = Clock.wait(60)
					saves += 1
				end
			end)

			fake:advance(59)
			check.equal(saves, 0)
			fake:advance(1)
			check.equal(saves, 1)
			check.equal(waited, 60)

			-- One advance runs every interval inside it.
			fake:advance(180)
			check.equal(saves, 4)
			return nil
		end)

		test.case("delay resumes a thread, as task.delay does", function()
			local fake = Clock.fake()
			local got = nil
			local thread = coroutine.create(function(value: number)
				got = value
			end)
			check.equal(Clock.delay(1, thread, 7), thread)
			fake:advance(1)
			check.equal(got, 7)
			return nil
		end)

		test.case("cancel stops a delay before it runs", function()
			local fake = Clock.fake()
			local ran = false
			local thread = Clock.delay(1, function()
				ran = true
			end)
			Clock.cancel(thread)
			check.equal(fake:pending(), 0)
			fake:advance(2)
			check.equal(ran, false)
			return nil
		end)

		test.case("heartbeat and frame waits fire once per advance", function()
			local fake = Clock.fake()
			local beats: { number } = {}
			local frames = 0

			local disconnect = Clock.heartbeat(function(dt)
				table.insert(beats, dt)
			end)
			task.spawn(function()
				while true do
					Clock.wait()
					frames += 1
				end
			end)

			fake:advance(1 / 60)
			fake:advance(0)
			check.equal(#beats, 2)
			check.equal(beats[1], 1 / 60)
			check.equal(beats[2], 0)
			check.equal(frames, 2)

			disconnect()
			fake:advance(1)
			check.equal(#beats, 2)
			return nil
		end)

		test.case("next jumps to the next timer", function()
			local fake = Clock.fake()
			check.equal(fake:next(), nil)

			local ran = 0
			Clock.delay(30, function()
				ran += 1
			end)
			Clock.delay(10, function()
				ran += 1
			end)

			check.equal(fake:next(), 10)
			check.equal(ran, 1)
			check.equal(fake:next(), 20)
			check.equal(Clock.now(), 30)
			check.equal(fake:next(), nil)
			return nil
		end)

		test.case("a timer rescheduling itself with no delay is caught", function()
			local fake = Clock.fake()
			local function again()
				Clock.delay(0, again)
			end
			Clock.delay(0, again)
			check.should_error(function()
				fake:advance(1)
				return nil
			end)
			return nil
		end)

		test.case("restore abandons waiting threads", function()
			local fake = Clock.fake()
			local resumed = false
			task.spawn(function()
				Clock.wait(1)
				resumed = true
			end)
			fake:restore()

			local next = Clock.fake()
			next:advance(5)
			check.equal(resumed, false)
			next:restore()
			return nil
		end)

		return nil
	end)
	return nil
end
