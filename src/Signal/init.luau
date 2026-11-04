--!strict

-- Typed signals within one side (server or client): a system broadcasts, others listen,
-- and neither calls the other directly.
--
-- Fire is immediate: every listener has run (or reached its first yield) when Fire returns.
-- Listeners run on a reused thread, one thread hop per Fire rather than per listener. If a
-- listener yields, that thread stays with it and Fire carries on with the next listener in a
-- new one, so a yielding listener never holds up the others or the code that fired.

local Log = require("./Log")

export type Connection = {
	-- False once disconnected (by Disconnect, Once firing, DisconnectAll or Destroy).
	read Connected: boolean,
	-- Stops the listener. Calling it again does nothing. Scope:add cleans connections with it.
	Disconnect: (self: Connection) -> (),
}

export type Signal<T...> = {
	-- Calls listener with the arguments of every Fire, in the order listeners connected.
	Connect: (self: Signal<T...>, listener: (T...) -> ()) -> Connection,
	-- Like Connect, but disconnects before the first call.
	Once: (self: Signal<T...>, listener: (T...) -> ()) -> Connection,
	-- Yields until the next Fire and returns its arguments.
	Wait: (self: Signal<T...>) -> T...,
	-- Calls every listener connected when Fire starts, now.
	Fire: (self: Signal<T...>, T...) -> (),
	-- Fire, after the current thread yields (task.defer).
	FireDeferred: (self: Signal<T...>, T...) -> (),
	-- Disconnects every listener. The signal still works.
	DisconnectAll: (self: Signal<T...>) -> (),
	-- Disconnects every listener; later Connects return a disconnected connection and Fire does nothing.
	Destroy: (self: Signal<T...>) -> (),
}

type Listener = (...any) -> ()

type ConnectionInternal = {
	Connected: boolean,
	-- Cleared on disconnect, so a connection kept around doesn't keep its closure alive.
	_listener: Listener?,
	_signal: SignalInternal?,
}

type SignalInternal = {
	-- Connected listeners in connection order. Replaced, never changed, while a Fire is walking it.
	_list: { ConnectionInternal },
	-- Fires walking _list right now (nested fires count once each).
	_firing: number,
	_destroyed: boolean,
	_name: string?,
}

type Runner = {
	thread: thread,
	-- Index of the listener running now; Fire reads it when a listener yields.
	index: number,
	-- Set when the runner reached the end of the list.
	done: boolean,
	-- Set by Fire when a listener yielded and Fire moved on without this runner.
	abandoned: boolean,
}

local SignalMethods = {}
local signalMetatable = { __index = SignalMethods }

local ConnectionMethods = {}
local connectionMetatable = { __index = ConnectionMethods }

--------------------------------------------------------------------------------
-- Running listeners
--------------------------------------------------------------------------------

local freeRunner: Runner? = nil

local function report(name: string?, err: any)
	if name then
		Log.warn(`[HYDROGEN] Listener of signal {name} failed: {err}`)
	else
		Log.warn(`[HYDROGEN] Signal listener failed: {err}`)
	end
end

-- Runs list[index..count] in the runner's thread until one yields.
local function runList(runner: Runner, name: string?, list: { ConnectionInternal }, count: number, index: number, ...: any)
	for i = index, count do
		local connection = list[i]
		local listener = connection._listener
		if listener then
			runner.index = i
			local ok, err = xpcall(listener, debug.traceback, ...)
			if not ok then
				report(name, err)
			end
			if runner.abandoned then
				-- The listener yielded and Fire went on without us; the rest is done.
				runner.abandoned = false
				return
			end
		end
	end
	runner.done = true
end

local function newRunner(): Runner
	local runner: Runner = {
		thread = nil :: any,
		index = 0,
		done = false,
		abandoned = false,
	}
	runner.thread = coroutine.create(function()
		while true do
			runList(coroutine.yield())
			-- Free again, whether it finished a Fire or a listener that had yielded.
			if freeRunner == nil then
				freeRunner = runner
			end
		end
	end)
	coroutine.resume(runner.thread)
	return runner
end

local function fire(self: SignalInternal, ...: any)
	local list = self._list
	local count = #list
	if count == 0 then
		return
	end

	self._firing += 1
	local index = 1
	while index <= count do
		local runner: Runner = freeRunner or newRunner()
		freeRunner = nil
		runner.done = false
		task.spawn(runner.thread, runner, self._name, list, count, index, ...)
		if runner.done then
			break
		end
		-- A listener yielded. Its thread is its own now; run the rest in another.
		runner.abandoned = true
		index = runner.index + 1
	end
	self._firing -= 1
end

--------------------------------------------------------------------------------
-- Connection
--------------------------------------------------------------------------------

function ConnectionMethods.Disconnect(self: ConnectionInternal)
	if not self.Connected then
		return
	end
	self.Connected = false
	self._listener = nil

	local signal = self._signal
	self._signal = nil
	if signal == nil then
		return
	end

	local list = signal._list
	if signal._firing > 0 then
		-- A Fire is walking this list: give the signal a new one and leave that Fire's alone.
		list = table.clone(list)
		signal._list = list
	end
	local index = table.find(list, self)
	if index then
		table.remove(list, index)
	end
end

local function closedConnection(): ConnectionInternal
	return setmetatable({
		Connected = false,
		_listener = nil,
		_signal = nil,
	}, connectionMetatable) :: any
end

--------------------------------------------------------------------------------
-- Signal
--------------------------------------------------------------------------------

local function connect(self: SignalInternal, listener: Listener): ConnectionInternal
	if self._destroyed then
		return closedConnection()
	end

	local connection: ConnectionInternal = setmetatable({
		Connected = true,
		_listener = listener,
		_signal = self,
	}, connectionMetatable) :: any

	local list = self._list
	if self._firing > 0 then
		-- Listeners connected during a Fire hear the next one, not this one.
		list = table.clone(list)
		self._list = list
	end
	table.insert(list, connection)
	return connection
end

local function checkListener(listener: any, method: string)
	if type(listener) ~= "function" then
		error(`[HYDROGEN] signal:{method} expects a function, got {typeof(listener)}`, 3)
	end
end

function SignalMethods.Connect(self: SignalInternal, listener: Listener): ConnectionInternal
	checkListener(listener, "Connect")
	return connect(self, listener)
end

function SignalMethods.Once(self: SignalInternal, listener: Listener): ConnectionInternal
	checkListener(listener, "Once")
	local connection: ConnectionInternal
	connection = connect(self, function(...)
		ConnectionMethods.Disconnect(connection)
		listener(...)
	end)
	return connection
end

function SignalMethods.Wait(self: SignalInternal): ...any
	if self._destroyed then
		error(`[HYDROGEN] signal:Wait() on a destroyed signal would never resume`, 2)
	end
	local thread = coroutine.running()
	local connection: ConnectionInternal
	connection = connect(self, function(...)
		ConnectionMethods.Disconnect(connection)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

SignalMethods.Fire = fire

function SignalMethods.FireDeferred(self: SignalInternal, ...: any)
	task.defer(fire, self, ...)
end

function SignalMethods.DisconnectAll(self: SignalInternal)
	local list = self._list
	-- A Fire walking the old list skips them: their listeners are cleared.
	self._list = {}
	for _, connection in list do
		connection.Connected = false
		connection._listener = nil
		connection._signal = nil
	end
end

function SignalMethods.Destroy(self: SignalInternal)
	self._destroyed = true
	SignalMethods.DisconnectAll(self)
end

local Signal = {}

-- A new signal. Give it a type where you declare it, so Fire and Connect are checked:
--   local Damaged: Hydrogen.Signal<Player, number> = Signal.new()
-- `name` appears in the warning when a listener errors.
function Signal.new<T...>(name: string?): Signal<T...>
	local signal: SignalInternal = {
		_list = {},
		_firing = 0,
		_destroyed = false,
		_name = name,
	}
	return setmetatable(signal, signalMetatable) :: any
end

-- True for a Hydrogen signal.
function Signal.is(value: any): boolean
	return type(value) == "table" and getmetatable(value) == signalMetatable
end

return Signal
