--!strict

local Scope = require("./Scope")

type function WithoutLifecycle(t: type)
	if t:is("union") or t:is("intersection") then
		local parts = {}
		for _, component in t:components() do
			table.insert(parts, WithoutLifecycle(component))
		end

		if #parts == 0 then
			return types.never
		elseif #parts == 1 then
			return parts[1]
		elseif t:is("union") then
			return types.unionof(table.unpack(parts))
		else
			return types.intersectionof(table.unpack(parts))
		end
	end

	if not t:is("table") then
		return t
	end

	local result = types.copy(t)
	result:setproperty(types.singleton("init"), nil)
	result:setproperty(types.singleton("start"), nil)
	result:setproperty(types.singleton("playerAdded"), nil)
	result:setproperty(types.singleton("playerRemoving"), nil)
	result:setproperty(types.singleton("characterAdded"), nil)
	result:setproperty(types.singleton("characterRemoving"), nil)
	result:setproperty(types.singleton("stop"), nil)
	result:setproperty(types.singleton("id"), nil)

	return result
end

export type Lifecycle = {
	id: string,
	init: ((any) -> ())?,
	start: ((any) -> ())?,
	playerAdded: ((any, Player) -> ())?,
	playerRemoving: ((any, Player) -> ())?,
	characterAdded: ((any, Player, Model) -> ())?,
	characterRemoving: ((any, Player, Model) -> ())?,
	stop: ((any) -> ())?,
}

-- Extension point for modules that add a pair of hooks systems can define, such as
-- characterAdded / characterRemoving. Each subject (a character, a tagged Instance) gets the
-- same guarantees as a player: added hooks run in dependency order, removing hooks in reverse
-- order and only after every added hook returned, an error in one system is warned and the
-- rest still run, and each system's Scope.of(system, subject) is destroyed right after its
-- removing hook. Add the hook names to Lifecycle and WithoutLifecycle above so they type-check.
export type Hooks = {
	-- Used in scope names, e.g. "Combat for character alice".
	name: string,
	-- The method names systems define, called as system:added(...args) / system:removing(...args).
	added: string,
	removing: string,
	-- Optional. Runs once per app that has a system defining either hook: at the end of
	-- app:start(), or when the first such system is added later. Returns cleanup for app:stop(),
	-- which runs after every subject was removed. An error fails app:start().
	attach: ((feed: Feed) -> (() -> ())?)?,
	-- Optional. Runs for each player the app adds, in the thread adding them, before their
	-- playerAdded hooks, and for players already in the app when the hooks attach late. Must not
	-- yield. Returns cleanup that runs after the player's last playerRemoving hook.
	player: ((feed: Feed, player: Player) -> (() -> ())?)?,
}

-- What an app hands an extension to drive its hooks. One per app and extension.
export type Feed = {
	-- Runs the added hook on every system in dependency order, in the calling thread, with args
	-- (no nil holes). With a parent subject (a player for a character) it first waits for the
	-- parent's added hooks, and the subject is removed before the parent. Returns false and runs
	-- nothing if the subject is already in the app, the parent isn't in it or is being removed,
	-- the app has stopped, or the subject is removed before its first hook runs.
	add: (self: Feed, subject: any, args: { any }, parent: any?) -> boolean,
	-- Runs the removing hooks in reverse order, after the added hooks finished. Yields until the
	-- subject is fully removed, also when another thread is already removing it. Nothing happens
	-- for a subject that isn't in the app.
	remove: (self: Feed, subject: any) -> (),
	-- The subject is in the app and not being removed.
	has: (self: Feed, subject: any) -> boolean,
	-- The system's scope for the subject under these hooks, as Scope.of(system, subject) would
	-- give it. Use it when one Instance can be a subject of several hook pairs (a tagged
	-- character): Scope.of looks for a player first, then each pair in the order they attached.
	scope: (self: Feed, system: any, subject: any) -> Scope.Scope,
}

export type System<T> = WithoutLifecycle<T>
export type Defined<T> = System<T> & Lifecycle

local Graph = require("./Graph")

type Registered<T> = T & {
	id: string,
	init: (() -> ())?,
	start: (() -> ())?,
}

-- Where each system was defined, so messages can tell a common Data from a place's Data.
local paths: { [Lifecycle]: string } = {}

-- A system an app swapped for a fake, while that app runs. Dependents hold the original
-- table (use returned it at require time), so the original itself forwards to the fake.
type Redirect = {
	fake: any,
	fields: { [any]: any },
	metatable: any,
}

local redirects: { [Lifecycle]: Redirect } = {}
-- Fake -> the system it stands in for, so messages name the original.
local standIns: { [any]: Lifecycle } = {}

local function describe(system: Lifecycle): string
	local original = standIns[system]
	if original then
		return `{describe(original)} (replaced)`
	end
	return paths[system] or system.id
end

local graph = Graph.new(describe) :: Graph.Graph<Lifecycle>
local pending: { { Lifecycle } } = {}
-- What each system uses, so an app can add dependencies nobody added.
local dependencies: { [Lifecycle]: { Lifecycle } } = {}
-- Hook pairs modules registered with Definition.hooks, in registration order.
local registered: { Hooks } = {}
local BUILT_IN = { "init", "start", "playerAdded", "playerRemoving", "stop", "id" }

local function use<T>(definition: T): WithoutLifecycle<T>
	local deps = pending[#pending]
	if deps then
		table.insert(deps, definition :: Lifecycle)
	end
	return definition :: WithoutLifecycle<T>
end

type Constructor<T> = (use: typeof(use)) -> T

local Definition = {}

-- The id is the calling module's name unless one is given; called through a wrapper,
-- the inferred id would be the wrapper's module, so wrappers should pass one.
local function define<T>(idOrConstructor: string | Constructor<T>, maybeConstructor: Constructor<T>?): Defined<T>
	local id: string? = nil
	local constructor: Constructor<T>
	if type(idOrConstructor) == "string" then
		if idOrConstructor == "" or type(maybeConstructor) ~= "function" then
			error(`[HYDROGEN] define(id, constructor) needs a non-empty id and a constructor function`, 2)
		end
		id = idOrConstructor
		constructor = maybeConstructor :: Constructor<T>
	else
		constructor = idOrConstructor :: Constructor<T>
	end

	local deps: { Lifecycle } = {}
	table.insert(pending, deps)

	local source = debug.info(2, "s") :: string
	local system = constructor(use) :: Registered<T>
	system.id = id or string.match(source, "[^.]+$") :: string
	paths[system :: any] = id or source

	table.remove(pending)
	graph:add(system)
	for _, dependency in deps do
		graph:link(system, dependency)
	end
	if #deps > 0 then
		dependencies[system :: any] = deps
	end

	return system :: Defined<T>
end

Definition.define = define :: (<T>(constructor: Constructor<T>) -> Defined<T>) & (<T>(id: string, constructor: Constructor<T>) -> Defined<T>)

-- The explicit id, or else the full name of the module that defined the system, e.g. ServerScriptService.Lobby.Data.
Definition.describe = describe

function Definition.order(systems: { Lifecycle }): { Lifecycle }
	return graph:sort(systems)
end

-- The systems a system uses, in the order its constructor called use.
function Definition.dependencies(system: Lifecycle): { Lifecycle }
	return dependencies[system] or {}
end

-- Registers a pair of hooks systems can define. Call it once, when the module defining the
-- hooks loads; apps started from then on run them.
function Definition.hooks(spec: Hooks): Hooks
	if type(spec) ~= "table" or type(spec.name) ~= "string" or type(spec.added) ~= "string" or type(spec.removing) ~= "string" then
		error(`[HYDROGEN] Definition.hooks expects \{ name: string, added: string, removing: string }`, 2)
	end
	for _, name in { spec.added, spec.removing } do
		if name == "" or table.find(BUILT_IN, name) then
			error(`[HYDROGEN] Definition.hooks: "{name}" can't be used as a hook name`, 2)
		end
		for _, other in registered do
			if other.added == name or other.removing == name then
				error(`[HYDROGEN] Definition.hooks: the hook "{name}" is already registered by {other.name}`, 2)
			end
		end
	end
	if spec.added == spec.removing then
		error(`[HYDROGEN] Definition.hooks: added and removing must be different hooks`, 2)
	end

	table.insert(registered, spec)
	return spec
end

-- Every registered hook pair, oldest first.
function Definition.registeredHooks(): { Hooks }
	return registered
end

function Definition.isDefined(value: any): boolean
	return type(value) == "table" and paths[value] ~= nil
end

-- Empties the original and points it at the fake, so every holder of the original (dependents,
-- plain modules that required it) reaches the fake. Nothing changes for systems never replaced.
function Definition.redirect(original: Lifecycle, fake: any)
	if redirects[original] then
		error(`[HYDROGEN] System {describe(original)} is already replaced by a running app; stop that app first`, 0)
	end
	if table.isfrozen(original :: any) then
		error(`[HYDROGEN] Can't replace system {describe(original)}: its table is frozen`, 0)
	end

	local fields = {}
	for key, value in next, original :: any do
		fields[key] = value
	end
	local metatable = getmetatable(original :: any)

	local ok = pcall(setmetatable, original :: any, { __index = fake, __newindex = fake })
	if not ok then
		error(`[HYDROGEN] Can't replace system {describe(original)}: its metatable is locked`, 0)
	end
	table.clear(original :: any)
	-- Kept so the shell still names the system it was.
	rawset(original :: any, "id", fields.id)

	redirects[original] = {
		fake = fake,
		fields = fields,
		metatable = metatable,
	}
	standIns[fake] = original
end

-- Puts the original's fields and metatable back. Writes made through it went to the fake.
function Definition.restore(original: Lifecycle)
	local redirect = redirects[original]
	if not redirect then
		return
	end

	redirects[original] = nil
	standIns[redirect.fake] = nil
	table.clear(original :: any)
	setmetatable(original :: any, redirect.metatable)
	for key, value in redirect.fields do
		rawset(original :: any, key, value)
	end
end

return Definition
