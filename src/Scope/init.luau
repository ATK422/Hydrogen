-- Cleanup tied to a lifetime. A scope collects whatever must be undone (connections, threads,
-- Instances, functions, other scopes) and undoes it all, newest first, when it's destroyed.
-- Apps give every system a scope and a scope per player; Scope.new makes your own.

export type Scope = {
	-- False once destroyed. Anything added to a destroyed scope is cleaned right away, so work
	-- that finishes after its player left (a DataStore load, a delay) can't leak.
	read alive: boolean,
	-- Shown in cleanup warnings.
	read name: string?,

	-- Tracks a task and returns it: a function (called), a thread (cancelled), an RBXScriptConnection,
	-- an Instance, another scope, or an object with Destroy, Disconnect or cancel (a promise).
	add: <T>(self: Scope, task: T) -> T,
	-- Connects and tracks the connection.
	connect: <T...>(self: Scope, signal: RBXScriptSignal<T...>, callback: (T...) -> ()) -> RBXScriptConnection,
	-- task.spawn, cancelled if the scope is destroyed first.
	spawn: <A...>(self: Scope, callback: (A...) -> ...any, A...) -> thread,
	-- task.delay, cancelled if the scope is destroyed first.
	delay: <A...>(self: Scope, seconds: number, callback: (A...) -> ...any, A...) -> thread,
	-- A scope destroyed with this one, or earlier on its own.
	child: (self: Scope, name: string?) -> Scope,
	-- Cleans one task now and stops tracking it.
	remove: (self: Scope, task: any) -> (),
	-- Cleans every task, newest first. Errors in a task are warned and the rest still run.
	destroy: (self: Scope) -> (),
	-- Same as destroy, for libraries (Trove, Maid, Janitor) that clean objects with Destroy.
	Destroy: (self: Scope) -> (),
}

type Internal = {
	alive: boolean,
	name: string?,
	-- Task -> when it was added; destroy cleans the newest first. Created on the first add.
	_tasks: { [any]: number }?,
	-- The scope this one was made in, so destroying it early stops the parent holding it.
	_parent: Internal?,
}

-- Finds the scope an app keeps for a system (and player). Returns nil and a reason when it can't.
type Owner = (system: any, player: Player?) -> (Scope?, string?)

local Methods = {}
local metatable = { __index = Methods }

-- Systems running in an app -> that app's lookup. Weak, so systems from finished tests can be collected.
local owners: { [any]: Owner } = setmetatable({}, { __mode = "k" }) :: any

-- Time source, so a test harness can swap in a fake clock (Scope._clock.delay). Same contract as task.delay.
local clock = {
	delay = function(seconds: number, thread: thread, ...: any): thread
		return task.delay(seconds, thread, ...)
	end,
}

-- Increases with every add, so destroy can clean in reverse order without keeping an array.
local added = 0

local METHOD_NAMES = { "Destroy", "Disconnect", "destroy", "disconnect", "cancel", "Cancel" }

local function index(object: any, key: string): any
	return object[key]
end

-- Userdata and strict classes error on unknown keys, so each lookup is protected.
local function methodOf(object: any): ((any) -> ...any)?
	for _, name in METHOD_NAMES do
		local ok, method = pcall(index, object, name)
		if ok and type(method) == "function" then
			return method
		end
	end
	return nil
end

local function cleanable(task: any): boolean
	local kind = typeof(task)
	if kind == "function" or kind == "thread" or kind == "RBXScriptConnection" or kind == "Instance" then
		return true
	end
	return (kind == "table" or kind == "userdata") and methodOf(task) ~= nil
end

local function cancel(thread: thread)
	local status = coroutine.status(thread)
	if status == "suspended" then
		task.cancel(thread)
	elseif status == "normal" then
		-- It resumed the code destroying the scope, so it can only be stopped once it yields.
		task.defer(function()
			if coroutine.status(thread) == "suspended" then
				task.cancel(thread)
			end
		end)
	end
	-- "running" is the thread destroying its own scope; it finishes what it's doing.
end

local function clean(task: any)
	local kind = typeof(task)
	if kind == "function" then
		task()
	elseif kind == "thread" then
		cancel(task)
	elseif kind == "RBXScriptConnection" then
		task:Disconnect()
	elseif kind == "Instance" then
		task:Destroy()
	else
		local method = methodOf(task)
		if method then
			method(task)
		end
	end
end

-- One failing task must not stop the rest; a player's other connections still have to go.
local function cleanSafely(scope: Internal, task: any)
	local ok, err = xpcall(clean, debug.traceback, task)
	if not ok then
		if scope.name then
			warn(`[HYDROGEN] Cleanup failed in scope {scope.name}: {err}`)
		else
			warn(`[HYDROGEN] Scope cleanup failed: {err}`)
		end
	end
end

local function track(scope: Internal, task: any)
	if not scope.alive then
		cleanSafely(scope, task)
		return
	end

	local tasks = scope._tasks
	if tasks == nil then
		tasks = {}
		scope._tasks = tasks
	end
	if tasks[task] == nil then
		added += 1
		tasks[task] = added
	end
end

local function new(name: string?): Scope
	local scope: Internal = {
		alive = true,
		name = name,
		_tasks = nil,
		_parent = nil,
	}
	return setmetatable(scope, metatable) :: any
end

-- Ends a spawned or delayed thread: forget it, then report its error as task.spawn would have.
local function finish(scope: Internal, thread: thread, ok: boolean, ...: any)
	local tasks = scope._tasks
	if tasks then
		tasks[thread] = nil
	end
	if not ok then
		error((...), 0)
	end
end

local function run(scope: Internal, callback: (...any) -> ...any, ...: any)
	finish(scope, coroutine.running(), xpcall(callback, debug.traceback, ...))
end

function Methods.add<T>(self: Internal, task: T): T
	if not cleanable(task) then
		error(
			`[HYDROGEN] A scope can't clean a {typeof(task)}. Add a function, connection, Instance, thread, scope, or an object with Destroy, Disconnect or cancel`,
			2
		)
	end

	if type(task) == "table" and getmetatable(task :: any) == metatable then
		if (task :: any) == self then
			error(`[HYDROGEN] A scope can't be added to itself`, 2)
		end
		local child = task :: any
		if child._parent == nil then
			child._parent = self
		end
	end

	track(self, task)
	return task
end

function Methods.connect(self: Internal, signal: any, callback: (...any) -> ()): any
	if typeof(signal) == "RBXScriptSignal" then
		return Methods.add(self, signal:Connect(callback))
	end

	local connect = type(signal) == "table" and (signal.Connect or signal.connect)
	if type(connect) ~= "function" then
		if type(signal) == "table" and signal.On then
			error(`[HYDROGEN] scope:connect takes a signal. For a Hydrogen network object use scope:add(object:On(callback))`, 2)
		end
		error(`[HYDROGEN] scope:connect expects a signal with Connect, got {typeof(signal)}`, 2)
	end
	return Methods.add(self, connect(signal, callback))
end

function Methods.spawn(self: Internal, callback: (...any) -> ...any, ...: any): thread
	local thread = coroutine.create(run)
	-- Tracked before it runs, so a callback that finishes at once is still forgotten.
	track(self, thread)
	if self.alive then
		task.spawn(thread, self, callback, ...)
	end
	return thread
end

function Methods.delay(self: Internal, seconds: number, callback: (...any) -> ...any, ...: any): thread
	local thread = coroutine.create(run)
	track(self, thread)
	if self.alive then
		clock.delay(seconds, thread, self, callback, ...)
	end
	return thread
end

function Methods.child(self: Internal, name: string?): Scope
	return Methods.add(self, new(name))
end

function Methods.remove(self: Internal, task: any)
	local tasks = self._tasks
	if tasks == nil or tasks[task] == nil then
		return
	end
	tasks[task] = nil
	cleanSafely(self, task)
end

function Methods.destroy(self: Internal)
	if not self.alive then
		return
	end
	self.alive = false

	local parent = self._parent
	if parent then
		self._parent = nil
		local siblings = parent._tasks
		if siblings then
			siblings[self] = nil
		end
	end

	local tasks = self._tasks
	if tasks == nil then
		return
	end
	self._tasks = nil

	local ordered = {}
	for task in tasks do
		table.insert(ordered, task)
	end
	table.sort(ordered, function(a, b)
		return tasks[a] > tasks[b]
	end)

	for _, task in ordered do
		cleanSafely(self, task)
	end
end

Methods.Destroy = Methods.destroy

-- Destroyed once, never holds anything: what a lifetime that has already ended hands out.
local closed = new()
Methods.destroy(closed :: any)

local Scope = {}

-- A scope you destroy yourself. Make it a child (scope:child()) to tie it to a longer lifetime.
function Scope.new(name: string?): Scope
	return new(name)
end

-- The scope an app keeps for a system, or for a player within that system. The system scope
-- is destroyed on app:stop() right after the system's stop hook. A player scope is destroyed
-- right after the system's playerRemoving for that player, so in reverse dependency order.
-- Once that has happened you get a destroyed scope, which cleans anything added straight away.
function Scope.of(system: any, player: Player?): Scope
	local owner = owners[system]
	if owner == nil then
		local name = if type(system) == "table" and type(system.id) == "string" then system.id else tostring(system)
		error(`[HYDROGEN] Scope.of: {name} isn't running in an app. Ask for its scope from init or later`, 2)
	end

	local scope, problem = owner(system, player)
	if scope == nil then
		error(`[HYDROGEN] Scope.of: {problem}`, 2)
	end
	return scope
end

-- Used by Hydrogen itself.

Scope._clock = clock

Scope._closed = closed :: Scope

-- An app registers each system it runs (and each fake standing in for one).
function Scope._own(system: any, owner: Owner)
	owners[system] = owner
end

return Scope
