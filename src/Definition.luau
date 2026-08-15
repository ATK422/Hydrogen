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
	result:setproperty(types.singleton("id"), nil)

	return result
end

export type Lifecycle = {
	read id: string,
	read init: (() -> ())?,
	read start: (() -> ())?,
}

export type System<T> = WithoutLifecycle<T>
export type Defined<T> = System<T> & Lifecycle

local Graph = require("./Graph")

type Registered<T> = T & {
	id: string,
	init: (() -> ())?,
	start: (() -> ())?,
}

local graph = Graph.new() :: Graph.Graph<Lifecycle>
local pending: { { Lifecycle } } = {}

local function use<T>(definition: T): WithoutLifecycle<T>
	local deps = pending[#pending]
	if deps then
		table.insert(deps, definition :: Lifecycle)
	end
	return definition :: WithoutLifecycle<T>
end

local Definition = {}

function Definition.define<T>(constructor: (use: typeof(use)) -> T): Defined<T>
	local deps: { Lifecycle } = {}
	table.insert(pending, deps)

	local system = constructor(use) :: Registered<T>
	system.id = string.match(debug.info(2, "s") :: string, "[^.]+$") :: string

	table.remove(pending)
	graph:add(system)
	for _, dependency in deps do
		graph:link(system, dependency)
	end

	return system :: Defined<T>
end

function Definition.order(systems: { Lifecycle }): { Lifecycle }
	return graph:sort(systems)
end

return Definition
