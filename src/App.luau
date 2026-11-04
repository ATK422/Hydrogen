local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Network = require("./Network")
local Definition = require("./Definition")
local Scope = require("./Scope")

type System = Definition.Lifecycle
type Scope = Scope.Scope

export type AppOptions = {
	-- Print how long each system's init and start took.
	debug: boolean?,
	-- Where debug output goes. Defaults to print.
	output: ((message: string) -> ())?,
	-- Collect the events fired during a frame and send them as one remote call per target.
	batching: boolean?,
}

type PlayerState = {
	-- Every playerAdded hook has returned.
	added: boolean,
	removing: boolean,
	-- While removing, the index in _ordered of the system whose playerRemoving is running.
	-- Systems after it are done with the player, so their scopes for it are closed.
	removingAt: number,
	-- Each system's scope for this player, created the first time the system asks.
	scopes: { [System]: Scope }?,
}

local App = {
	_systems = {} :: { System },
	-- Systems in dependency order, filled by start.
	_ordered = {} :: { System },
	_players = {} :: { [Player]: PlayerState },
	-- Original -> fake, from replace. Redirected while the app runs.
	_replacements = {} :: { [System]: System },
	-- Originals this app redirected, so it never undoes another app's.
	_redirected = {} :: { System },
	-- Players whose playerRemoving hooks are still running.
	_removing = 0,
	-- System scopes, created the first time a system asks.
	_scopes = {} :: { [System]: Scope },
	-- Players whose playerRemoving hooks have all run, so late Scope.of calls get a closed scope.
	_departed = {} :: { [Player]: true },
	-- What Scope.of calls for this app's systems.
	_owner = nil :: ((system: any, player: Player?) -> (Scope?, string?))?,
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
			warn(`[HYDROGEN] Tried to collect "system" but it was not a valid system: {module:GetFullName()}`)
		end
	end

	if #systems == 0 then
		warn(`[HYDROGEN] addSystemsFolders found no systems in {container:GetFullName()}`)
	end

	return systems
end

-- A hook that declares a parameter after its usual ones (`function S:start(scope)`,
-- `function S:playerAdded(player, scope)`) is given a scope. Other hooks never create one.
local function wantsScope(callback: any, usual: number): boolean
	if type(callback) ~= "function" then
		return false
	end
	local params, variadic = debug.info(callback, "a")
	return variadic or params > usual
end

-- Fails fast like a plain call, but names the system. Returns how long the hook took.
local function boot(app: typeof(App), system: System, hook: "init" | "start"): number
	local callback = (system :: any)[hook]
	if not callback then
		return 0
	end

	local scope = if wantsScope(callback, 1) then app:_systemScope(system) else nil
	local began = os.clock()
	local ok, err = xpcall(callback, debug.traceback, system, scope)
	if not ok then
		error(`[HYDROGEN] System {Definition.describe(system)} failed in {hook}: {err}`, 0)
	end
	return os.clock() - began
end

local function milliseconds(seconds: number): string
	return string.format("%.2fms", seconds * 1000)
end

-- One system failing must not stop the rest; Data still has to save when another system errors.
local function runHook(app: typeof(App), system: System, hook: "playerAdded" | "playerRemoving" | "stop", player: Player?)
	local callback = (system :: any)[hook]
	if not callback then
		return
	end

	local ok, err
	if player then
		local scope = if wantsScope(callback, 2) then app:_playerScope(system, player) else nil
		ok, err = xpcall(callback, debug.traceback, system, player, scope)
	else
		local scope = if wantsScope(callback, 1) then app:_systemScope(system) else nil
		ok, err = xpcall(callback, debug.traceback, system, scope)
	end
	if not ok then
		warn(`[HYDROGEN] {hook} failed in system {Definition.describe(system)}: {err}`)
	end
end

function App.new(options: AppOptions?): typeof(App)
	local app = table.clone(App)
	app._debug = options ~= nil and options.debug == true
	app._batching = options ~= nil and options.batching == true
	app._output = (options and options.output) or print
	app._systems = {}
	app._ordered = {}
	app._players = {}
	app._replacements = {}
	app._redirected = {}
	app._removing = 0
	app._scopes = {}
	app._departed = setmetatable({}, { __mode = "k" }) :: any
	app._owner = nil
	app._started = false
	app._stopped = false
	return app
end

function App:addSystem(system: System)
	table.insert(self._systems, system)

	if self._started then
		Scope._own(system, self._owner :: any)
		boot(self, system, "init")
		boot(self, system, "start")

		-- Players still being added reach this system through the loop in _addPlayer.
		table.insert(self._ordered, system)
		for player, state in self._players do
			if state.added and not state.removing then
				task.spawn(runHook, self, system, "playerAdded", player)
			end
		end
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
			warn(`[HYDROGEN] addNetwork found no network objects in {container:GetFullName()}`)
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
		for index = #self._ordered, 1, -1 do
			self:_closeSystemScope(self._ordered[index])
		end
		self:_restore()
		error(err, 0)
	end
end

function App:_boot()
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
		initTimes[system] = boot(self, system, "init")
	end

	-- Listeners register during init; the client then requests any queued events.
	local networkBegan = os.clock()
	Network.init({ batching = self._batching })
	local networkTime = os.clock() - networkBegan

	for _, system in self._ordered do
		startTimes[system] = boot(self, system, "start")
	end

	if self._debug then
		self:_printTimings(os.clock() - began, networkTime, initTimes, startTimes)
	end

	self:_listen()
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

-- Runs playerRemoving for every player still in the game, waits for all of those
-- hooks to finish, then runs stop hooks in reverse dependency order (destroying each
-- system's scope right after its hook) and undoes replace.
-- On the server this is bound to game:BindToClose.
function App:stop()
	if self._stopped then
		return
	end
	self._stopped = true

	local remaining = {}
	for player in self._players do
		table.insert(remaining, player)
	end
	for _, player in remaining do
		task.spawn(self._removePlayer, self, player)
	end

	while self._removing > 0 do
		task.wait()
	end

	for index = #self._ordered, 1, -1 do
		local system = self._ordered[index]
		runHook(self, system, "stop")
		self:_closeSystemScope(system)
	end

	self:_restore()
end

-- Scope.of for this app's systems. Originals resolve to the fake standing in for them.
function App:_scopeOf(system: any, player: Player?): (Scope?, string?)
	system = self._replacements[system] or system
	if player == nil then
		return self:_systemScope(system)
	end
	return self:_playerScope(system, player)
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

-- Open from the player's first playerAdded hook until this system's playerRemoving for them returns.
function App:_playerScope(system: System, player: Player): (Scope?, string?)
	local state = self._players[player]
	if state == nil then
		if self._departed[player] or self._stopped then
			return Scope._closed
		end
		return nil, `{player.Name} hasn't been added to the app yet. Ask for a player's scope from playerAdded or later`
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

	scope = Scope.new(`{Definition.describe(system)} for {player.Name}`)
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

-- Calls playerAdded on each system in dependency order, one after another.
function App:_addPlayer(player: Player)
	if self._stopped or self._players[player] then
		return
	end

	local state: PlayerState = {
		added = false,
		removing = false,
		removingAt = math.huge,
		scopes = nil,
	}
	self._players[player] = state

	-- Indexed so systems added while a hook yields are still reached.
	local index = 1
	while self._ordered[index] do
		runHook(self, self._ordered[index], "playerAdded", player)
		index += 1
	end

	state.added = true
end

-- Calls playerRemoving on each system in reverse dependency order, after playerAdded has finished.
-- Each system's scope for the player is destroyed right after its hook.
function App:_removePlayer(player: Player)
	local state = self._players[player]
	if not state or state.removing then
		return
	end

	state.removing = true
	self._removing += 1

	while not state.added do
		task.wait()
	end

	for index = #self._ordered, 1, -1 do
		local system = self._ordered[index]
		state.removingAt = index
		runHook(self, system, "playerRemoving", player)

		local scope = state.scopes and state.scopes[system]
		if scope then
			scope:destroy()
		end
	end

	self._players[player] = nil
	self._departed[player] = true
	self._removing -= 1
end

return App
