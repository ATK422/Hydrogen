local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Network = require("./Network")
local Definition = require("./Definition")
local Scope = require("./Scope")
local Clock = require("./Clock")
local Log = require("./Log")
-- Registers the characterAdded / characterRemoving hooks.
require("./Character")

type System = Definition.Lifecycle
type Scope = Scope.Scope
type Hooks = Definition.Hooks
type Feed = Definition.Feed

export type AppOptions = {
	-- Print how long each system's init and start took.
	debug: boolean?,
	-- Where debug output goes. Defaults to print.
	output: ((message: string) -> ())?,
	-- Collect the events fired during a frame and send them as one remote call per target.
	batching: boolean?,
}

-- A player, or a subject of a registered hook pair (a character), while the app has it.
type Subject = {
	hooks: Hooks,
	value: any,
	-- What the hooks are called with, after self.
	args: { any },
	-- Removed before its parent, and added only after the parent's added hooks returned.
	parent: Subject?,
	children: { Subject }?,
	-- Its first added hook has begun. A subject removed before that never runs a hook.
	started: boolean,
	-- Every added hook has returned.
	added: boolean,
	removing: boolean,
	-- Every removing hook has returned, or it was dropped before starting.
	removed: boolean,
	-- While removing, the index in _ordered of the system whose removing hook is running.
	-- Systems after it are done with the subject, so their scopes for it are closed.
	removingAt: number,
	-- Each system's scope for this subject, created the first time the system asks.
	scopes: { [System]: Scope }?,
	-- Threads waiting for this subject to be added or removed.
	waiting: { thread }?,
	-- From the attached hook pairs' player callbacks, run after a player's playerRemoving hooks.
	cleanups: { () -> () }?,
}

-- A registered hook pair running in this app.
type Attached = {
	hooks: Hooks,
	feed: Feed,
	detach: (() -> ())?,
}

local PLAYER: Hooks = {
	name = "player",
	added = "playerAdded",
	removing = "playerRemoving",
}

local App = {
	_systems = {} :: { System },
	-- Systems in dependency order, filled by start.
	_ordered = {} :: { System },
	-- Players and other subjects, per hook pair, keyed by the player or subject. One Instance can
	-- be a subject of several pairs (a character with a tag) with separate lifetimes.
	_subjects = {} :: { [Hooks]: { [any]: Subject } },
	-- Registered hook pairs some system in this app defines.
	_attached = {} :: { Attached },
	-- Original -> fake, from replace. Redirected while the app runs.
	_replacements = {} :: { [System]: System },
	-- Originals this app redirected, so it never undoes another app's.
	_redirected = {} :: { System },
	-- Subjects whose removing hooks are still running.
	_removing = 0,
	-- System scopes, created the first time a system asks.
	_scopes = {} :: { [System]: Scope },
	-- Subjects whose removing hooks have all run, so late Scope.of calls get a closed scope.
	_departed = {} :: { [Hooks]: { [any]: true } },
	-- What Scope.of calls for this app's systems.
	_owner = nil :: ((system: any, subject: any?) -> (Scope?, string?))?,
	_started = false,
	_stopped = false,
	_debug = false,
	_batching = false,
	_output = print :: (message: string) -> (),
}

-- A ModuleScript counts as well as its descendants, so a single module can be passed directly.
local function modulesIn(container: Instance): { ModuleScript }
	local modules = {}

	if container:IsA("ModuleScript") then
		table.insert(modules, container)
	end

	for _, child in container:GetDescendants() do
		if child:IsA("ModuleScript") then
			table.insert(modules, child)
		end
	end

	return modules
end

local function collectSystems(container: Instance): { System }
	local systems = {}

	for _, module in modulesIn(container) do
		local system = require(module) :: System
		if type(system) == "table" and system.id then
			table.insert(systems, system)
		else
			Log.warn(`[HYDROGEN] Tried to collect "system" but it was not a valid system: {module:GetFullName()}`)
		end
	end

	if #systems == 0 then
		Log.warn(`[HYDROGEN] addSystemsFolders found no systems in {container:GetFullName()}`)
	end

	return systems
end

-- Fails fast like a plain call, but names the system. Returns how long the hook took.
local function boot(system: System, hook: "init" | "start"): number
	local callback = (system :: any)[hook]
	if not callback then
		return 0
	end

	local began = os.clock()
	local ok, err = xpcall(callback, debug.traceback, system)
	if not ok then
		error(`[HYDROGEN] System {Definition.describe(system)} failed in {hook}: {err}`, 0)
	end
	return os.clock() - began
end

local function nameOf(value: any): string
	local ok, name = pcall(function()
		return value.Name
	end)
	return if ok and type(name) == "string" then name else tostring(value)
end

local function milliseconds(seconds: number): string
	return string.format("%.2fms", seconds * 1000)
end

-- One system failing must not stop the rest; Data still has to save when another system errors.
local function runHook(system: System, hook: string, ...: any)
	local callback = (system :: any)[hook]
	if not callback then
		return
	end

	local ok, err = xpcall(callback, debug.traceback, system, ...)
	if not ok then
		Log.warn(`[HYDROGEN] {hook} failed in system {Definition.describe(system)}: {err}`)
	end
end

function App.new(options: AppOptions?): typeof(App)
	local app = table.clone(App)
	app._debug = options ~= nil and options.debug == true
	app._batching = options ~= nil and options.batching == true
	app._output = (options and options.output) or print
	app._systems = {}
	app._ordered = {}
	app._subjects = {}
	app._attached = {}
	app._replacements = {}
	app._redirected = {}
	app._removing = 0
	app._scopes = {}
	app._departed = {}
	app._owner = nil
	app._started = false
	app._stopped = false
	return app
end

function App:addSystem(system: System)
	if self._started then
		if table.find(self._systems, system) then
			return
		end
		-- What it uses boots first, as it would have at start.
		for _, dependency in Definition.dependencies(system) do
			if not table.find(self._systems, dependency) then
				self:_note(`Added {Definition.describe(dependency)}: {Definition.describe(system)} uses it`)
				self:addSystem(dependency)
			end
		end
	end

	table.insert(self._systems, system)

	if self._started then
		Scope._own(system, self._owner :: any)
		boot(system, "init")
		boot(system, "start")

		-- Subjects still being added, and any added from here on (the characters of hooks this
		-- system is the first to define), reach it through the loop in _enter.
		table.insert(self._ordered, system)
		for _, state in self:_all() do
			if state.parent == nil and state.added and not state.removing then
				local children = {}
				for _, child in state.children or {} do
					if child.added then
						table.insert(children, child)
					end
				end
				task.spawn(self._catchUp, self, system, state, children)
			end
		end
		self:_attachHooks()
	end
end

-- A system added after start gets the added hooks for what's already in: a player, then their character.
function App:_catchUp(system: System, state: Subject, children: { Subject })
	runHook(system, state.hooks.added, table.unpack(state.args))
	for _, child in children do
		if not child.removing then
			runHook(system, child.hooks.added, table.unpack(child.args))
		end
	end
end

-- Debug output, for what the app decided on its own.
function App:_note(message: string)
	if self._debug then
		self._output(`[HYDROGEN] {message}`)
	end
end

function App:addSystems(systems: { System })
	for _, system in systems do
		self:addSystem(system)
	end
end

function App:addSystemsFolders(...: Instance)
	for _, container in { ... } do
		local systems = collectSystems(container)
		self:addSystems(systems)
	end
end

function App:addNetwork(...: Instance)
	for _, container in { ... } do
		local found = 0
		for _, module in modulesIn(container) do
			found += Network.countObjects(require(module) :: any)
		end

		-- Usually the wrong instance was passed; the names would then be missing on this side only.
		if found == 0 then
			Log.warn(`[HYDROGEN] addNetwork found no network objects in {container:GetFullName()}`)
		end
	end
end

-- Swaps a system for a fake until app:stop(). The fake's hooks run in the original's place
-- in the order, and the original forwards every field to the fake, so dependents that
-- already hold it call the fake. The original is added to the app if it wasn't.
function App:replace(original: System, fake: { [any]: any })
	if self._started then
		error(`[HYDROGEN] replace must be called before app:start()`, 2)
	end
	if not Definition.isDefined(original) then
		error(`[HYDROGEN] replace expects a system made with Hydrogen.define as the original`, 2)
	end
	if type(fake) ~= "table" or fake == original then
		error(`[HYDROGEN] replace expects a fake table to stand in for {Definition.describe(original)}`, 2)
	end

	if not table.find(self._systems, original) then
		table.insert(self._systems, original)
	end
	self._replacements[original] = fake :: any
end

function App:start()
	self._started = true

	-- A failed boot must not leave the originals pointing at this app's fakes, or leave
	-- running what systems added to their scopes in init.
	self:_redirect()
	local ok, err = pcall(self._boot, self)
	if not ok then
		self:_detachHooks()
		for index = #self._ordered, 1, -1 do
			self:_closeSystemScope(self._ordered[index])
		end
		self:_restore()
		error(err, 0)
	end
end

function App:_boot()
	self:_addDependencies()

	self._ordered = {}
	for index, system in Definition.order(self._systems) do
		self._ordered[index] = self._replacements[system] or system
	end

	-- Dependents hold the original, so Scope.of(original) has to reach the fake's scope too.
	self._owner = function(system, player)
		return self:_scopeOf(system, player)
	end
	for _, system in self._systems do
		Scope._own(system, self._owner :: any)
		local fake = self._replacements[system]
		if fake then
			Scope._own(fake, self._owner :: any)
		end
	end

	local initTimes: { [System]: number } = {}
	local startTimes: { [System]: number } = {}
	local began = os.clock()

	for _, system in self._ordered do
		initTimes[system] = boot(system, "init")
	end

	-- Listeners register during init; the client then requests any queued events.
	local networkBegan = os.clock()
	Network.init({ batching = self._batching })
	local networkTime = os.clock() - networkBegan

	for _, system in self._ordered do
		startTimes[system] = boot(system, "start")
	end

	if self._debug then
		self:_printTimings(os.clock() - began, networkTime, initTimes, startTimes)
	end

	self:_attachHooks()
	self:_listen()
end

-- A system that's used but wasn't added would run without its init and start, so it's added.
-- A replaced system's dependencies aren't: the fake stands in for it.
function App:_addDependencies()
	local included: { [System]: boolean } = {}
	for _, system in self._systems do
		included[system] = true
	end

	local index = 1
	while self._systems[index] do
		local system = self._systems[index]
		if not self._replacements[system] then
			for _, dependency in Definition.dependencies(system) do
				if not included[dependency] then
					included[dependency] = true
					table.insert(self._systems, dependency)
					self:_note(`Added {Definition.describe(dependency)}: {Definition.describe(system)} uses it`)
				end
			end
		end
		index += 1
	end
end

-- Hook pairs cost nothing until a system defines one of their hooks.
function App:_attachHooks()
	for _, hooks in Definition.registeredHooks() do
		local attached = false
		for _, entry in self._attached do
			if entry.hooks == hooks then
				attached = true
				break
			end
		end
		if attached or not self:_defines(hooks) then
			continue
		end

		local entry: Attached = {
			hooks = hooks,
			feed = self:_feed(hooks),
			detach = nil,
		}
		table.insert(self._attached, entry)

		if hooks.attach then
			local ok, result = xpcall(hooks.attach, debug.traceback, entry.feed)
			if not ok then
				error(`[HYDROGEN] Couldn't start the {hooks.added} / {hooks.removing} hooks: {result}`, 0)
			end
			entry.detach = result
		end

		-- Players added before a system defining these hooks arrived.
		if hooks.player then
			for _, state in self:_statesOf(PLAYER) do
				if state.started and not state.removing then
					self:_watchPlayer(entry, state)
				end
			end
		end
	end
end

function App:_defines(hooks: Hooks): boolean
	for _, system in self._ordered do
		if (system :: any)[hooks.added] ~= nil or (system :: any)[hooks.removing] ~= nil then
			return true
		end
	end
	return false
end

function App:_feed(hooks: Hooks): Feed
	local app = self
	local feed = {} :: Feed

	function feed.add(_: Feed, subject: any, args: { any }, parent: any?): boolean
		if subject == nil or type(args) ~= "table" then
			error(`[HYDROGEN] feed:add expects a subject and a table of hook arguments`, 2)
		end
		return app:_enter(hooks, subject, args, parent)
	end

	function feed.remove(_: Feed, subject: any)
		local state = app:_statesOf(hooks)[subject]
		if state then
			app:_leave(state)
		end
	end

	function feed.has(_: Feed, subject: any): boolean
		local state = app:_statesOf(hooks)[subject]
		return state ~= nil and not state.removing
	end

	function feed.scope(_: Feed, system: any, subject: any): Scope
		local scope, problem = app:_scopeOf(system, subject, hooks)
		if scope == nil then
			error(`[HYDROGEN] Scope.of: {problem}`, 2)
		end
		return scope
	end

	return feed
end

function App:_watchPlayer(entry: Attached, state: Subject)
	local ok, cleanup = xpcall(entry.hooks.player :: any, debug.traceback, entry.feed, state.value)
	if not ok then
		Log.warn(`[HYDROGEN] Couldn't watch {nameOf(state.value)} for {entry.hooks.added}: {cleanup}`)
	elseif cleanup ~= nil then
		local cleanups = state.cleanups or {}
		state.cleanups = cleanups
		table.insert(cleanups, cleanup)
	end
end

function App:_detachHooks()
	for index = #self._attached, 1, -1 do
		local entry = self._attached[index]
		local detach = entry.detach
		entry.detach = nil
		if detach then
			local ok, err = xpcall(detach, debug.traceback)
			if not ok then
				Log.warn(`[HYDROGEN] Stopping the {entry.hooks.added} / {entry.hooks.removing} hooks failed: {err}`)
			end
		end
	end
end

function App:_redirect()
	for original, fake in self._replacements do
		local ok, err = pcall(Definition.redirect, original, fake)
		if not ok then
			self:_restore()
			error(err, 0)
		end
		table.insert(self._redirected, original)
	end
end

function App:_restore()
	for _, original in self._redirected do
		Definition.restore(original)
	end
	table.clear(self._redirected)
end

-- Slowest systems first, so the ones worth looking at are at the top.
function App:_printTimings(total: number, network: number, initTimes: { [System]: number }, startTimes: { [System]: number })
	local systems = table.clone(self._ordered)
	table.sort(systems, function(a, b)
		return initTimes[a] + startTimes[a] > initTimes[b] + startTimes[b]
	end)

	local lines = { `[HYDROGEN] Booted {#systems} systems in {milliseconds(total)} (network {milliseconds(network)})` }
	for _, system in systems do
		table.insert(lines, `  {Definition.describe(system)}: init {milliseconds(initTimes[system])}, start {milliseconds(startTimes[system])}`)
	end
	self._output(table.concat(lines, "\n"))
end

-- Runs playerRemoving for every player still in the game (characterRemoving first), waits
-- for all of those hooks to finish, then runs stop hooks in reverse dependency order
-- (destroying each system's scope right after its hook) and undoes replace.
-- On the server this is bound to game:BindToClose.
function App:stop()
	if self._stopped then
		return
	end
	self._stopped = true

	-- Children go with their parent, first.
	local remaining = {}
	for _, state in self:_all() do
		if state.parent == nil then
			table.insert(remaining, state)
		end
	end
	for _, state in remaining do
		task.spawn(self._leave, self, state)
	end

	while self._removing > 0 do
		Clock.wait()
	end

	self:_detachHooks()

	for index = #self._ordered, 1, -1 do
		local system = self._ordered[index]
		runHook(system, "stop")
		self:_closeSystemScope(system)
	end

	self:_restore()
end

-- Scope.of for this app's systems. Originals resolve to the fake standing in for them.
-- Without hooks, a subject is looked up as a player first, then in each hook pair.
function App:_scopeOf(system: any, subject: any?, hooks: Hooks?): (Scope?, string?)
	system = self._replacements[system] or system
	if subject == nil then
		return self:_systemScope(system)
	end
	return self:_subjectScope(system, subject, hooks)
end

function App:_systemScope(system: System): Scope
	local scope = self._scopes[system]
	if scope == nil then
		scope = Scope.new(Definition.describe(system))
		self._scopes[system] = scope
	end
	return scope
end

-- After the system's stop hook, or when the boot fails. Scope.of then hands out a closed scope.
function App:_closeSystemScope(system: System)
	local scope = self._scopes[system]
	if scope then
		scope:destroy()
	else
		self._scopes[system] = Scope._closed
	end
end

-- Open from the subject's first added hook until this system's removing hook for it returns.
function App:_subjectScope(system: System, subject: any, hooks: Hooks?): (Scope?, string?)
	local state = if hooks then self:_statesOf(hooks)[subject] else self:_find(subject)
	if state == nil then
		if self:_departedFrom(subject, hooks) or self._stopped then
			return Scope._closed
		end
		if typeof(subject) == "Instance" and not subject:IsA("Player") then
			return nil, `{subject:GetFullName()} isn't a character (or other subject) the app has added. Ask for its scope from characterAdded or later`
		end
		return nil, `{nameOf(subject)} hasn't been added to the app yet. Ask for a player's scope from playerAdded or later`
	end

	local scopes = state.scopes
	if scopes == nil then
		scopes = {}
		state.scopes = scopes
	end

	local scope = scopes[system]
	if scope then
		return scope
	end

	if state.removing then
		local index = table.find(self._ordered, system)
		if index == nil or index > state.removingAt then
			return Scope._closed
		end
	end

	local label = if state.hooks == PLAYER then nameOf(subject) else `{state.hooks.name} {nameOf(subject)}`
	scope = Scope.new(`{Definition.describe(system)} for {label}`)
	scopes[system] = scope
	return scope
end

-- Players and shutdown only exist in a running game or under loopback; the tests call the hooks directly otherwise.
function App:_listen()
	local loopback = Network.activeLoopback()
	if loopback then
		loopback:watch(function(player)
			self:_addPlayer(player)
		end, function(player)
			self:_removePlayer(player)
		end)
		return
	end

	if not (RunService:IsServer() or RunService:IsClient()) then
		return
	end

	Players.PlayerAdded:Connect(function(player)
		self:_addPlayer(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		self:_removePlayer(player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(self._addPlayer, self, player)
	end

	if RunService:IsServer() then
		game:BindToClose(function()
			self:stop()
		end)
	end
end

local function isAdded(state: Subject): boolean
	return state.added
end

local function isRemoved(state: Subject): boolean
	return state.removed
end

-- Resumes everything waiting on the subject; each waiter checks again what it waits for.
local function wake(state: Subject)
	local waiting = state.waiting
	if waiting == nil then
		return
	end
	state.waiting = nil
	for _, thread in waiting do
		if coroutine.status(thread) == "suspended" then
			task.spawn(thread)
		end
	end
end

local function waitUntil(state: Subject, done: (Subject) -> boolean)
	while not done(state) do
		local waiting = state.waiting
		if waiting == nil then
			waiting = {}
			state.waiting = waiting
		end
		table.insert(waiting, coroutine.running())
		coroutine.yield()
	end
end

-- The subjects of one hook pair, keyed by subject.
function App:_statesOf(hooks: Hooks): { [any]: Subject }
	local states = self._subjects[hooks]
	if states == nil then
		states = {}
		self._subjects[hooks] = states
	end
	return states
end

-- Every subject of every hook pair.
function App:_all(): { Subject }
	local list = {}
	for _, states in self._subjects do
		for _, state in states do
			table.insert(list, state)
		end
	end
	return list
end

-- A player first, then the subject of each hook pair in the order they attached.
function App:_find(value: any): Subject?
	local state = self:_statesOf(PLAYER)[value]
	if state then
		return state
	end
	for _, entry in self._attached do
		state = self:_statesOf(entry.hooks)[value]
		if state then
			return state
		end
	end
	return nil
end

function App:_departedFrom(value: any, hooks: Hooks?): boolean
	if hooks then
		local departed = self._departed[hooks]
		return departed ~= nil and departed[value] == true
	end
	for _, departed in self._departed do
		if departed[value] then
			return true
		end
	end
	return false
end

function App:_addPlayer(player: Player)
	self:_enter(PLAYER, player, { player }, nil)
end

function App:_removePlayer(player: Player)
	local state = self:_statesOf(PLAYER)[player]
	if state then
		self:_leave(state)
	end
end

-- Calls the added hook on each system in dependency order, one after another, in this thread.
-- A subject with a parent waits for the parent's added hooks first.
function App:_enter(hooks: Hooks, value: any, args: { any }, parentValue: any?): boolean
	local states = self:_statesOf(hooks)
	if self._stopped or states[value] then
		return false
	end

	local parent: Subject? = nil
	if parentValue ~= nil then
		parent = self:_find(parentValue)
		if parent == nil or parent.removing then
			return false
		end
	end

	local state: Subject = {
		hooks = hooks,
		value = value,
		args = args,
		parent = parent,
		children = nil,
		started = false,
		added = false,
		removing = false,
		removed = false,
		removingAt = math.huge,
		scopes = nil,
		waiting = nil,
		cleanups = nil,
	}
	states[value] = state
	local departed = self._departed[hooks]
	if departed then
		departed[value] = nil
	end

	if parent then
		local siblings = parent.children
		if siblings == nil then
			siblings = {}
			parent.children = siblings
		end
		table.insert(siblings, state)

		waitUntil(parent, isAdded)
		if parent.removing and not state.removing then
			-- The parent is leaving; this subject goes without running a hook.
			self:_leave(state)
		end
		if state.removing then
			return false
		end
	end

	state.started = true
	if hooks == PLAYER then
		for _, entry in table.clone(self._attached) do
			if entry.hooks.player then
				self:_watchPlayer(entry, state)
			end
		end
	end

	-- Indexed so systems added while a hook yields are still reached.
	local index = 1
	while self._ordered[index] do
		runHook(self._ordered[index], hooks.added, table.unpack(args))
		index += 1
	end

	state.added = true
	wake(state)
	return true
end

-- Calls the removing hook on each system in reverse dependency order, once the added hooks
-- have finished and the subject's children are removed. Each system's scope for the subject
-- is destroyed right after its hook. Returns once the subject is fully removed, also when
-- another thread got there first.
function App:_leave(state: Subject)
	if state.removed then
		return
	end
	if state.removing then
		waitUntil(state, isRemoved)
		return
	end

	state.removing = true
	self._removing += 1

	if state.started then
		waitUntil(state, isAdded)

		-- Newest first, like scope cleanup.
		local children = state.children
		if children then
			local list = table.clone(children)
			for index = #list, 1, -1 do
				self:_leave(list[index])
			end
		end

		local hook = state.hooks.removing
		for index = #self._ordered, 1, -1 do
			local system = self._ordered[index]
			state.removingAt = index
			runHook(system, hook, table.unpack(state.args))

			local scope = state.scopes and state.scopes[system]
			if scope then
				scope:destroy()
			end
		end

		local cleanups = state.cleanups
		state.cleanups = nil
		if cleanups then
			for index = #cleanups, 1, -1 do
				local ok, err = xpcall(cleanups[index], debug.traceback)
				if not ok then
					Log.warn(`[HYDROGEN] Cleaning up after {nameOf(state.value)} failed: {err}`)
				end
			end
		end
	end

	-- Scopes asked for before the first hook ran, or for a system no longer in the order.
	local scopes = state.scopes
	if scopes then
		for _, scope in scopes do
			scope:destroy()
		end
	end

	local states = self:_statesOf(state.hooks)
	if states[state.value] == state then
		states[state.value] = nil
	end
	local departed = self._departed[state.hooks]
	if departed == nil then
		-- Weak, so departed players and characters can be collected.
		departed = setmetatable({}, { __mode = "k" }) :: any
		self._departed[state.hooks] = departed
	end
	departed[state.value] = true

	local parent = state.parent
	local siblings = parent and parent.children
	if siblings then
		local index = table.find(siblings, state)
		if index then
			table.remove(siblings, index)
		end
	end

	state.removed = true
	self._removing -= 1
	wake(state)
end

return App
