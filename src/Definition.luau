--!strict

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
	result:setproperty(types.singleton("stop"), nil)
	result:setproperty(types.singleton("id"), nil)

	return result
end

export type Lifecycle = {
	read id: string,
	read init: ((any) -> ())?,
	read start: ((any) -> ())?,
	read playerAdded: ((any, Player) -> ())?,
	read playerRemoving: ((any, Player) -> ())?,
	read stop: ((any) -> ())?,
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

	return system :: Defined<T>
end

Definition.define = define :: (<T>(constructor: Constructor<T>) -> Defined<T>) & (<T>(id: string, constructor: Constructor<T>) -> Defined<T>)

-- The explicit id, or else the full name of the module that defined the system, e.g. ServerScriptService.Lobby.Data.
Definition.describe = describe

function Definition.order(systems: { Lifecycle }): { Lifecycle }
	return graph:sort(systems)
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
