--!strict

-- Every time source Hydrogen and its kit modules use, in one place, so a test can swap in a
-- fake clock and run timeouts, refills, flushes and autosaves deterministically.
-- In a game the fields are the built-ins themselves, so calling Clock.now() costs what
-- os.clock() does. Look fields up when calling (Clock.now()), never cache them
-- (local now = Clock.now), or a fake installed later can't reach the call.

export type FakeClockOptions = {
	-- What Clock.now() starts at. Defaults to 0.
	now: number?,
	-- What Clock.time() starts at, in Unix seconds. Defaults to the real os.time().
	time: number?,
}

export type FakeClock = {
	-- Moves time forward: runs every timer due by then in order (Clock.now() reads each
	-- timer's due time while it runs), then fires heartbeat once with dt = seconds and
	-- resumes threads waiting for the next frame. advance(0) runs only what is due now.
	advance: (self: FakeClock, seconds: number) -> (),
	-- Advances to the next timer and runs it. Returns the seconds advanced, or nil if
	-- no timer is waiting.
	next: (self: FakeClock) -> number?,
	-- Timers (delays and timed waits) still waiting.
	pending: (self: FakeClock) -> number,
	now: (self: FakeClock) -> number,
	-- Puts the real clock back. Threads still waiting on the fake clock are never resumed.
	restore: (self: FakeClock) -> (),
}

type Timer = {
	at: number,
	-- Ties run in the order they were scheduled.
	order: number,
	thread: thread,
	-- A delay's arguments, or nil for a wait (resumed with the seconds waited).
	args: { [number]: any, n: number }?,
	since: number,
}

local Clock = {}

-- Seconds on a monotonic clock, for durations and cooldowns.
Clock.now = os.clock :: () -> number
-- Unix seconds, for dates and timestamps that are saved.
Clock.time = os.time :: () -> number
-- Yields for seconds (the next frame without them) and returns the seconds waited.
Clock.wait = task.wait :: (seconds: number?) -> number
-- Runs fn(...) after seconds in a new thread and returns that thread. Like task.delay, fn
-- can also be a suspended thread, which is resumed with the arguments.
Clock.delay = task.delay :: <A...>(seconds: number, fn: ((A...) -> ()) | thread, A...) -> thread
-- Stops a thread made by Clock.delay before it runs.
Clock.cancel = task.cancel :: (thread: thread) -> ()

-- Calls fn(dt) at the end of every frame. Returns a function that disconnects it.
function Clock.heartbeat(fn: (dt: number) -> ()): () -> ()
	local connection = game:GetService("RunService").Heartbeat:Connect(fn)
	return function()
		connection:Disconnect()
	end
end

-- Timers one advance may run before it decides something reschedules itself with no delay.
local MAX_TIMERS_PER_ADVANCE = 100000

local real = {
	now = Clock.now,
	time = Clock.time,
	wait = Clock.wait,
	delay = Clock.delay,
	cancel = Clock.cancel,
	heartbeat = Clock.heartbeat,
}

local installed: FakeClock? = nil

-- Installs a fake clock until its restore(). Time only moves when the test calls advance.
function Clock.fake(options: FakeClockOptions?): FakeClock
	if installed then
		error(`[HYDROGEN] A fake clock is already installed; restore it before installing another`, 2)
	end

	local now = (options and options.now) or 0
	local timeBase = (options and options.time) or os.time()
	local nowBase = now
	local timers: { Timer } = {}
	local scheduled = 0
	local frameWaiters: { { thread: thread, since: number } } = {}
	local listeners: { (dt: number) -> () } = {}

	local fake = {} :: FakeClock

	local function schedule(seconds: number, thread: thread, args: { [number]: any, n: number }?)
		scheduled += 1
		table.insert(timers, {
			at = now + math.max(seconds, 0),
			order = scheduled,
			thread = thread,
			args = args,
			since = now,
		})
	end

	-- The earliest due timer, removed from the list.
	local function takeDue(limit: number): Timer?
		local best: number? = nil
		for index, timer in timers do
			if timer.at <= limit then
				local current = best and timers[best]
				if not current or timer.at < current.at or (timer.at == current.at and timer.order < current.order) then
					best = index
				end
			end
		end
		if not best then
			return nil
		end
		return table.remove(timers, best)
	end

	local function run(timer: Timer)
		now = timer.at
		if coroutine.status(timer.thread) ~= "suspended" then
			return
		end
		if timer.args then
			task.spawn(timer.thread, table.unpack(timer.args, 1, timer.args.n))
		else
			task.spawn(timer.thread, now - timer.since)
		end
	end

	local function frame(dt: number)
		for _, listener in table.clone(listeners) do
			task.spawn(listener, dt)
		end
		local waiting = frameWaiters
		frameWaiters = {}
		for _, waiter in waiting do
			if coroutine.status(waiter.thread) == "suspended" then
				task.spawn(waiter.thread, now - waiter.since)
			end
		end
	end

	function fake:advance(seconds: number)
		if type(seconds) ~= "number" or seconds < 0 or seconds ~= seconds then
			error(`[HYDROGEN] advance expects a non-negative number of seconds`, 2)
		end
		local target = now + seconds
		local ran = 0
		while true do
			local timer = takeDue(target)
			if not timer then
				break
			end
			ran += 1
			if ran > MAX_TIMERS_PER_ADVANCE then
				error(`[HYDROGEN] advance ran {MAX_TIMERS_PER_ADVANCE} timers without reaching the target time; is a timer rescheduling itself with no delay?`, 2)
			end
			run(timer)
		end
		now = target
		frame(seconds)
	end

	function fake:next(): number?
		local timer = takeDue(math.huge)
		if not timer then
			return nil
		end
		local began = now
		run(timer)
		return now - began
	end

	function fake:pending(): number
		return #timers
	end

	function fake:now(): number
		return now
	end

	function fake:restore()
		if installed ~= fake then
			return
		end
		installed = nil
		table.clear(timers)
		table.clear(frameWaiters)
		table.clear(listeners)
		for key, value in real do
			(Clock :: any)[key] = value
		end
	end

	Clock.now = function(): number
		return now
	end

	Clock.time = function(): number
		return math.floor(timeBase + now - nowBase)
	end

	Clock.wait = function(seconds: number?): number
		local thread = coroutine.running()
		if seconds == nil or seconds <= 0 then
			table.insert(frameWaiters, { thread = thread, since = now })
		else
			schedule(seconds, thread, nil)
		end
		return coroutine.yield()
	end

	Clock.delay = function<A...>(seconds: number, fn: ((A...) -> ()) | thread, ...: A...): thread
		local thread = if type(fn) == "thread" then fn else coroutine.create(fn)
		schedule(seconds, thread, table.pack(...))
		return thread
	end :: any

	Clock.cancel = function(thread: thread)
		for index, timer in timers do
			if timer.thread == thread then
				table.remove(timers, index)
				if coroutine.status(thread) == "suspended" then
					coroutine.close(thread)
				end
				return
			end
		end
		-- Not one of ours: made by the real scheduler before the fake was installed.
		real.cancel(thread)
	end

	Clock.heartbeat = function(fn: (dt: number) -> ()): () -> ()
		table.insert(listeners, fn)
		return function()
			local index = table.find(listeners, fn)
			if index then
				table.remove(listeners, index)
			end
		end
	end

	installed = fake
	return fake
end

-- The installed fake clock, if a test installed one.
function Clock.active(): FakeClock?
	return installed
end

return Clock
