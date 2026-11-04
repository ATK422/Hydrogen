--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")

local Scheduler = Hydrogen.Scheduler
local Clock = Hydrogen.Clock

local function contains(text: string, part: string): boolean
	return string.find(text, part, 1, true) ~= nil
end

-- A clock whose wake-ups the test delivers late, to simulate a server hitch: the fake clock
-- always runs timers exactly on time.
type LateClock = {
	deliver: (at: number) -> (),
	pending: () -> number,
	restore: () -> (),
}

local function lateClock(): LateClock
	local saved = { now = Clock.now, delay = Clock.delay, cancel = Clock.cancel }
	local now = 0
	local waiting: { { at: number, thread: thread } } = {}

	local clock = Clock :: any
	clock.now = function(): number
		return now
	end
	clock.delay = function(seconds: number, fn: () -> ()): thread
		local thread = coroutine.create(fn)
		table.insert(waiting, { at = now + seconds, thread = thread })
		return thread
	end
	clock.cancel = function(thread: thread)
		for index, entry in waiting do
			if entry.thread == thread then
				table.remove(waiting, index)
				return
			end
		end
	end

	return {
		deliver = function(at: number)
			now = at
			local due = {}
			for index = #waiting, 1, -1 do
				if waiting[index].at <= at then
					table.insert(due, table.remove(waiting, index))
				end
			end
			for _, entry in due do
				task.spawn(entry.thread)
			end
		end,
		pending = function(): number
			return #waiting
		end,
		restore = function()
			clock.now = saved.now
			clock.delay = saved.delay
			clock.cancel = saved.cancel
		end,
	}
end

return function()
	local late: LateClock? = nil

	test.on_test_leave(function()
		if late then
			late.restore()
			late = nil
		end
		local fake = Clock.active()
		if fake then
			fake:restore()
		end
	end)

	test.suite("Scheduler", function()
		test.case("after runs once, at its due time", function()
			Hydrogen.test({}, function(t)
				local at: { number } = {}
				local timer = Scheduler.after(2, function()
					table.insert(at, Clock.now())
				end)
				check.equal(timer.active, true)
				t:advance(1.5)
				check.equal(#at, 0)
				t:advance(10)
				check.equal(#at, 1)
				check.equal(at[1], 2)
				check.equal(timer.active, false)
				check.equal(Scheduler.count(), 0)
			end)
			return nil
		end)

		test.case("every runs once per interval, with the time since the last run", function()
			Hydrogen.test({}, function(t)
				local runs: { number } = {}
				local elapsed: { number } = {}
				Scheduler.every(60, function(seconds: number)
					table.insert(runs, Clock.now())
					table.insert(elapsed, seconds)
				end)
				t:advance(59)
				check.equal(#runs, 0)
				t:advance(5 * 60 - 59)
				check.equal(#runs, 5)
				check.equal(runs[1], 60)
				check.equal(runs[5], 300)
				check.equal(elapsed[1], 60)
				check.equal(elapsed[5], 60)
			end)
			return nil
		end)

		test.case("timers run in due order, ties in creation order, interleaved with Clock.delay", function()
			Hydrogen.test({}, function(t)
				local order = {}
				Scheduler.after(2, function()
					table.insert(order, "after2")
				end)
				Scheduler.after(1, function()
					table.insert(order, "after1-a")
				end)
				Clock.delay(1.5, function()
					table.insert(order, "delay1.5")
				end)
				Scheduler.after(1, function()
					table.insert(order, "after1-b")
				end)
				Scheduler.every(1, function()
					table.insert(order, "every")
				end)
				t:advance(2)
				check.equal(table.concat(order, ","), "after1-a,after1-b,every,delay1.5,after2,every")
			end)
			return nil
		end)

		test.case("one waiting thread however many timers, and none when idle", function()
			Hydrogen.test({}, function(t)
				check.equal(t.clock:pending(), 0)
				local timers = {}
				for index = 1, 1000 do
					table.insert(timers, Scheduler.every(index, function() end))
				end
				check.equal(Scheduler.count(), 1000)
				check.equal(t.clock:pending(), 1)
				t:advance(10)
				check.equal(t.clock:pending(), 1)
				for _, timer in timers do
					timer:cancel()
				end
				check.equal(Scheduler.count(), 0)
				check.equal(t.clock:pending(), 0)
			end)
			return nil
		end)

		test.case("cancel stops a timer, also from inside its own callback", function()
			Hydrogen.test({}, function(t)
				local runs = 0
				local timer = Scheduler.after(1, function()
					runs += 1
				end)
				timer:cancel()
				timer:cancel()
				check.equal(timer.active, false)

				local repeating: Hydrogen.Timer = nil :: any
				repeating = Scheduler.every(1, function()
					runs += 1
					if runs == 3 then
						repeating:cancel()
					end
				end)
				t:advance(10)
				check.equal(runs, 3)
				check.equal(Scheduler.count(), 0)
			end)
			return nil
		end)

		test.case("an erroring callback is warned with a traceback and the timer keeps going", function()
			Hydrogen.test({}, function(t)
				local runs = 0
				Scheduler.every(1, function()
					runs += 1
					error("tick failed")
				end)
				t:advance(3)
				check.equal(runs, 3)
				local warnings = t:warnings()
				check.equal(#warnings, 3)
				check.equal(contains(warnings[1], "[HYDROGEN] Scheduler: every(1) callback failed:"), true)
				check.equal(contains(warnings[1], "tick failed"), true)
				check.equal(contains(warnings[1], "\n"), true)
				t:expectWarning("tick failed")
			end)
			return nil
		end)

		test.case("a repeating timer whose callback yields skips runs until it returns", function()
			Hydrogen.test({}, function(t)
				local started = 0
				local finished = 0
				local other = 0
				Scheduler.every(1, function()
					started += 1
					if started == 1 then
						Clock.wait(2.5)
					end
					finished += 1
				end)
				Scheduler.every(1, function()
					other += 1
				end)
				t:advance(1)
				check.equal(started, 1)
				check.equal(finished, 0)
				t:advance(2) -- t = 3: runs at 2 and 3 are skipped while the first waits until 3.5
				check.equal(started, 1)
				check.equal(other, 3)
				t:advance(1) -- t = 4
				check.equal(finished, 2)
				check.equal(started, 2)
				t:expectWarning("every(1) skipped a run because its last run yielded")
				-- Warned once per timer, not once per skipped run.
				check.equal(#t:warnings(), 1)
			end)
			return nil
		end)

		test.case("after(0) from a callback runs in the same advance, not in a loop", function()
			Hydrogen.test({}, function(t)
				local order = {}
				Scheduler.after(1, function()
					table.insert(order, "first")
					Scheduler.after(0, function()
						table.insert(order, "zero")
					end)
				end)
				t:advance(1)
				check.equal(table.concat(order, ","), "first,zero")
			end)
			return nil
		end)

		test.case("fixed steps exactly once per step under the fake clock", function()
			Hydrogen.test({}, function(t)
				local steps = 0
				local dts: { number } = {}
				local times: { number } = {}
				Scheduler.fixed(1 / 20, function(dt: number)
					steps += 1
					table.insert(dts, dt)
					table.insert(times, Clock.now())
				end)
				t:advance(1)
				check.equal(steps, 20)
				check.equal(dts[1], 1 / 20)
				check.equal(dts[20], 1 / 20)
				check.equal(times[1], 1 / 20)
				check.equal(math.abs(times[20] - 1) < 1e-9, true)
				-- Many small frames give the same count (1/64 adds up to exactly 1).
				for _ = 1, 64 do
					t:advance(1 / 64)
				end
				check.equal(steps, 40)
			end)
			return nil
		end)

		test.case("fixed catches up after a hitch, up to maxSteps, and drops the rest", function()
			local clock = lateClock()
			late = clock
			local steps = 0
			local timer = Scheduler.fixed(0.05, function()
				steps += 1
			end, { maxSteps = 5 })

			clock.deliver(0.05)
			check.equal(steps, 1)
			-- A 0.12 s hitch: two steps were missed, both run now.
			clock.deliver(0.17)
			check.equal(steps, 3)
			-- A 0.5 s hitch: ten steps are due, five run, the rest are dropped.
			clock.deliver(0.67)
			check.equal(steps, 8)
			-- The loop carries on from the next step after now (0.7), not from the dropped ones.
			clock.deliver(0.69)
			check.equal(steps, 8)
			clock.deliver(0.71)
			check.equal(steps, 9)
			check.equal(clock.pending(), 1)
			timer:cancel()
			check.equal(clock.pending(), 0)
			return nil
		end)

		test.case("every runs once after a hitch and keeps its phase through small delays", function()
			local clock = lateClock()
			late = clock
			local runs: { number } = {}
			local timer = Scheduler.every(1, function()
				table.insert(runs, Clock.now())
			end)
			clock.deliver(1.02) -- a frame late
			clock.deliver(2) -- still due at 2: phase kept
			check.equal(#runs, 2)
			clock.deliver(5.5) -- three intervals missed: runs once
			check.equal(#runs, 3)
			clock.deliver(6) -- next is 6.5, a full interval after the late run
			check.equal(#runs, 3)
			clock.deliver(6.5)
			check.equal(#runs, 4)
			timer:cancel()
			return nil
		end)

		test.case("pause keeps the time left and resume continues from it", function()
			Hydrogen.test({}, function(t)
				local runs: { number } = {}
				local timer = Scheduler.every(10, function()
					table.insert(runs, Clock.now())
				end)
				t:advance(4)
				timer:pause()
				check.equal(timer.paused, true)
				check.equal(Scheduler.count(), 0)
				t:advance(100)
				check.equal(#runs, 0)
				timer:resume()
				check.equal(timer.paused, false)
				t:advance(5.9)
				check.equal(#runs, 0)
				t:advance(0.1)
				check.equal(#runs, 1)
				check.equal(runs[1], 110)
				t:advance(10)
				check.equal(#runs, 2)

				local fixedSteps = 0
				local loop = Scheduler.fixed(1, function()
					fixedSteps += 1
				end)
				t:advance(2.5)
				loop:pause()
				t:advance(50)
				loop:resume()
				t:advance(0.5)
				check.equal(fixedSteps, 3)
				loop:cancel()
				timer:cancel()
				timer:resume()
				check.equal(timer.active, false)
			end)
			return nil
		end)

		test.case("jitter spreads intervals between seconds and seconds + jitter", function()
			Hydrogen.test({}, function(t)
				local runs: { number } = {}
				Scheduler.every(10, function()
					table.insert(runs, Clock.now())
				end, { jitter = 2 })
				t:advance(100)
				check.equal(#runs >= 8 and #runs <= 10, true)
				local previous = 0
				for _, at in runs do
					local gap = at - previous
					check.equal(gap >= 10 and gap <= 12, true)
					previous = at
				end
			end)
			return nil
		end)

		test.case("bind cancels with a scope, or with a system's and player's scopes", function()
			local scope = Hydrogen.Scope.new()
			local timer = Scheduler.every(1, function() end):bind(scope)
			scope:destroy()
			check.equal(timer.active, false)

			local systemRuns = 0
			local playerRuns = 0
			local playerTimer: Hydrogen.Timer? = nil
			local Regen = Hydrogen.define("SchedulerRegen", function()
				local Regen = {}
				function Regen:start()
					Scheduler.every(1, function()
						systemRuns += 1
					end):bind(self)
				end
				function Regen:playerAdded(player: Player)
					playerTimer = Scheduler.every(1, function()
						playerRuns += 1
					end):bind(self, player)
				end
				return Regen
			end)

			Hydrogen.test({ systems = { Regen }, players = { "Alice" } }, function(t, alice)
				t:advance(3)
				check.equal(systemRuns, 3)
				check.equal(playerRuns, 3)
				t:leave(alice)
				check.equal((playerTimer :: Hydrogen.Timer).active, false)
				t:advance(3)
				check.equal(systemRuns, 6)
				check.equal(playerRuns, 3)
			end)
			-- Stopping the app destroyed the system scope.
			check.equal(Scheduler.count(), 0)
			check.should_error(function()
				Scheduler.after(1, function() end):bind(nil)
				return nil
			end)
			return nil
		end)

		test.case("timers left on a fake clock are dropped when it's restored", function()
			local ran = false
			Hydrogen.test({}, function()
				Scheduler.after(5, function()
					ran = true
				end)
				check.equal(Scheduler.count(), 1)
			end)
			check.equal(Scheduler.count(), 0)
			Hydrogen.test({}, function(t)
				t:advance(10)
				check.equal(ran, false)
				-- And the next test's timers work normally.
				local fired = false
				Scheduler.after(1, function()
					fired = true
				end)
				t:advance(1)
				check.equal(fired, true)
			end)
			return nil
		end)

		test.case("debounce runs once after calls stop, with the last arguments", function()
			Hydrogen.test({}, function(t)
				local saved: { string } = {}
				local save, cancel = Scheduler.debounce(0.5, function(name: string)
					table.insert(saved, name)
				end)
				save("a")
				t:advance(0.3)
				save("b")
				t:advance(0.3)
				check.equal(#saved, 0)
				t:advance(0.2)
				check.equal(table.concat(saved, ","), "b")
				check.equal(Scheduler.count(), 0)

				save("c")
				cancel()
				t:advance(1)
				check.equal(#saved, 1)
				save("d")
				t:advance(0.5)
				check.equal(table.concat(saved, ","), "b,d")
			end)
			return nil
		end)

		test.case("throttle runs at once, then merges calls into one at the end of the window", function()
			Hydrogen.test({}, function(t)
				local sent: { number } = {}
				local send, cancel = Scheduler.throttle(1, function(value: number)
					table.insert(sent, value)
				end)
				send(1)
				check.equal(table.concat(sent, ","), "1")
				send(2)
				send(3)
				check.equal(#sent, 1)
				t:advance(1)
				check.equal(table.concat(sent, ","), "1,3")
				t:advance(1)
				send(4)
				check.equal(table.concat(sent, ","), "1,3,4")
				send(5)
				cancel()
				t:advance(2)
				check.equal(table.concat(sent, ","), "1,3,4")
			end)
			return nil
		end)

		test.case("bad arguments fail with [HYDROGEN] errors", function()
			local function fails(fn: () -> (), text: string)
				local ok, err = pcall(fn)
				check.equal(ok, false)
				check.equal(contains(tostring(err), text), true)
			end
			fails(function()
				Scheduler.every(0, function() end)
			end, "[HYDROGEN] Scheduler.every expects seconds > 0, got 0")
			fails(function()
				Scheduler.after(-1, function() end)
			end, "[HYDROGEN] Scheduler.after expects seconds >= 0, got -1")
			fails(function()
				Scheduler.fixed(0 / 0, function() end)
			end, "Scheduler.fixed expects seconds > 0")
			fails(function()
				Scheduler.after(1, nil :: any)
			end, "[HYDROGEN] Scheduler.after expects a function, got nil")
			fails(function()
				Scheduler.fixed(1, function() end, { maxSteps = 0 })
			end, "maxSteps must be a whole number >= 1")
			fails(function()
				Scheduler.every(1, function() end, { jitter = -1 })
			end, "jitter must be a number >= 0")
			check.equal(Scheduler.count(), 0)
			return nil
		end)
	end)
end
