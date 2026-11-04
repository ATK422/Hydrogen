--!strict

-- Watches Hydrogen's network runtime inside one world while the game boots. It wraps the
-- runtime's methods on the loaded module tables (nothing in src/Network changes), recording each
-- registration with the stack that made it. After the boot, snapshot() reads the registries.

local lune = {
	fs = (require :: any)("@lune/fs"),
}

local World = require("./World")

type World = World.World
type Frame = World.Frame

export type Registration = {
	name: string,
	-- Where the game asked for it: the first frame outside Hydrogen.
	site: Frame?,
	frames: { Frame },
	-- Made by a Hydrogen kit module (State, PlayerState) on the game's behalf, e.g. State/<name>.
	via: string?,
	object: any,
}

-- What one side registered under a name, read after the boot.
export type Entry = {
	name: string,
	kind: string,
	encode: boolean,
	-- GreenTea's format() of the schemas: one for events, args and returns for functions.
	schema: string?,
	args: string?,
	returns: string?,
	-- Whether something on this side listens (events) or answers (functions).
	handled: boolean,
	registration: Registration,
}

export type FunctionIssue = {
	name: string,
	problem: "missing-returns" | "extra-arguments" | "not-tuples",
	site: Frame?,
	frames: { Frame },
}

-- A module app:addNetwork would loop on forever, and the path inside its value to the culprit.
export type Hang = {
	module: string,
	file: string?,
	path: string,
}

export type Snapshot = {
	side: World.Side,
	-- Hydrogen copies loaded on this side; each has a runtime of its own.
	runtimes: { string },
	started: boolean,
	-- The runtime's fingerprint of the names it assigned ids to (sent in the ready handshake).
	hash: string?,
	entries: { [string]: Entry },
	names: { string },
	duplicates: { { first: Registration, second: Registration } },
	late: { Registration },
	builders: { Registration },
	functionIssues: { FunctionIssue },
	addNetwork: { { containers: { string }, site: Frame? } },
	hangs: { Hang },
}

export type Probe = {
	world: World,
	root: string?,
	snapshot: (self: Probe) -> Snapshot,
	started: (self: Probe) -> boolean,
	-- Whether a frame is inside a Hydrogen copy this side loaded.
	isHydrogen: (self: Probe, frame: Frame) -> boolean,
}

local Probe = {}

local function safeFormat(schema: any): string?
	if type(schema) ~= "table" then
		return nil
	end
	local ok, text = pcall(function()
		return schema:format()
	end)
	return if ok then text else tostring(schema)
end

local function isTuple(value: any): boolean
	return type(value) == "table" and value.kind == "tuple"
end

function Probe.attach(world: World): Probe
	local runtimes: { { file: string, runtime: any } } = {}
	local roots: { string } = {}
	local byName: { [string]: Registration } = {}
	local order: { Registration } = {}
	local duplicates = {}
	local late = {}
	local builders: { { registration: Registration, called: boolean } } = {}
	local functionIssues: { FunctionIssue } = {}
	local addNetwork = {}
	local hangs: { Hang } = {}
	-- Objects whose registration the lint reported instead of passing on; they still count as objects.
	local swallowed: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	-- What each module returned, so a count can name the module it is counting.
	local loadedFiles: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

	local probe = { world = world, root = nil :: string? }

	-- The frame's path inside a Hydrogen copy (e.g. State/Wire.luau), or nil for game code.
	local function hydrogenPath(frame: Frame): string?
		local file = string.lower(frame.file)
		for _, root in roots do
			local prefix = string.lower(root) .. "/"
			if string.sub(file, 1, #prefix) == prefix then
				return string.sub(frame.file, #prefix + 1)
			end
		end
		return nil
	end

	-- The first frame outside Hydrogen, and the kit module in between if there is one.
	local function locate(frames: { Frame }): (Frame?, string?)
		local via = nil
		for _, frame in frames do
			local path = hydrogenPath(frame)
			if not path then
				return frame, via
			end
			local module = string.match(path, "^([^/]+)/")
			if module and module ~= "Network" and module ~= "Testing" then
				via = `Hydrogen.{module}`
			end
		end
		return frames[1], via
	end

	local function registration(name: string, object: any, frames: { Frame }): Registration
		local site, via = locate(frames)
		return { name = name, site = site, frames = frames, via = via, object = object }
	end

	local function patchRuntime(file: string, runtime: any)
		table.insert(runtimes, { file = file, runtime = runtime })
		-- src/Network/Runtime.luau: Hydrogen's src folder is two levels up.
		local root = world:relative(string.match(file, "^(.*)/[^/]+/[^/]+$") or file)
		table.insert(roots, root)
		probe.root = probe.root or root

		-- Hydrogen's count walks modules with `for _, child in value`, and a generic for calls a
		-- table with __call (a GreenTea schema, so any State object) as its iterator, forever.
		-- The lint counts with next, so it can't hang, and reports what the game's count would loop on.
		local okSource, source = pcall(lune.fs.readFile, file)
		local loops = okSource and string.find(source, "for _, child in value do", 1, true) ~= nil
		local function count(value: any, visited: { [any]: boolean }, path: string, hazard: { string? }): number
			if type(value) ~= "table" then
				return 0
			end
			if runtime.Objects[value] or swallowed[value] then
				return 1
			end
			if visited[value] then
				return 0
			end
			visited[value] = true
			local meta = getmetatable(value)
			if loops and type(meta) == "table" and meta.__call ~= nil and meta.__iter == nil and hazard[1] == nil then
				hazard[1] = path
				return 0
			end
			local total = 0
			for key, child in next, value do
				total += count(child, visited, `{path}.{tostring(key)}`, hazard)
			end
			return total
		end
		runtime.countObjects = function(_self: any, value: any, seen: { [any]: boolean }?): number
			local hazard: { string? } = {}
			local total = count(value, seen or {}, "", hazard)
			if hazard[1] and not seen then
				local file = loadedFiles[value]
				table.insert(hangs, {
					module = if file then (world:instanceOf(file) or world:relative(file)) else "a module",
					file = if file then world:relative(file) else nil,
					path = string.sub(hazard[1] :: string, 2),
				})
			end
			return total
		end

		local register = runtime.registerNetworkObject
		runtime.registerNetworkObject = function(self: any, name: string, object: any, ...: any)
			local record = registration(name, object, world:frames(2))
			if runtime.Initialized then
				-- The runtime would ignore it with a warning; the lint reports it instead.
				table.insert(late, record)
				swallowed[object] = true
				return
			end
			local first = byName[name]
			if first then
				-- The runtime errors here; carrying on lets the lint check the rest of the game.
				table.insert(duplicates, { first = first, second = record })
				swallowed[object] = true
				return
			end
			byName[name] = record
			table.insert(order, record)
			return register(self, name, object, ...)
		end
	end

	local function patchServerFunction(module: any)
		local new = module.new
		module.new = function(name: string, ...: any): any
			local builder = new(name, ...)
			local record = { registration = registration(name, nil, world:frames(2)), called = false }
			table.insert(builders, record)
			return function(...: any): any
				record.called = true
				return builder(...)
			end
		end
	end

	local function patchClientFunction(module: any)
		local new = module.new
		module.new = function(name: string, args: any, returns: any, ...: any): any
			local problem: ("missing-returns" | "extra-arguments" | "not-tuples")? = nil
			if returns == nil then
				problem = "missing-returns"
			elseif select("#", ...) > 0 then
				problem = "extra-arguments"
			elseif not (isTuple(args) and isTuple(returns)) then
				problem = "not-tuples"
			end
			if problem then
				local frames = world:frames(2)
				local site = locate(frames)
				table.insert(functionIssues, { name = name, problem = problem :: any, site = site, frames = frames })
			end
			return new(name, args, returns, ...)
		end
	end

	local function patchApp(module: any)
		local add = module.addNetwork
		module.addNetwork = function(self: any, ...: any)
			local containers = {}
			for _, container in { ... } do
				table.insert(containers, world:fullName(container))
			end
			local site = locate(world:frames(2))
			table.insert(addNetwork, { containers = containers, site = site })
			return add(self, ...)
		end
	end

	local previous = world.onLoad
	world.onLoad = function(loadedWorld: World, file: string, value: any)
		if previous then
			previous(loadedWorld, file, value)
		end
		if type(value) ~= "table" then
			return
		end
		loadedFiles[value] = file

		local relative = world:relative(file)
		if string.match(relative, "Network/Runtime%.luau?$") and type(value.registerNetworkObject) == "function" and type(value.RegisteredNames) == "table" then
			patchRuntime(file, value)
		elseif string.match(relative, "Network/ServerFunction%.luau?$") and type(value.new) == "function" then
			patchServerFunction(value)
		elseif string.match(relative, "Network/ClientFunction%.luau?$") and type(value.new) == "function" then
			patchClientFunction(value)
		elseif string.match(relative, "/App%.luau?$") and type(value.addNetwork) == "function" and type(value.start) == "function" then
			for _, root in roots do
				if string.lower(relative) == string.lower(`{root}/App.luau`) then
					patchApp(value)
				end
			end
		end
	end

	function probe.isHydrogen(_self: any, frame: Frame): boolean
		return hydrogenPath(frame) ~= nil
	end

	function probe.started(_self: any): boolean
		for _, entry in runtimes do
			if entry.runtime.Initialized then
				return true
			end
		end
		return false
	end

	function probe.snapshot(_self: any): Snapshot
		local entries: { [string]: Entry } = {}
		local names = {}
		for _, record in order do
			local object = record.object
			local kind = if type(object) == "table" and type(object._kind) == "string" then object._kind else "Unknown"
			local entry: Entry = {
				name = record.name,
				kind = kind,
				encode = false,
				schema = nil,
				args = nil,
				returns = nil,
				handled = false,
				registration = record,
			}
			if type(object) == "table" then
				if kind == "ServerEvent" or kind == "ClientEvent" then
					entry.encode = object._codec ~= nil
					entry.schema = safeFormat(object._schema)
					entry.handled = type(object._listeners) == "table" and next(object._listeners) ~= nil
				else
					entry.encode = object._argsCodec ~= nil
					entry.args = safeFormat(object._argsSchema)
					entry.returns = safeFormat(object._returnsSchema)
					entry.handled = object._callback ~= nil
				end
			end
			entries[record.name] = entry
			table.insert(names, record.name)
		end
		table.sort(names)

		local hash = nil
		local started = false
		for _, entry in runtimes do
			if entry.runtime.Initialized then
				started = true
				local ok, value = pcall(entry.runtime.namesHash, entry.runtime)
				hash = if ok then value else nil
			end
		end

		local uncalled = {}
		for _, builder in builders do
			if not builder.called then
				table.insert(uncalled, builder.registration)
			end
		end

		local runtimeFiles = {}
		for _, entry in runtimes do
			table.insert(runtimeFiles, world:relative(entry.file))
		end

		return {
			side = world.side,
			runtimes = runtimeFiles,
			started = started,
			hash = hash,
			entries = entries,
			names = names,
			duplicates = duplicates,
			late = late,
			builders = uncalled,
			functionIssues = functionIssues,
			addNetwork = addNetwork,
			hangs = hangs,
		}
	end

	return probe :: any
end

return Probe
