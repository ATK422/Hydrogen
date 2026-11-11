--!strict

-- Runs Roblox game code, Hydrogen systems and their tests under Lune (https://lune-org.github.io/docs).
-- It sets the Roblox globals from @lune/roblox and loads modules with a require that
-- understands Roblox code: relative and @self paths, .luaurc aliases, pesde's package links,
-- require(script.Parent.Module), and ModuleScript Instances registered in Lune.modules.
--
-- Load it with Lune's own require, before any game code:
--   local Lune = require("../roblox_packages/.pesde/atk422+hydrogen/<version>/hydrogen/src/Testing/Lune")
--   Lune.install()
--   Lune.require("test/Shop")
--
-- Nothing in a game requires this module, so it costs nothing there.

export type InstallOptions = {
	-- What RunService:IsServer() and IsClient() return. Both default to false: Hydrogen then
	-- leaves the Players service and BindToClose alone, and Hydrogen.test supplies players.
	server: boolean?,
	client: boolean?,
}

-- Stands in for a ModuleScript or Folder: a path on disk, walked like the Instance tree.
export type ScriptRef = {
	Name: string,
	Parent: ScriptRef?,
	FindFirstChild: (self: ScriptRef, name: string) -> ScriptRef?,
	WaitForChild: (self: ScriptRef, name: string, timeout: number?) -> ScriptRef,
	GetFullName: (self: ScriptRef) -> string,
	IsA: (self: ScriptRef, className: string) -> boolean,
}

local lune = {
	fs = (require :: any)("@lune/fs"),
	luau = (require :: any)("@lune/luau"),
	process = (require :: any)("@lune/process"),
	roblox = (require :: any)("@lune/roblox"),
	serde = (require :: any)("@lune/serde"),
	task = (require :: any)("@lune/task"),
}

local EXTENSIONS = { ".luau", ".lua" }
-- Roblox datatypes copied to globals when @lune/roblox has them.
local DATATYPES = {
	"Axes", "BrickColor", "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "Content",
	"Enum", "Faces", "Font", "Instance", "NumberRange", "NumberSequence", "NumberSequenceKeypoint",
	"PhysicalProperties", "Ray", "Rect", "Region3", "Region3int16", "UDim", "UDim2", "Vector2",
	"Vector2int16", "Vector3", "Vector3int16",
}

local Lune = {
	-- What require(instance) returns for a ModuleScript Instance, which Lune can't run.
	-- Also reachable as _G.instanceModules.
	modules = {} :: { [any]: any },
}

type Loaded = { done: boolean, value: any }

local globals = getfenv(0) :: { [string]: any }
local cache: { [string]: Loaded } = {}
local aliasCache: { [string]: { [string]: string } } = {}
local refs: { [string]: ScriptRef } = {}
local refPaths: { [ScriptRef]: string } = {}
local installed = false
local cwd = string.gsub(string.gsub(lune.process.cwd :: string, "\\", "/"), "/+$", "")

local function normalize(path: string): string
	path = string.gsub(path, "\\", "/")
	local absolute = string.match(path, "^%a:/") ~= nil or string.sub(path, 1, 1) == "/"
	if not absolute then
		path = `{cwd}/{path}`
	end

	local parts = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end

	local joined = table.concat(parts, "/")
	return if string.sub(path, 1, 1) == "/" then `/{joined}` else joined
end

local function dirname(path: string): string
	return string.match(path, "^(.*)/[^/]*$") or path
end

local function basename(path: string): string
	return string.match(path, "([^/]*)$") or path
end

-- The file a module path names: path.luau, path.lua, or path/init.luau.
local function findFile(path: string): string?
	for _, extension in EXTENSIONS do
		if lune.fs.isFile(path .. extension) then
			return path .. extension
		end
	end
	if lune.fs.isDir(path) then
		for _, extension in EXTENSIONS do
			local init = `{path}/init{extension}`
			if lune.fs.isFile(init) then
				return init
			end
		end
	end
	if string.match(path, "%.luau?$") and lune.fs.isFile(path) then
		return path
	end
	return nil
end

-- The module path a file is: an init file is its folder, as in Rojo.
local function modulePath(file: string): string
	local withoutExtension = string.gsub(file, "%.luau?$", "")
	if basename(withoutExtension) == "init" then
		return dirname(withoutExtension)
	end
	return withoutExtension
end

-- A Roblox-style full name relative to the working directory, e.g. src.Systems.Shop. Hydrogen
-- infers a system's id from it, as it does from GetFullName() in Roblox.
local function fullName(path: string): string
	local relative = path
	if string.lower(string.sub(path, 1, #cwd + 1)) == string.lower(cwd .. "/") then
		relative = string.sub(path, #cwd + 2)
	end
	return (string.gsub(relative, "/", "."))
end

local function ref(path: string): ScriptRef
	local existing = refs[path]
	if existing then
		return existing
	end

	local object = {} :: ScriptRef
	refs[path] = object
	refPaths[object] = path

	setmetatable(object :: any, {
		__index = function(_, key: string): any
			if key == "Name" then
				return basename(path)
			elseif key == "Parent" then
				local parent = dirname(path)
				return if parent == path then nil else ref(parent)
			elseif key == "FindFirstChild" then
				return function(_: any, name: string): ScriptRef?
					local child = `{path}/{name}`
					return if findFile(child) or lune.fs.isDir(child) then ref(child) else nil
				end
			elseif key == "WaitForChild" then
				return function(_: any, name: string): ScriptRef
					local child = `{path}/{name}`
					if not (findFile(child) or lune.fs.isDir(child)) then
						error(`[HYDROGEN] {fullName(path)} has no child {name}`, 2)
					end
					return ref(child)
				end
			elseif key == "GetFullName" then
				return function(): string
					return fullName(path)
				end
			elseif key == "IsA" then
				return function(_: any, className: string): boolean
					if className == "ModuleScript" or className == "LuaSourceContainer" then
						return findFile(path) ~= nil
					end
					return className == "Folder" or className == "Instance"
				end
			end
			-- Like indexing an Instance's child.
			return ref(`{path}/{key}`)
		end,
		__tostring = function(): string
			return basename(path)
		end,
	})

	return object
end

-- .luaurc files can have trailing commas, which strict JSON doesn't allow.
local function readAliases(directory: string): { [string]: string }
	local cached = aliasCache[directory]
	if cached then
		return cached
	end

	local aliases: { [string]: string } = {}
	local parent = dirname(directory)
	if parent ~= directory then
		for name, target in readAliases(parent) do
			aliases[name] = target
		end
	end

	local file = `{directory}/.luaurc`
	if lune.fs.isFile(file) then
		local source = string.gsub(lune.fs.readFile(file), ",(%s*[}%]])", "%1")
		local ok, config = pcall(lune.serde.decode, "json", source)
		if ok and type(config) == "table" and type(config.aliases) == "table" then
			for name, target in config.aliases do
				aliases[string.lower(name)] = normalize(`{directory}/{target}`)
			end
		end
	end

	aliasCache[directory] = aliases
	return aliases
end

local load: (file: string) -> any

-- Where a string require from file points, following the require-by-string rules: paths
-- are relative to the file's folder, except in an init file, whose own folder is @self.
local function resolve(file: string, path: string): string
	local folder = dirname(file)
	local isInit = string.match(basename(file), "^init%.luau?$") ~= nil
	local base = if isInit then dirname(folder) else folder

	local alias, rest = string.match(path, "^@([^/]+)/?(.*)$")
	if alias then
		if alias == "self" then
			return normalize(`{folder}/{rest}`)
		end
		local target = readAliases(folder)[string.lower(alias)]
		if not target then
			error(`[HYDROGEN] Unknown require alias @{alias} in {file}; add it to a .luaurc`, 3)
		end
		return if rest == "" then target else normalize(`{target}/{rest}`)
	end

	return normalize(`{base}/{path}`)
end

local function requireFrom(file: string): (any) -> any
	return function(target: any): any
		if type(target) == "string" then
			if string.sub(target, 1, 6) == "@lune/" then
				return (require :: any)(target)
			end
			local path = resolve(file, target)
			local found = findFile(path)
			if not found then
				error(`[HYDROGEN] Can't find module {target} (looked for {path}) required from {file}`, 2)
			end
			return load(found)
		end

		local registered = Lune.modules[target]
		if registered ~= nil then
			return registered
		end
		-- Lune can hand out a new userdata for the same Instance (GetDescendants does), so
		-- compare with ==, which Lune defines for Instances.
		if typeof(target) == "Instance" then
			for key, value in Lune.modules do
				if key == target then
					return value
				end
			end
		end

		local refPath = refPaths[target]
		if refPath then
			local found = findFile(refPath)
			if not found then
				error(`[HYDROGEN] {fullName(refPath)} is not a module`, 2)
			end
			return load(found)
		end

		if typeof(target) == "Instance" then
			error(`[HYDROGEN] Lune can't run ModuleScript {target:GetFullName()}; register what it returns in Lune.modules[moduleScript]`, 2)
		end
		error(`[HYDROGEN] require expects a path, a script reference or a registered ModuleScript, got {typeof(target)}`, 2)
	end
end

function load(file: string): any
	file = normalize(file)
	local key = string.lower(file)
	local loaded = cache[key]
	if loaded then
		if not loaded.done then
			error(`[HYDROGEN] Cyclic require of {file}`, 3)
		end
		return loaded.value
	end

	loaded = { done = false, value = nil }
	cache[key] = loaded

	local environment = setmetatable({
		script = ref(modulePath(file)),
		require = requireFrom(file),
	}, { __index = globals })

	local chunk = lune.luau.load(lune.fs.readFile(file), {
		debugName = `={fullName(modulePath(file))}`,
		environment = environment,
		injectGlobals = false,
	})

	local ok, value = pcall(chunk)
	if not ok then
		cache[key] = nil
		error(value, 0)
	end

	loaded.value = value
	loaded.done = true
	return value
end

-- Loads a module (and everything it requires) with the Roblox-style require. Paths resolve
-- like a require in the calling file: relative to its folder, or through its .luaurc aliases.
function Lune.require(path: string): any
	if string.sub(path, 1, 6) == "@lune/" then
		return (require :: any)(path)
	end

	-- Lune names a script's chunk by its path, without the extension.
	local caller = normalize(debug.info(2, "s") :: string)
	local from = findFile(caller) or `{cwd}/_`
	local target = resolve(from, path)
	local found = findFile(target)
	if not found then
		error(`[HYDROGEN] Can't find module {path} (looked for {target})`, 2)
	end
	return load(found)
end

-- Sets the Roblox globals: game (a DataModel with the usual services and a RunService stub),
-- the datatypes, task, and a warn that Hydrogen.test can capture. Safe to call more than once.
-- @lune/roblox's CFrame.lookAt (Lune 0.10) faces the wrong way for any target with a Z
-- component, and returns NaN looking straight up or down. This one matches Roblox.
local function lookAt(cframe: any, vector3: any): (any, any, any?) -> any
	return function(at: any, target: any, up: any?): any
		local look = target - at
		if look.Magnitude < 1e-9 then
			return cframe.new(at)
		end
		look = look.Unit
		local right = look:Cross(up or vector3.new(0, 1, 0))
		if right.Magnitude < 1e-6 then
			right = vector3.new(1, 0, 0)
		end
		right = right.Unit
		return cframe.fromMatrix(at, right, right:Cross(look), -look)
	end
end

function Lune.install(options: InstallOptions?)
	if installed then
		return
	end
	installed = true

	local roblox = lune.roblox
	local dataModel = roblox.Instance.new("DataModel")

	for _, name in DATATYPES do
		if roblox[name] ~= nil then
			globals[name] = roblox[name]
		end
	end
	globals.CFrame = setmetatable({ lookAt = lookAt(roblox.CFrame, roblox.Vector3) }, { __index = roblox.CFrame })
	globals.task = lune.task

	-- Headless there are no frames: Heartbeat never fires. Hydrogen.test's fake clock steps time.
	local heartbeat = {
		Connect = function()
			return { Connected = true, Disconnect = function() end }
		end,
	}
	local server = options ~= nil and options.server == true
	local client = options ~= nil and options.client == true
	local runService = {
		Heartbeat = heartbeat,
		Stepped = heartbeat,
		RenderStepped = heartbeat,
		PreSimulation = heartbeat,
		PostSimulation = heartbeat,
		IsServer = function()
			return server
		end,
		IsClient = function()
			return client
		end,
		IsStudio = function()
			return false
		end,
		IsRunning = function()
			return true
		end,
	}

	local services: { [string]: any } = { RunService = runService }
	for _, name in { "ReplicatedStorage", "ReplicatedFirst", "ServerScriptService", "ServerStorage", "StarterPlayer", "Players", "Workspace", "Lighting" } do
		pcall(function()
			services[name] = dataModel:GetService(name)
		end)
	end

	globals.game = setmetatable({
		GetService = function(_: any, name: string): any
			return services[name] or dataModel:GetService(name)
		end,
		FindService = function(_: any, name: string): any
			return services[name] or dataModel:FindService(name)
		end,
		BindToClose = function() end,
	}, {
		__index = function(_, key: string): any
			return services[key] or dataModel[key]
		end,
	})
	globals.workspace = services.Workspace

	-- One Log for everything loaded here, so Hydrogen.test sees warn() from any module.
	local Log = load(findFile(`{dirname(dirname(normalize(debug.info(1, "s") :: string)))}/Log`) :: string)
	local output = globals.warn
	Log.output = function(message: string)
		output(message)
	end
	globals.warn = function(...: any)
		local parts = table.pack(...)
		for index = 1, parts.n do
			parts[index] = tostring(parts[index])
		end
		Log.warn(table.concat(parts :: any, " ", 1, parts.n))
	end

	globals._G.instanceModules = Lune.modules
end

return Lune
