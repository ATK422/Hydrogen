--!strict

-- Network stats per network object, collected by a global middleware (what arrives and what is
-- sent) and the network's delivery observer (what reached a listener or handler). Nothing is
-- installed until the first enable or lease, and disable removes it all again, so a game that
-- never turns stats on pays nothing.

local Clock = require("../Clock")
local Middleware = require("../Network/Middleware")
local Runtime = require("../Network/Runtime")

export type Kind = Middleware.Kind

-- Seconds. average and max cover every call since stats started or were reset.
export type Latency = {
	count: number,
	last: number,
	average: number,
	max: number,
}

export type NetStat = {
	name: string,
	kind: Kind,
	-- Messages since stats started: events, function requests and responses. A server event sent
	-- to three players counts three.
	inTotal: number,
	outTotal: number,
	-- Messages during the last full second.
	inPerSecond: number,
	outPerSecond: number,
	-- Estimated payload bytes (see estimate below), in total and during the last full second.
	inBytes: number,
	outBytes: number,
	inBytesPerSecond: number,
	outBytesPerSecond: number,
	-- Events and requests that arrived but never reached a listener or handler: dropped by
	-- middleware (Hydrogen.rateLimit, Hydrogen.DROP) or failing the schema.
	dropped: number,
	-- Round trips of calls this side made (a clientFunction on a client, a serverFunction on the server).
	latency: Latency?,
	-- Time this side's handler took to answer.
	handler: Latency?,
}

type Timing = {
	count: number,
	total: number,
	last: number,
	max: number,
}

type Record = {
	name: string,
	kind: Kind,
	inTotal: number,
	outTotal: number,
	inBytes: number,
	outBytes: number,
	-- Counted in the current window.
	inWindow: number,
	outWindow: number,
	inBytesWindow: number,
	outBytesWindow: number,
	-- The last full window.
	inRate: number,
	outRate: number,
	inBytesRate: number,
	outBytesRate: number,
	arrived: number,
	delivered: number,
	latency: Timing?,
	handler: Timing?,
}

local WINDOW = 1
-- Values walked per message. Past it, each remaining value counts as a number, so a huge table
-- costs a bounded amount of work to estimate.
local VALUE_BUDGET = 256
-- Hydrogen's network id in front of every message.
local MESSAGE_OVERHEAD = 9

local Stats = {}

local enabled = false
-- Turned on by enable(), as opposed to a lease from the overlay.
local manual = false
local leaseUntil = 0
local leaseTimer: thread? = nil
local records: { [string]: Record } = {}
local windowStart = 0
local removeMiddleware: (() -> ())? = nil
-- The observer that was installed before ours (Hydrogen.test's), called after ours.
local chained: ((Runtime.Observation) -> ())? = nil
-- Calls in flight from this side, by the calling thread and the function's name.
local calls: { [thread]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any
-- Handlers running on this side, by the observation the network reported them with.
local handlers: { [Runtime.Observation]: number } = setmetatable({}, { __mode = "k" }) :: any

local budget = 0

-- Roughly what Roblox serializes for a value: the same rules the network uses for its
-- unreliable size limit. Plain values, as middleware sees them, so :Encode() objects are
-- estimated larger than the buffer they actually send.
local function estimate(value: any, depth: number): number
	budget -= 1
	if budget < 0 then
		return 9
	end

	local kind = type(value)
	if kind == "number" then
		return 9
	elseif kind == "string" then
		return #value + 4
	elseif kind == "boolean" or kind == "nil" then
		return 2
	elseif kind == "table" then
		if depth > 16 then
			return 4
		end
		local size = 4
		for key, entry in value do
			size += estimate(key, depth + 1) + estimate(entry, depth + 1)
		end
		return size
	elseif kind == "buffer" then
		return buffer.len(value) + 4
	end

	local roblox = typeof(value)
	if roblox == "Vector3" then
		return 13
	elseif roblox == "CFrame" then
		return 49
	end
	return 16
end

local function messageBytes(...: any): number
	budget = VALUE_BUDGET
	local size = MESSAGE_OVERHEAD
	for index = 1, select("#", ...) do
		size += estimate((select(index, ...)), 0)
	end
	return size
end

-- Moves to the next window once a second has passed. Called on every message, so it is one
-- comparison until then.
local function roll(now: number)
	local elapsed = now - windowStart
	if elapsed < WINDOW and elapsed >= 0 then
		return
	end

	-- More than one window with no message in between, or a clock that jumped back (a test's
	-- fake clock came or went): the last full window had nothing in it.
	local stale = elapsed >= 2 * WINDOW or elapsed < 0
	for _, record in records do
		if stale then
			record.inRate, record.outRate, record.inBytesRate, record.outBytesRate = 0, 0, 0, 0
		else
			record.inRate = record.inWindow / WINDOW
			record.outRate = record.outWindow / WINDOW
			record.inBytesRate = record.inBytesWindow / WINDOW
			record.outBytesRate = record.outBytesWindow / WINDOW
		end
		record.inWindow, record.outWindow, record.inBytesWindow, record.outBytesWindow = 0, 0, 0, 0
	end
	windowStart = if stale then now else windowStart + WINDOW
end

local function recordFor(name: string, kind: Kind): Record
	local record = records[name]
	if not record then
		record = {
			name = name,
			kind = kind,
			inTotal = 0,
			outTotal = 0,
			inBytes = 0,
			outBytes = 0,
			inWindow = 0,
			outWindow = 0,
			inBytesWindow = 0,
			outBytesWindow = 0,
			inRate = 0,
			outRate = 0,
			inBytesRate = 0,
			outBytesRate = 0,
			arrived = 0,
			delivered = 0,
			latency = nil,
			handler = nil,
		}
		records[name] = record
	end
	return record
end

local function time(timing: Timing?, seconds: number): Timing
	local result = timing or { count = 0, total = 0, last = 0, max = 0 }
	result.count += 1
	result.total += seconds
	result.last = seconds
	result.max = math.max(result.max, seconds)
	return result
end

local install: () -> ()

local function collect(context: Middleware.Context, ...: any): ...any
	if not enabled then
		return ...
	end
	-- Middleware added after ours would run before it on incoming messages and could drop
	-- them unseen, so ours moves back to the end of the chain.
	install()

	local now = Clock.now()
	roll(now)
	local record = recordFor(context.name, context.kind)
	local bytes = messageBytes(...)

	if context.direction == "outgoing" then
		local count = if context.players then #context.players else 1
		record.outTotal += count
		record.outWindow += count
		record.outBytes += bytes * count
		record.outBytesWindow += bytes * count
		if context.payload == "request" then
			local thread = coroutine.running()
			local started = calls[thread]
			if not started then
				started = {}
				calls[thread] = started
			end
			started[context.name] = now
		end
	else
		record.inTotal += 1
		record.inWindow += 1
		record.inBytes += bytes
		record.inBytesWindow += bytes
		if context.payload == "response" then
			local started = calls[coroutine.running()]
			local began = started and started[context.name]
			if began then
				(started :: any)[context.name] = nil
				record.latency = time(record.latency, now - began)
			end
		else
			record.arrived += 1
		end
	end

	return ...
end

local function observe(observation: Runtime.Observation)
	if enabled then
		local record = records[observation.name]
		if record then
			if observation.returns == nil then
				record.delivered += 1
				if observation.kind == "ClientFunction" or observation.kind == "ServerFunction" then
					handlers[observation] = Clock.now()
				end
			else
				local began = handlers[observation]
				if began then
					handlers[observation] = nil
					record.handler = time(record.handler, Clock.now() - began)
				end
			end
		end
	end

	local previous = chained
	if previous then
		previous(observation)
	end
end

install = function()
	if Runtime.Observer ~= observe then
		-- Something replaced ours (a test harness opened): keep it, ahead of what it replaced.
		chained = Runtime.Observer
		Runtime.Observer = observe
	end
	local global = Middleware.global
	if global[#global] ~= collect then
		if removeMiddleware then
			removeMiddleware()
		end
		removeMiddleware = Middleware.use(collect)
	end
end

local function start()
	if enabled then
		return
	end
	enabled = true
	windowStart = Clock.now()
	install()
end

local function stop()
	if not enabled then
		return
	end
	enabled = false
	if removeMiddleware then
		removeMiddleware()
		removeMiddleware = nil
	end
	-- If something installed its own observer over ours, ours stays in its chain and passes through.
	if Runtime.Observer == observe then
		Runtime.Observer = chained
		chained = nil
	end
	table.clear(calls)
	table.clear(handlers)
end

local function cancelLease()
	leaseUntil = 0
	local timer = leaseTimer
	leaseTimer = nil
	if timer and coroutine.status(timer) == "suspended" then
		Clock.cancel(timer)
	end
end

local function scheduleLeaseEnd()
	leaseTimer = Clock.delay(math.max(leaseUntil - Clock.now(), 0), function()
		leaseTimer = nil
		if manual or not enabled then
			return
		end
		if Clock.now() < leaseUntil then
			scheduleLeaseEnd()
		else
			stop()
		end
	end)
end

-- Collects until disable(), whoever else leases.
function Stats.enable()
	manual = true
	cancelLease()
	start()
end

function Stats.disable()
	manual = false
	cancelLease()
	stop()
end

function Stats.enabled(): boolean
	return enabled
end

-- Collects for at least the next `seconds`, then stops unless leased again or enabled. The
-- overlay and the server's debug requests use this, so stats run only while someone is looking.
function Stats.lease(seconds: number)
	if manual then
		return
	end
	leaseUntil = math.max(leaseUntil, Clock.now() + seconds)
	start()
	if not leaseTimer then
		scheduleLeaseEnd()
	end
end

-- Forgets everything counted so far. Collection carries on if it was on.
function Stats.reset()
	table.clear(records)
	table.clear(calls)
	table.clear(handlers)
	windowStart = Clock.now()
end

local function latencyOf(timing: Timing?): Latency?
	if not timing then
		return nil
	end
	return {
		count = timing.count,
		last = timing.last,
		average = timing.total / timing.count,
		max = timing.max,
	}
end

-- A copy of every object's numbers, by network name. Empty until stats have run.
function Stats.snapshot(): { [string]: NetStat }
	local snapshot: { [string]: NetStat } = {}
	if next(records) == nil then
		return snapshot
	end

	roll(Clock.now())
	for name, record in records do
		snapshot[name] = {
			name = name,
			kind = record.kind,
			inTotal = record.inTotal,
			outTotal = record.outTotal,
			inPerSecond = record.inRate,
			outPerSecond = record.outRate,
			inBytes = record.inBytes,
			outBytes = record.outBytes,
			inBytesPerSecond = record.inBytesRate,
			outBytesPerSecond = record.outBytesRate,
			dropped = math.max(record.arrived - record.delivered, 0),
			latency = latencyOf(record.latency),
			handler = latencyOf(record.handler),
		}
	end
	return snapshot
end

-- The estimate for one message's values, for tests and docs.
Stats.estimate = messageBytes

-- For tests: everything off and forgotten.
function Stats._reset()
	Stats.disable()
	Stats.reset()
	chained = nil
end

return Stats
