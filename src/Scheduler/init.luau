--!strict

-- Timers tied to lifetimes: after, every, a fixed-timestep loop, debounce and throttle.
--
-- Every timer lives in one min-heap ordered by due time. One Clock.delay is armed for the
-- earliest timer, so a thousand timers cost one waiting thread, nothing runs per frame, and
-- with no timers nothing is armed at all. Because the wake-up is a Clock.delay, the test
-- harness's fake clock runs each timer at its own due time, interleaved with other delays.

local Clock = require("./Clock")
local Log = require("./Log")
local Scope = require("./Scope")

export type Timer = {
	-- False once cancelled, or once an after timer has run.
	read active: boolean,
	-- True between pause() and resume().
	read paused: boolean,
	-- Stops the timer for good. Calling it again does nothing. Scope:add cleans timers with it.
	cancel: (self: Timer) -> (),
	-- Stops the countdown, keeping the time left. Does nothing if paused or inactive.
	pause: (self: Timer) -> (),
	-- Restarts the countdown with the time that was left. Does nothing unless paused.
	resume: (self: Timer) -> (),
	-- Cancels the timer when a lifetime ends: a Hydrogen.Scope, or a system (and player),
	-- meaning Scope.of(system, player). Returns the timer.
	bind: (self: Timer, owner: any, player: Player?) -> Timer,
}

export type EveryOptions = {
	-- Adds a random 0..jitter seconds to each interval, so many timers made together spread out.
	jitter: number?,
}

export type FixedOptions = {
	-- Most steps run in one catch-up after a hitch. Steps beyond it are dropped. Defaults to 5.
	maxSteps: number?,
}

type Kind = "after" | "every" | "fixed"

type TimerInternal = {
	active: boolean,
	paused: boolean,
	kind: Kind,
	seconds: number,
	callback: (...any) -> (),
	-- When it runs next, and the order it was scheduled in (ties run oldest first).
	due: number,
	order: number,
	-- Position in the heap, 0 while not in it.
	slot: number,
	-- Seconds left while paused.
	remaining: number,
	-- True while its callback runs, including while it is yielded.
	running: boolean,
	warnedBusy: boolean,
	-- every: when it last ran (or was created). fixed: step k is due at start + k * seconds.
	last: number,
	start: number,
	count: number,
	jitter: number,
	maxSteps: number,
	-- Shown in warnings instead of kind(seconds), for debounce and throttle.
	label: string?,
}

local Methods = {}
local metatable = { __index = Methods }

--------------------------------------------------------------------------------
-- The heap
--------------------------------------------------------------------------------

local heap: { TimerInternal } = {}
local scheduled = 0
-- The Clock.delay thread waiting for the earliest timer, and when it wakes.
local armed: thread? = nil
local armedAt = 0
-- True while due timers run; arming waits until they're done.
local draining = false
-- The Clock.delay the heap was built on. A fake clock installed or restored since then
-- abandons the heap, as the fake clock abandons its own waiting threads.
local clockKey: any = nil

local function before(a: TimerInternal, b: TimerInternal): boolean
	return a.due < b.due or (a.due == b.due and a.order < b.order)
end

local function swap(i: number, j: number)
	local a, b = heap[i], heap[j]
	heap[i], heap[j] = b, a
	a.slot = j
	b.slot = i
end

local function up(i: number)
	while i > 1 do
		local parent = i // 2
		if not before(heap[i], heap[parent]) then
			break
		end
		swap(i, parent)
		i = parent
	end
end

local function down(i: number)
	local size = #heap
	while true do
		local left = i * 2
		local smallest = i
		if left <= size and before(heap[left], heap[smallest]) then
			smallest = left
		end
		if left + 1 <= size and before(heap[left + 1], heap[smallest]) then
			smallest = left + 1
		end
		if smallest == i then
			return
		end
		swap(i, smallest)
		i = smallest
	end
end

local function insert(timer: TimerInternal)
	table.insert(heap, timer)
	timer.slot = #heap
	up(timer.slot)
end

local function remove(timer: TimerInternal)
	local i = timer.slot
	if i == 0 then
		return
	end
	timer.slot = 0
	local last = table.remove(heap) :: TimerInternal
	if last ~= timer then
		heap[i] = last
		last.slot = i
		up(i)
		down(last.slot)
	end
end

-- Drops the heap if the clock changed under it (a test installed or restored a fake clock).
local function sync()
	local key = Clock.delay
	if key == clockKey then
		return
	end
	clockKey = key
	for _, timer in heap do
		timer.slot = 0
		timer.active = false
	end
	table.clear(heap)
	armed = nil
end

--------------------------------------------------------------------------------
-- Running callbacks
--------------------------------------------------------------------------------

-- Callbacks run on a reused thread. One that yields keeps that thread, and the next callback
-- gets a new one, so a yielding callback never holds up other timers.
local freeRunner: thread? = nil

local function describe(timer: TimerInternal): string
	return timer.label or `{timer.kind}({timer.seconds})`
end

local function runCallback(timer: TimerInternal, ...: any)
	local acquired = freeRunner
	freeRunner = nil
	timer.running = true
	local ok, err = xpcall(timer.callback, debug.traceback, ...)
	timer.running = false
	if not ok then
		Log.warn(`[HYDROGEN] Scheduler: {describe(timer)} callback failed: {err}`)
	end
	freeRunner = acquired
end

local function runnerLoop()
	while true do
		runCallback(coroutine.yield())
	end
end

local function run(timer: TimerInternal, ...: any)
	if freeRunner == nil then
		local thread = coroutine.create(runnerLoop)
		coroutine.resume(thread)
		freeRunner = thread
	end
	task.spawn(freeRunner :: thread, timer, ...)
end

-- A repeating timer whose last run yielded and hasn't finished skips this run.
local function busy(timer: TimerInternal): boolean
	if not timer.running then
		return false
	end
	if not timer.warnedBusy then
		timer.warnedBusy = true
		Log.warn(
			`[HYDROGEN] Scheduler: {describe(timer)} skipped a run because its last run yielded and is still running. Don't yield in repeating timers; task.spawn the slow part`
		)
	end
	return true
end

--------------------------------------------------------------------------------
-- Waking up
--------------------------------------------------------------------------------

local wake: () -> ()

local function arm()
	if draining then
		return
	end
	local top = heap[1]
	if top == nil then
		if armed then
			Clock.cancel(armed)
			armed = nil
		end
		return
	end
	if armed and armedAt <= top.due then
		return
	end
	if armed then
		Clock.cancel(armed)
	end
	armedAt = top.due
	armed = Clock.delay(math.max(top.due - Clock.now(), 0), wake)
end

local function fireTimer(timer: TimerInternal, now: number)
	local kind = timer.kind
	if kind == "after" then
		timer.active = false
		run(timer)
	elseif kind == "every" then
		-- Keeps its phase through small delays; after missing a whole interval it starts over
		-- from now instead of running the missed ones in a burst.
		local due = timer.due + timer.seconds
		if due <= now then
			due = now + timer.seconds
		end
		if timer.jitter > 0 then
			due += math.random() * timer.jitter
		end
		timer.due = due
		insert(timer)
		if not busy(timer) then
			local elapsed = now - timer.last
			timer.last = now
			run(timer, elapsed)
		end
	else
		local step = timer.seconds
		local start = timer.start
		local count = timer.count
		local steps = 0
		while start + (count + 1) * step <= now and steps < timer.maxSteps do
			count += 1
			steps += 1
		end
		if start + (count + 1) * step <= now then
			-- Too far behind: drop the backlog rather than spiral.
			count = math.max(count, math.floor((now - start) / step))
			while start + (count + 1) * step <= now do
				count += 1
			end
		end
		timer.count = count
		timer.due = start + (count + 1) * step
		insert(timer)
		for _ = 1, steps do
			if not timer.active or timer.paused or busy(timer) then
				break
			end
			run(timer, step)
		end
	end
end

wake = function()
	if armed ~= coroutine.running() then
		return
	end
	armed = nil
	sync()

	draining = true
	local now = Clock.now()
	-- Timers made while these run wait for the next wake, so after(0) in a callback can't loop here.
	local limit = scheduled
	while true do
		local top = heap[1]
		if top == nil or top.due > now or top.order > limit then
			break
		end
		remove(top)
		fireTimer(top, now)
	end
	draining = false
	arm()
end

--------------------------------------------------------------------------------
-- Timers
--------------------------------------------------------------------------------

local function checkSeconds(what: string, seconds: any, allowZero: boolean)
	local valid = type(seconds) == "number" and seconds == seconds and seconds < math.huge
	if valid and (seconds > 0 or (allowZero and seconds == 0)) then
		return
	end
	local expected = if allowZero then "seconds >= 0" else "seconds > 0"
	error(`[HYDROGEN] Scheduler.{what} expects {expected}, got {tostring(seconds)}`, 3)
end

local function checkCallback(what: string, callback: any)
	if type(callback) ~= "function" then
		error(`[HYDROGEN] Scheduler.{what} expects a function, got {typeof(callback)}`, 3)
	end
end

local function schedule(timer: TimerInternal, due: number)
	scheduled += 1
	timer.order = scheduled
	timer.due = due
	insert(timer)
	arm()
end

local function newTimer(kind: Kind, seconds: number, callback: (...any) -> ()): TimerInternal
	sync()
	local now = Clock.now()
	local timer: TimerInternal = setmetatable({
		active = true,
		paused = false,
		kind = kind,
		seconds = seconds,
		callback = callback,
		due = 0,
		order = 0,
		slot = 0,
		remaining = 0,
		running = false,
		warnedBusy = false,
		last = now,
		start = now,
		count = 0,
		jitter = 0,
		maxSteps = 0,
		label = nil,
	}, metatable) :: any
	return timer
end

function Methods.cancel(self: TimerInternal)
	sync()
	if not self.active then
		return
	end
	self.active = false
	self.paused = false
	remove(self)
	if heap[1] == nil then
		arm()
	end
end

function Methods.pause(self: TimerInternal)
	sync()
	if not self.active or self.paused then
		return
	end
	self.paused = true
	self.remaining = math.max(self.due - Clock.now(), 0)
	remove(self)
	if heap[1] == nil then
		arm()
	end
end

function Methods.resume(self: TimerInternal)
	if not self.active or not self.paused then
		return
	end
	sync()
	self.paused = false
	local now = Clock.now()
	local due = now + self.remaining
	if self.kind == "fixed" then
		-- Steps carry on from now; the paused time is not caught up.
		self.start = due - self.seconds
		self.count = 0
	elseif self.kind == "every" then
		self.last = now - (self.seconds - self.remaining)
	end
	schedule(self, due)
end

function Methods.bind(self: TimerInternal, owner: any, player: Player?): TimerInternal
	local scope: any
	if type(owner) == "table" and getmetatable(owner) == getmetatable(Scope._closed :: any) then
		scope = owner
	elseif owner == nil then
		error(`[HYDROGEN] timer:bind expects a scope or a system, got nil`, 2)
	else
		scope = Scope.of(owner, player)
	end
	scope:add(self)
	return self
end

local Scheduler = {}

-- Runs callback once, after seconds.
function Scheduler.after(seconds: number, callback: () -> ()): Timer
	checkSeconds("after", seconds, true)
	checkCallback("after", callback)
	local timer = newTimer("after", seconds, callback)
	schedule(timer, Clock.now() + seconds)
	return timer :: any
end

-- Runs callback(elapsed) every seconds, first after one interval. elapsed is the time since
-- the last run. A run late by more than an interval doesn't add runs to catch up.
function Scheduler.every(seconds: number, callback: (elapsed: number) -> (), options: EveryOptions?): Timer
	checkSeconds("every", seconds, false)
	checkCallback("every", callback)
	local jitter = options and options.jitter or 0
	if type(jitter) ~= "number" or jitter < 0 or jitter ~= jitter then
		error(`[HYDROGEN] Scheduler.every: jitter must be a number >= 0, got {tostring(jitter)}`, 2)
	end
	local timer = newTimer("every", seconds, callback :: any)
	timer.jitter = jitter
	schedule(timer, Clock.now() + seconds + if jitter > 0 then math.random() * jitter else 0)
	return timer :: any
end

-- A fixed-timestep loop: callback(seconds) runs once per step of exactly seconds, at
-- start + k * seconds. After a hitch it runs the missed steps back to back, up to maxSteps,
-- and drops the rest.
function Scheduler.fixed(seconds: number, callback: (dt: number) -> (), options: FixedOptions?): Timer
	checkSeconds("fixed", seconds, false)
	checkCallback("fixed", callback)
	local maxSteps = options and options.maxSteps or 5
	if type(maxSteps) ~= "number" or maxSteps < 1 or maxSteps % 1 ~= 0 then
		error(`[HYDROGEN] Scheduler.fixed: maxSteps must be a whole number >= 1, got {tostring(maxSteps)}`, 2)
	end
	local timer = newTimer("fixed", seconds, callback :: any)
	timer.maxSteps = maxSteps
	schedule(timer, timer.start + seconds)
	return timer :: any
end

-- Returns call and cancel. call(...) runs callback(...) once seconds have passed without
-- another call, with the last call's arguments. cancel drops a pending run; add it to a scope.
function Scheduler.debounce<A...>(seconds: number, callback: (A...) -> ()): ((A...) -> (), () -> ())
	checkSeconds("debounce", seconds, true)
	checkCallback("debounce", callback)
	local args: { n: number, [number]: any }? = nil
	local timer: TimerInternal? = nil

	local function flush()
		local pending = args
		args = nil
		if pending then
			local run: (...any) -> () = callback :: any
			run(table.unpack(pending, 1, pending.n))
		end
	end

	local function call(...: any)
		args = table.pack(...)
		local current = timer
		if current and current.active then
			sync()
			if current.active then
				remove(current)
				schedule(current, Clock.now() + seconds)
				return
			end
		end
		local created = newTimer("after", seconds, flush)
		created.label = `debounce({seconds})`
		timer = created
		schedule(created, Clock.now() + seconds)
	end

	local function cancel()
		args = nil
		if timer then
			Methods.cancel(timer)
			timer = nil
		end
	end

	return call :: any, cancel
end

-- Returns call and cancel. call(...) runs callback(...) right away at most once per seconds;
-- calls in between are merged into one run at the end of the window, with the last arguments.
function Scheduler.throttle<A...>(seconds: number, callback: (A...) -> ()): ((A...) -> (), () -> ())
	checkSeconds("throttle", seconds, false)
	checkCallback("throttle", callback)
	local lastRun: number? = nil
	local args: { n: number, [number]: any }? = nil
	local timer: TimerInternal? = nil

	local function trailing()
		timer = nil
		local pending = args
		args = nil
		if pending then
			lastRun = Clock.now()
			local run: (...any) -> () = callback :: any
			run(table.unpack(pending, 1, pending.n))
		end
	end

	local function call(...: any)
		local now = Clock.now()
		if timer and timer.active then
			args = table.pack(...)
			return
		end
		if lastRun == nil or now - lastRun >= seconds then
			lastRun = now
			local run: (...any) -> () = callback :: any
			run(...)
			return
		end
		args = table.pack(...)
		local created = newTimer("after", seconds, trailing)
		created.label = `throttle({seconds})`
		timer = created
		schedule(created, (lastRun :: number) + seconds)
	end

	local function cancel()
		args = nil
		if timer then
			Methods.cancel(timer)
			timer = nil
		end
	end

	return call :: any, cancel
end

-- Active timers waiting to run (paused ones not included). For tests that check nothing leaked.
function Scheduler.count(): number
	sync()
	return #heap
end

return Scheduler
