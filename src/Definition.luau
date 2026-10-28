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

local function describe(system: Lifecycle): string
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

return Definition
