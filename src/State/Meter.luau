--!strict

-- A number that moves at a steady rate between a min and a max: stamina, mana, hunger, heat.
-- What is stored and sent is a segment, (value, rate, min, max, at): the value at server time
-- `at` and how fast it moves from there. Each side works the value out in get(), so time passing
-- costs nothing and sends nothing; only set, add, setRate, setRange and sync send a segment.
-- Timestamps are Clock.serverNow(), which server and clients agree on.
--
-- Three things live on one side only, in cell.aux: a client's predicted segment, which shows
-- instead of the received one until the next one arrives or it times out, onLimit listeners
-- with the one timer that fires when the value reaches a limit, and on the server, for meters
-- with a history option, the segments the current one replaced, so getAt can read the past.

local Clock = require("../Clock")
local Log = require("../Log")
local Runtime = require("../Network/Runtime")
local Store = require("./Store")

type Def = Store.Def
type Cell = Store.Cell

export type Limit = "min" | "max"

export type Segment = {
	value: number,
	rate: number,
	min: number,
	max: number,
	-- Server time the value was at value.
	at: number,
	-- Server cells: the initial rate has been applied (see start).
	started: boolean,
}

-- A meter definition's settings, checked by State.meter / State.playerMeter.
export type Config = {
	min: number,
	max: number,
	value: number,
	rate: number,
	predict: boolean,
	predictTimeout: number,
	-- Seconds of past segments the server keeps for getAt. 0: none kept, getAt errors.
	history: number,
	-- What a replica shows before anything arrives: the initial value, at rest.
	resting: Segment,
}

type Aux = {
	predicted: Segment?,
	predictTimer: thread?,
	listeners: { (limit: Limit) -> () }?,
	timer: thread?,
	-- The limit the value was at when last checked, so each arrival is reported once.
	last: Limit?,
	-- Server, with a history option: the segments cell.data replaced, oldest first. Each was in
	-- force from its at until the next one's (or cell.data's).
	history: { Segment }?,
}

local SERVER = Store.SERVER
local LOCAL = Store.LOCAL

-- Within a microsecond of a limit counts as there, so a timer due at the crossing sees it
-- whatever the rounding.
local TOLERANCE = 1e-6

-- Past segments kept per meter (per player) whatever the history window, so a meter written
-- many times a second can't grow without bound: 60 writes a second for 2 seconds fits. Times
-- only the dropped ones covered read as nil, which refuses rather than guesses.
local MAX_HISTORY = 128

local Meter = {}

local function config(state: Def): Config
	return (state :: any).meter
end

--------------------------------------------------------------------------------
-- Time and extrapolation
--------------------------------------------------------------------------------

-- The server's own time. Under loopback, code running as a fake client sees that client's
-- skewed Clock.serverNow(); server writes and reads must not.
local function serverTime(): number
	local fake = Clock.active()
	if fake then
		return fake:serverNow()
	end
	return Clock.serverNow()
end

-- Server time as the side that owns ctx sees it.
local function timeIn(ctx: any): number
	if ctx == SERVER then
		return serverTime()
	end
	return Clock.serverNow()
end

local function clamp(value: number, min: number, max: number): number
	if value < min then
		return min
	elseif value > max then
		return max
	end
	return value
end

-- The value at server time t. Before `at` (a client whose clock runs behind the server's) it
-- holds at value rather than running backwards.
function Meter.valueAt(segment: Segment, t: number): number
	local rate = segment.rate
	if rate == 0 then
		return segment.value
	end
	local elapsed = t - segment.at
	if elapsed <= 0 then
		return segment.value
	end
	return clamp(segment.value + rate * elapsed, segment.min, segment.max)
end

local valueAt = Meter.valueAt

local function limitAt(segment: Segment, t: number): Limit?
	local value = valueAt(segment, t)
	local slack = math.abs(segment.rate) * TOLERANCE
	if value <= segment.min + slack then
		return "min"
	elseif value >= segment.max - slack then
		return "max"
	end
	return nil
end

-- Seconds from t until the value reaches the limit it is heading for, and that limit.
local function untilLimit(segment: Segment, t: number): (number?, Limit?)
	local rate = segment.rate
	if rate < 0 then
		local due = segment.at + (segment.value - segment.min) / -rate
		return math.max(due - t, 0), "min"
	elseif rate > 0 then
		local due = segment.at + (segment.max - segment.value) / rate
		return math.max(due - t, 0), "max"
	end
	return nil, nil
end

local function segment(value: number, rate: number, min: number, max: number, at: number): Segment
	return { value = value, rate = rate, min = min, max = max, at = at, started = true }
end

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

local function auxOf(cell: Cell): Aux
	local existing: Aux? = cell.aux
	if existing then
		return existing
	end
	local aux: Aux = {}
	cell.aux = aux
	return aux
end

-- What this side shows: the prediction if there is one, otherwise the received segment.
local function effective(cell: Cell): Segment
	local aux = cell.aux
	return (aux and aux.predicted) or cell.data
end

local function cancel(thread: thread?)
	if thread then
		-- A timer made under a fake clock that was restored since: nothing left to cancel.
		pcall(Clock.cancel, thread)
	end
end

-- Whether cell is still the one the state holds for ctx, so a timer outliving a reset, a
-- departure or a closed loopback does nothing.
local function live(state: Def, ctx: any, cell: Cell): boolean
	local key: any = nil
	if state.perPlayer then
		key = if ctx == SERVER then Store.ownerOf(cell) else cell.userId
		if key == nil then
			return false
		end
	end
	return Store.cellAt(state, ctx, key, false) == cell
end

-- Runs fn as the side that owns ctx: under loopback a fake client's code runs inside as, so
-- its Clock.serverNow() carries its offset.
local function inContext(ctx: any, fn: (...any) -> (), ...: any)
	local loopback = Runtime.Loopback :: any
	if ctx ~= SERVER and ctx ~= LOCAL then
		if not loopback or not loopback:owns(ctx) then
			return
		end
		loopback:as(ctx, Store.within, ctx, fn, ...)
		return
	end
	Store.within(ctx, fn, ...)
end

-- The server cell, with the initial rate running from now if this is its first use, so the
-- clock starts when the server first touches the meter (or the player joins), the same on
-- every side.
local function start(state: Def, player: Player?): Cell
	local cell = Store.writable(state, player)
	local data: Segment = cell.data
	if not data.started then
		data.started = true
		local rate = config(state).rate
		if rate ~= 0 then
			cell.data = segment(data.value, rate, data.min, data.max, serverTime())
			Store.written(state, cell, player)
		end
	end
	return cell
end

--------------------------------------------------------------------------------
-- Limits: one timer per watched cell, for the moment the value gets there
--------------------------------------------------------------------------------

local settle: (state: Def, ctx: any, cell: Cell, before: Segment?) -> ()

local function onTimer(state: Def, ctx: any, cell: Cell)
	local aux = cell.aux
	if not aux then
		return
	end
	aux.timer = nil
	if live(state, ctx, cell) then
		inContext(ctx, settle, state, ctx, cell, nil)
	end
end

-- Reports a limit the value has reached since the last check, then times the next one.
-- before is what showed just before a change: a limit reached by the rate an instant before
-- the change is reported, and leaving a limit is noted so returning to it is reported again.
settle = function(state: Def, ctx: any, cell: Cell, before: Segment?)
	local aux = cell.aux
	local listeners = aux and aux.listeners
	if not aux or not listeners or #listeners == 0 then
		return
	end
	if aux.timer then
		cancel(aux.timer)
		aux.timer = nil
	end

	local t = timeIn(ctx)
	if before then
		local was = limitAt(before, t)
		if was ~= aux.last then
			aux.last = was
			if was then
				Store.notify(state.name, listeners, was)
			end
		end
	end

	local current = effective(cell)
	local limit = limitAt(current, t)
	if limit ~= aux.last then
		aux.last = limit
		if limit then
			Store.notify(state.name, listeners, limit)
		end
	end

	-- A listener may have disconnected the last listener, or changed the meter (which settled again).
	if #listeners == 0 or aux.timer or effective(cell) ~= current then
		return
	end
	local delay, target = untilLimit(current, t)
	if delay and target ~= limit then
		aux.timer = Clock.delay(delay, onTimer, state, ctx, cell)
	end
end

--------------------------------------------------------------------------------
-- Telling observers
--------------------------------------------------------------------------------

local function emit(state: Def, ctx: any, cell: Cell, before: Segment)
	local current = effective(cell)
	local observed = cell.observers ~= nil and #cell.observers > 0
	if observed or Store.hasAllObservers(state, ctx) then
		local value = valueAt(current, timeIn(ctx))
		if observed then
			Store.notify(state.name, cell.observers, value, current.rate)
		end
		Store.notifyAll(state, ctx, cell, value, current.rate)
	end
	Store.changed(state, ctx)
	settle(state, ctx, cell, before)
end

local function current(cell: Cell): ...any
	local shown = effective(cell)
	return valueAt(shown, timeIn(Store.context())), shown.rate
end

--------------------------------------------------------------------------------
-- Kind
--------------------------------------------------------------------------------

function Meter.initial(state: Def): any
	local settings = config(state)
	return {
		value = settings.value,
		rate = 0,
		min = settings.min,
		max = settings.max,
		at = 0,
		started = false,
	} :: Segment
end

function Meter.snapshot(_state: Def, cell: Cell): ...any
	local data: Segment = cell.data
	return data.value, data.rate, data.min, data.max, data.at
end

Meter.diff = Meter.snapshot

function Meter.clearPending(_cell: Cell) end

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function dropPrediction(cell: Cell)
	local aux = cell.aux
	if aux and aux.predicted then
		aux.predicted = nil
		cancel(aux.predictTimer)
		aux.predictTimer = nil
	end
end

-- Client: a new segment from the server. It replaces any prediction.
function Meter.apply(state: Def, ctx: any, cell: Cell, value: number, rate: number, min: number, max: number, at: number)
	if not (finite(value) and finite(rate) and finite(min) and finite(max) and finite(at)) or min > max then
		Log.warn(`[HYDROGEN] State {state.name} received a meter segment that isn't finite numbers with min <= max; ignored`)
		return
	end
	local before = effective(cell)
	cell.data = segment(clamp(value, min, max), rate, min, max, at)
	dropPrediction(cell)
	emit(state, ctx, cell, before)
end

-- Server: a player starts receiving state. A meter whose initial rate isn't 0 starts running
-- for them now, so their client and the server agree on when it started.
function Meter.join(state: Def, player: Player)
	if config(state).rate == 0 then
		return
	end
	start(state, if state.perPlayer then player else nil)
end

-- A cell is being dropped (reset, a departed player, a closed loopback): stop its timers.
function Meter.discard(cell: Cell)
	local aux = cell.aux
	if aux then
		cancel(aux.timer)
		cancel(aux.predictTimer)
		aux.timer = nil
		aux.predictTimer = nil
		aux.listeners = nil
		aux.history = nil
	end
end

-- Server: a player left. Their meter stays readable for playerRemoving hooks, but its past is
-- dropped: nothing they send is judged any more.
function Meter.leave(state: Def, player: Player)
	if not state.perPlayer then
		return
	end
	local cell = Store.cellAt(state, SERVER, player, false)
	local aux = cell and cell.aux
	if aux then
		aux.history = nil
	end
end

function Meter.observeAll(state: Def, observer: (...any) -> ()): () -> ()
	return Store.observeAll(state, observer, current)
end

--------------------------------------------------------------------------------
-- Reads
--------------------------------------------------------------------------------

-- The segment this side shows, and the context it was read in.
local function read(state: Def, player: Player?): (Segment, any)
	Store.read(state)
	local ctx = Store.context()
	if ctx == SERVER then
		local cell = Store.cell(state, SERVER, player, false)
		if not cell or not cell.data.started then
			cell = start(state, player)
		end
		return (cell :: Cell).data, ctx
	end
	local cell = Store.cell(state, ctx, player, false)
	if not cell then
		return config(state).resting, ctx
	end
	return effective(cell), ctx
end

function Meter.get(state: Def, player: Player?): number
	local shown, ctx = read(state, player)
	if shown.rate == 0 then
		return shown.value
	end
	return valueAt(shown, timeIn(ctx))
end

-- Server, with a history option: the value at server time t, from the segment that was in force
-- then, clamped to that segment's range. A t after the last write (now, or a stamp a little in
-- the future) extrapolates the current segment like get(). nil when t is more than `history`
-- seconds ago, or before the oldest segment kept (the meter started later, the player left, or
-- the hard cap dropped it).
function Meter.getAt(state: Def, player: Player?, t: number): number?
	Store.read(state)
	local cell = Store.cell(state, SERVER, player, false)
	if not cell or not cell.data.started then
		cell = start(state, player)
	end
	if t < serverTime() - config(state).history then
		return nil
	end
	local data: Segment = (cell :: Cell).data
	if t >= data.at then
		return valueAt(data, t)
	end
	local aux = (cell :: Cell).aux
	local past: { Segment }? = aux and aux.history
	if past then
		for index = #past, 1, -1 do
			local old = past[index]
			if old.at <= t then
				return valueAt(old, t)
			end
		end
	end
	return nil
end

function Meter.getRate(state: Def, player: Player?): number
	local shown = read(state, player)
	return shown.rate
end

function Meter.getRange(state: Def, player: Player?): (number, number)
	local shown = read(state, player)
	return shown.min, shown.max
end

-- The cell observers attach to in the running context.
local function observed(state: Def, player: Player?): (any, Cell)
	local ctx = Store.context()
	if ctx == SERVER then
		return ctx, start(state, player)
	end
	return ctx, Store.cell(state, ctx, player, true) :: Cell
end

function Meter.observe(state: Def, player: Player?, observer: (...any) -> ()): () -> ()
	local ctx, cell = observed(state, player)
	local observers = cell.observers or {}
	cell.observers = observers
	local disconnect = Store.add(observers, observer)
	local shown = effective(cell)
	Store.within(ctx, Store.call, state.name, observer, valueAt(shown, timeIn(ctx)), shown.rate)
	return disconnect
end

function Meter.onLimit(state: Def, player: Player?, listener: (limit: Limit) -> ()): () -> ()
	local ctx, cell = observed(state, player)
	local aux = auxOf(cell)
	local listeners = aux.listeners or {}
	aux.listeners = listeners
	if #listeners == 0 then
		-- Where it is now isn't news: only arrivals from here on are reported.
		aux.last = limitAt(effective(cell), timeIn(ctx))
	end
	local remove = Store.add(listeners, listener)
	if not aux.timer then
		settle(state, ctx, cell, nil)
	end
	return function()
		remove()
		if #listeners == 0 and aux.timer then
			cancel(aux.timer)
			aux.timer = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Writes (server)
--------------------------------------------------------------------------------

-- With a history option, keeps the segment a write replaces, and drops what is past the window
-- (or the hard cap). Only on writes: reads and time passing do nothing.
local function remember(state: Def, player: Player?, cell: Cell, before: Segment, t: number)
	local window = config(state).history
	if window == 0 then
		return
	end
	local aux = auxOf(cell)
	if player and Store.departed(player) then
		aux.history = nil
		return
	end
	local past = aux.history
	if not past then
		past = {}
		aux.history = past
	end
	-- A segment replaced at the instant it started was never in force: nothing to keep.
	if before.at < t then
		table.insert(past, before)
	end

	-- Each kept segment lasts until the next one starts; drop the ones that ended before the
	-- window. The current segment (starting at t) always covers the window's end.
	local cutoff = t - window
	local drop = 0
	local count = #past
	while drop < count do
		local nextStart = if drop + 1 < count then past[drop + 2].at else t
		if nextStart > cutoff and count - drop <= MAX_HISTORY then
			break
		end
		drop += 1
	end
	if drop > 0 then
		table.move(past, drop + 1, count, 1)
		for index = count - drop + 1, count do
			past[index] = nil
		end
	end
end

local function commit(state: Def, player: Player?, cell: Cell, before: Segment, after: Segment)
	remember(state, player, cell, before, after.at)
	cell.data = after
	Store.written(state, cell, player)
	Store.within(SERVER, emit, state, SERVER, cell, before)
end

function Meter.set(state: Def, player: Player?, value: number)
	local cell = start(state, player)
	local data: Segment = cell.data
	local t = serverTime()
	local target = clamp(value, data.min, data.max)
	if target == valueAt(data, t) then
		return
	end
	commit(state, player, cell, data, segment(target, data.rate, data.min, data.max, t))
end

function Meter.add(state: Def, player: Player?, delta: number)
	local cell = start(state, player)
	local data: Segment = cell.data
	local t = serverTime()
	local now = valueAt(data, t)
	local target = clamp(now + delta, data.min, data.max)
	if target == now then
		return
	end
	commit(state, player, cell, data, segment(target, data.rate, data.min, data.max, t))
end

function Meter.setRate(state: Def, player: Player?, rate: number)
	local cell = start(state, player)
	local data: Segment = cell.data
	if rate == data.rate then
		return
	end
	local t = serverTime()
	commit(state, player, cell, data, segment(valueAt(data, t), rate, data.min, data.max, t))
end

function Meter.setRange(state: Def, player: Player?, min: number, max: number)
	local cell = start(state, player)
	local data: Segment = cell.data
	if min == data.min and max == data.max then
		return
	end
	local t = serverTime()
	commit(state, player, cell, data, segment(clamp(valueAt(data, t), min, max), data.rate, min, max, t))
end

-- Sends the segment again though nothing changed, so a client's prediction is replaced now
-- (e.g. after the server turned down the request it predicted).
function Meter.sync(state: Def, player: Player?)
	local cell = start(state, player)
	Store.written(state, cell, player)
end

--------------------------------------------------------------------------------
-- Prediction (the owning client)
--------------------------------------------------------------------------------

local function expire(state: Def, ctx: any, cell: Cell, predicted: Segment)
	local aux = cell.aux
	if not aux or aux.predicted ~= predicted then
		return
	end
	aux.predictTimer = nil
	if not live(state, ctx, cell) then
		return
	end
	inContext(ctx, function()
		if aux.predicted ~= predicted then
			return
		end
		aux.predicted = nil
		emit(state, ctx, cell, predicted)
	end)
end

-- Shows a change on this client at once, from Clock.serverNow(): a new rate, an instant change
-- by delta, or both. The next segment from the server replaces it; without one it is dropped
-- after the meter's predictTimeout.
function Meter.predict(state: Def, ctx: any, player: Player, rate: number?, delta: number?)
	local cell = Store.cell(state, ctx, player, true) :: Cell
	local aux = auxOf(cell)
	local before = effective(cell)
	local t = Clock.serverNow()
	local now = valueAt(before, t)
	local newRate = if rate ~= nil then rate else before.rate
	local newValue = if delta ~= nil then clamp(now + delta, before.min, before.max) else now
	if newRate == before.rate and newValue == now then
		return
	end

	local predicted = segment(newValue, newRate, before.min, before.max, t)
	aux.predicted = predicted
	cancel(aux.predictTimer)
	aux.predictTimer = Clock.delay(config(state).predictTimeout, expire, state, ctx, cell, predicted)
	emit(state, ctx, cell, before)
end

return Meter
