--!strict

export type Node = {
	read id: string,
}

export type Graph<T> = {
	add: (self: Graph<T>, node: T) -> (),
	link: (self: Graph<T>, dependent: T, dependency: T) -> (),
	sort: (self: Graph<T>, nodes: { T }) -> { T },
}

local function nodeId<T>(node: T): string
	return (node :: Node).id
end

local function new<T>(): Graph<T>
	local edges: { [T]: { T } } = {}

	local graph = {} :: Graph<T>

	function graph.add(self: Graph<T>, node: T)
		if not edges[node] then
			edges[node] = {}
		end
	end

	function graph.link(self: Graph<T>, dependent: T, dependency: T)
		self:add(dependent)
		self:add(dependency)

		local deps = edges[dependent] :: { T }
		if not table.find(deps, dependency) then
			table.insert(deps, dependency)
		end
	end

	function graph.sort(self: Graph<T>, nodes: { T }): { T }
		local include: { [T]: boolean } = {}
		for _, node in nodes do
			include[node] = true
			self:add(node)
		end

		local visited: { [T]: boolean } = {}
		local visiting: { [T]: boolean } = {}
		local ordered: { T } = {}

		local function visit(node: T, chain: { T })
			if visited[node] then
				return
			end

			if visiting[node] then
				local cycle = {}
				local recording = false
				for _, step in chain do
					if step == node then
						recording = true
					end
					if recording then
						table.insert(cycle, nodeId(step))
					end
				end
				table.insert(cycle, nodeId(node))
				error(`Cyclic system dependency: {table.concat(cycle, " -> ")}`)
			end

			visiting[node] = true
			table.insert(chain, node)

			for _, dependency in edges[node] :: { T } do
				if include[dependency] then
					visit(dependency, chain)
				else
					warn(`System {nodeId(node)} depends on system {nodeId(dependency)} which was not added to the app`)
				end
			end

			table.remove(chain)
			visiting[node] = nil
			visited[node] = true
			table.insert(ordered, node)
		end

		for _, node in nodes do
			visit(node, {})
		end

		return ordered
	end

	return graph
end

return {
	new = new,
}
