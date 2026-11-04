--!strict
--!nolint DeprecatedApi

-- One side of a game, loaded under Lune for the network lint: an Instance tree built from the
-- Rojo sourcemap, Roblox globals, a module cache and RunService answers of its own. A server world
-- and a client world live in one Lune VM without seeing each other, as two Roblox VMs would.
--
-- It emulates what game code touches while it boots, not the engine. Members the lint doesn't know
-- are permissive stand-ins (callable, indexable, connectable), so unknown engine APIs don't stop a
-- game from loading. Requiring something that isn't a module is still an error.

local nativeFs = (require :: any)("@lune/fs")

-- Lune's filesystem calls yield. The lint waits until none are in flight before it reads the
-- registries, so a large boot isn't cut short.
local pending = 0
local function tracked(name: string): any
	return function(...: any): ...any
		pending += 1
		local result = table.pack(pcall(nativeFs[name], ...))
		pending -= 1
		if not result[1] then
			error(result[2], 2)
		end
		return table.unpack(result, 2, result.n)
	end
end

local lune = {
	fs = {
		isFile = tracked("isFile"),
		isDir = tracked("isDir"),
		readDir = tracked("readDir"),
		readFile = tracked("readFile"),
	},
	luau = (require :: any)("@lune/luau"),
	roblox = (require :: any)("@lune/roblox"),
	serde = (require :: any)("@lune/serde"),
	task = (require :: any)("@lune/task"),
}

export type Side = "server" | "client"

-- A stack frame in game or package code: the file relative to the project, and the line.
export type Frame = {
	file: string,
	line: number,
	-- The Instance the file is, e.g. ServerScriptService.Server.Main, when the sourcemap has it.
	instance: string?,
}

export type Output = {
	text: string,
	frames: { Frame },
}

export type ScriptRun = {
	instance: string,
	file: string,
	status: "running" | "finished" | "errored",
	error: string?,
	-- Where it errored, or where it is waiting while still running.
	frames: { Frame },
	-- The network had started on this side when it errored.
	afterStart: boolean,
	thread: thread?,
}

export type Options = {
	side: Side,
	-- Absolute project directory; sourcemap paths are relative to it.
	root: string,
	sourcemap: any,
	-- Called after each module loads, before its requirer sees it.
	onLoad: ((world: World, file: string, value: any) -> ())?,
	-- Whether the network has started; read when a script errors.
	started: (() -> boolean)?,
}

export type World = {
	side: Side,
	root: string,
	game: any,
	globals: { [string]: any },
	warnings: { Output },
	prints: { Output },
	-- Instance paths the game used that aren't in the Rojo project; they got stand-ins.
	missing: { [string]: boolean },
	scripts: { ScriptRun },
	onLoad: ((world: World, file: string, value: any) -> ())?,
	started: (() -> boolean)?,

	require: (self: World, target: any) -> any,
	requireString: (self: World, from: string, path: string) -> any,
	load: (self: World, file: string) -> any,
	entryScripts: (self: World) -> { any },
	runScript: (self: World, node: any) -> ScriptRun,
	finish: (self: World) -> (),
	frames: (self: World, level: number, thread: thread?) -> { Frame },
	relative: (self: World, file: string) -> string,
	instanceOf: (self: World, file: string) -> string?,
	fullName: (self: World, node: any) -> string,

	_nodeByFile: { [string]: any },
	-- Nodes for modules outside the sourcemap.
	_fileNodes: { [string]: any },
	_sources: { [string]: string },
	_cache: { [string]: { done: boolean, value: any, failed: string? } },
	_aliases: { [string]: { [string]: string } },
	_errorFrames: { [string]: { Frame } },
	_dataModel: any,
	_localPlayer: any,
}

local EXTENSIONS = { ".luau", ".lua" }

local DATATYPES = {
	"Axes", "BrickColor", "CFrame", "Color3", "ColorSequence", "ColorSequenceKeypoint", "Content",
	"Enum", "Faces", "Font", "NumberRange", "NumberSequence", "NumberSequenceKeypoint",
	"PhysicalProperties", "Ray", "Rect", "Region3", "Region3int16", "UDim", "UDim2", "Vector2",
	"Vector2int16", "Vector3", "Vector3int16",
}

-- Enough of the class tree for IsA in game code.
local SUPERCLASS: { [string]: string } = {
	Script = "BaseScript",
	LocalScript = "Script",
	BaseScript = "LuaSourceContainer",
	ModuleScript = "LuaSourceContainer",
	Part = "FormFactorPart",
	FormFactorPart = "BasePart",
	MeshPart = "TriangleMeshPart",
	UnionOperation = "PartOperation",
	PartOperation = "TriangleMeshPart",
	TriangleMeshPart = "BasePart",
	BasePart = "PVInstance",
	Model = "PVInstance",
	Workspace = "WorldRoot",
	WorldRoot = "Model",
	ScreenGui = "LayerCollector",
	BillboardGui = "LayerCollector",
	SurfaceGui = "LayerCollector",
	LayerCollector = "GuiBase2d",
	Frame = "GuiObject",
	ScrollingFrame = "GuiObject",
	TextLabel = "GuiObject",
	TextBox = "GuiObject",
	ImageLabel = "GuiObject",
	TextButton = "GuiButton",
	ImageButton = "GuiButton",
	GuiButton = "GuiObject",
	GuiObject = "GuiBase2d",
	GuiBase2d = "GuiBase",
	RemoteEvent = "BaseRemoteEvent",
	UnreliableRemoteEvent = "BaseRemoteEvent",
	StringValue = "ValueBase",
	IntValue = "ValueBase",
	NumberValue = "ValueBase",
	BoolValue = "ValueBase",
	ObjectValue = "ValueBase",
	Tool = "BackpackItem",
}

local World = {}

---------------------------------------------------------------------------------------------
-- Paths

local function slashes(path: string): string
	return (string.gsub(path, "\\", "/"))
end

local function normalize(path: string, base: string): string
	path = slashes(path)
	local absolute = string.match(path, "^%a:/") ~= nil or string.sub(path, 1, 1) == "/"
	if not absolute then
		path = `{base}/{path}`
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

local function isInit(file: string): boolean
	return string.match(basename(file), "^init%.luau?$") ~= nil
end

-- The module path a file is: an init file is its folder.
local function modulePath(file: string): string
	local withoutExtension = string.gsub(file, "%.luau?$", "")
	if isInit(file) then
		return dirname(withoutExtension)
	end
	return withoutExtension
end

---------------------------------------------------------------------------------------------
-- Stand-ins for what the lint doesn't emulate

type NodeData = {
	node: any,
	world: World,
	name: string,
	className: string,
	parent: any?,
	children: { any },
	props: { [string]: any },
	attributes: { [string]: any },
	tags: { [string]: boolean },
	signals: { [string]: any },
	file: string?,
	-- A stand-in made because the game asked for something the Rojo project doesn't have.
	missing: boolean?,
}

local nodeData: { [any]: NodeData } = setmetatable({}, { __mode = "k" }) :: any
local signalObjects: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any
local connectionObjects: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local phantomNames: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any
local phantomChildren: { [any]: { [any]: any } } = setmetatable({}, { __mode = "k" }) :: any

local phantomMeta = {}

local function phantom(name: string): any
	local value = setmetatable({}, phantomMeta)
	phantomNames[value] = name
	phantomChildren[value] = {}
	return value
end

phantomMeta.__index = function(self: any, key: any): any
	local children = phantomChildren[self]
	local child = children[key]
	if child == nil then
		child = phantom(`{phantomNames[self]}.{tostring(key)}`)
		children[key] = child
	end
	return child
end
phantomMeta.__newindex = function() end
phantomMeta.__call = function(self: any): any
	return phantom(`{phantomNames[self]}()`)
end
phantomMeta.__iter = function(): any
	return next, {}
end
phantomMeta.__len = function(): number
	return 0
end
phantomMeta.__tostring = function(self: any): string
	return phantomNames[self]
end
phantomMeta.__concat = function(left: any, right: any): string
	return tostring(left) .. tostring(right)
end
for _, operator in { "__add", "__sub", "__mul", "__div", "__idiv", "__mod", "__pow", "__unm" } do
	(phantomMeta :: any)[operator] = function(self: any): any
		return if phantomNames[self] then self else phantom("value")
	end
end

local function newSignal(name: string): any
	local connections: { { callback: (...any) -> (), connection: any, once: boolean } } = {}
	local signal = {}

	local function connect(callback: (...any) -> (), once: boolean): any
		local connection = { Connected = true }
		connectionObjects[connection] = true
		function connection.Disconnect(self: any)
			self.Connected = false
		end
		table.insert(connections, { callback = callback, connection = connection, once = once })
		return connection
	end

	function signal.Connect(_: any, callback: (...any) -> ()): any
		return connect(callback, false)
	end
	signal.ConnectParallel = signal.Connect
	function signal.Once(_: any, callback: (...any) -> ()): any
		return connect(callback, true)
	end
	-- Engine events never fire here, so waiting would hang the game's boot: return at once.
	function signal.Wait(_: any): ...any
		return
	end
	-- For events the lint fires itself (BindableEvent:Fire).
	function signal._fire(...: any)
		for _, entry in table.clone(connections) do
			if entry.connection.Connected then
				if entry.once then
					entry.connection.Connected = false
				end
				lune.task.spawn(entry.callback, ...)
			end
		end
	end

	signalObjects[signal] = name
	return signal
end

---------------------------------------------------------------------------------------------
-- Instances

local nodeMeta = {}
local methods: { [string]: any } = {}
local newNode: (world: World, name: string, className: string, parent: any?) -> any
local makeNode: (world: World, name: string, className: string, parent: any?) -> any

local EVENTS = {
	ChildAdded = true, ChildRemoved = true, DescendantAdded = true, DescendantRemoving = true,
	AncestryChanged = true, Changed = true, Destroying = true, AttributeChanged = true,
}

-- Lune's filesystem calls yield, and a metamethod can't, so a folder's files become children
-- up front rather than on first look.
local function listInto(data: NodeData, directory: string, depth: number)
	local ok, entries = pcall(lune.fs.readDir, directory)
	if not ok or depth > 6 then
		return
	end
	table.sort(entries)
	for _, entry in entries do
		local path = `{directory}/{entry}`
		local name = string.gsub(entry, "%.luau?$", "")
		if name == "init" or string.sub(entry, 1, 1) == "." then
			continue
		end

		local child = nil
		if lune.fs.isDir(path) then
			local file = findFile(path)
			child = newNode(data.world, name, if file then "ModuleScript" else "Folder", nil)
			nodeData[child].file = file
			listInto(nodeData[child], path, depth + 1)
		elseif string.match(entry, "%.luau?$") then
			child = newNode(data.world, name, "ModuleScript", nil)
			nodeData[child].file = path
		end
		if child then
			nodeData[child].parent = data.node
			table.insert(data.children, child)
			local file = nodeData[child].file
			if file then
				data.world._fileNodes[string.lower(file)] = child
			end
		end
	end
end

local function childNamed(node: any, name: string): any?
	local data = nodeData[node]
	for _, child in data.children do
		if nodeData[child].name == name then
			return child
		end
	end
	return nil
end

local function isA(className: string, wanted: string): boolean
	if wanted == "Instance" then
		return true
	end
	local current: string? = className
	while current do
		if current == wanted then
			return true
		end
		current = SUPERCLASS[current]
	end
	return false
end

local function fullName(node: any): string
	local names = {}
	local current = node
	while current do
		local data = nodeData[current]
		if data.className == "DataModel" then
			break
		end
		table.insert(names, 1, data.name)
		current = data.parent
	end
	return table.concat(names, ".")
end

local function setParent(node: any, parent: any?)
	local data = nodeData[node]
	local old = data.parent
	if old == parent then
		return
	end
	if old then
		local siblings = nodeData[old].children
		local index = table.find(siblings, node)
		if index then
			table.remove(siblings, index)
		end
	end
	data.parent = parent
	if parent then
		local parentData = nodeData[parent]
		if parentData then
			table.insert(parentData.children, node)
			local signal = parentData.signals.ChildAdded
			if signal then
				signal._fire(node)
			end
		else
			data.parent = nil
		end
	end
end

function newNode(world: World, name: string, className: string, parent: any?): any
	local node = setmetatable({}, nodeMeta)
	nodeData[node] = {
		node = node,
		world = world,
		name = name,
		className = className,
		parent = nil,
		children = {},
		props = {},
		attributes = {},
		tags = {},
		signals = {},
		file = nil,
	}
	if parent then
		setParent(node, parent)
	end
	return node
end

nodeMeta.__index = function(self: any, key: string): any
	local data = nodeData[self]
	if key == "Name" then
		return data.name
	elseif key == "ClassName" then
		return data.className
	elseif key == "Parent" then
		return data.parent
	end

	local prop = data.props[key]
	if prop ~= nil then
		return prop
	end
	local method = methods[key]
	if method then
		return method
	end
	if EVENTS[key] then
		local signal = data.signals[key]
		if not signal then
			signal = newSignal(`{fullName(self)}.{key}`)
			data.signals[key] = signal
		end
		return signal
	end
	local child = childNamed(self, key)
	if child then
		return child
	end

	local name = `{fullName(self)}.{key}`
	local stand = phantom(name)
	data.props[key] = stand
	return stand
end

nodeMeta.__newindex = function(self: any, key: string, value: any)
	local data = nodeData[self]
	if key == "Name" then
		data.name = tostring(value)
	elseif key == "Parent" then
		setParent(self, if nodeData[value] then value else nil)
	else
		data.props[key] = value
	end
end

nodeMeta.__tostring = function(self: any): string
	return nodeData[self].name
end

local function standIn(node: any, name: string): any
	local data = nodeData[node]
	local path = `{fullName(node)}.{name}`
	data.world.missing[path] = true
	local child = newNode(data.world, name, "Folder", nil)
	nodeData[child].missing = true
	nodeData[child].parent = node
	return child
end

function methods.FindFirstChild(self: any, name: string, recursive: boolean?): any?
	local child = childNamed(self, name)
	if child or not recursive then
		return child
	end
	for _, descendant in methods.GetDescendants(self) do
		if nodeData[descendant].name == name then
			return descendant
		end
	end
	return nil
end

-- Engine objects (a map from the place file, an Instance another script makes at runtime) are
-- often missing from a Rojo project, so waiting for them would hang the boot. A stand-in Folder
-- lets the game carry on; requiring it still fails, with a message saying why.
function methods.WaitForChild(self: any, name: string, timeout: number?): any?
	local child = childNamed(self, name)
	if child then
		return child
	end
	if timeout then
		return nil
	end
	return standIn(self, name)
end

function methods.FindFirstChildOfClass(self: any, className: string): any?
	for _, child in nodeData[self].children do
		if nodeData[child].className == className then
			return child
		end
	end
	return nil
end

function methods.FindFirstChildWhichIsA(self: any, className: string, recursive: boolean?): any?
	local list = if recursive then methods.GetDescendants(self) else methods.GetChildren(self)
	for _, child in list do
		if isA(nodeData[child].className, className) then
			return child
		end
	end
	return nil
end

function methods.FindFirstDescendant(self: any, name: string): any?
	return methods.FindFirstChild(self, name, true)
end

function methods.FindFirstAncestor(self: any, name: string): any?
	local current = nodeData[self].parent
	while current and nodeData[current].name ~= name do
		current = nodeData[current].parent
	end
	return current
end

function methods.FindFirstAncestorOfClass(self: any, className: string): any?
	local current = nodeData[self].parent
	while current and nodeData[current].className ~= className do
		current = nodeData[current].parent
	end
	return current
end

function methods.FindFirstAncestorWhichIsA(self: any, className: string): any?
	local current = nodeData[self].parent
	while current and not isA(nodeData[current].className, className) do
		current = nodeData[current].parent
	end
	return current
end

function methods.GetChildren(self: any): { any }
	return table.clone(nodeData[self].children)
end

function methods.GetDescendants(self: any): { any }
	local all = {}
	local function walk(node: any)
		for _, child in nodeData[node].children do
			table.insert(all, child)
			walk(child)
		end
	end
	walk(self)
	return all
end

function methods.IsA(self: any, className: string): boolean
	return isA(nodeData[self].className, className)
end

function methods.IsDescendantOf(self: any, ancestor: any): boolean
	local current = nodeData[self].parent
	while current do
		if current == ancestor then
			return true
		end
		current = nodeData[current].parent
	end
	return false
end

function methods.IsAncestorOf(self: any, descendant: any): boolean
	return nodeData[descendant] ~= nil and methods.IsDescendantOf(descendant, self)
end

function methods.GetFullName(self: any): string
	return fullName(self)
end

function methods.Destroy(self: any)
	setParent(self, nil)
end
methods.Remove = methods.Destroy

function methods.ClearAllChildren(self: any)
	for _, child in methods.GetChildren(self) do
		setParent(child, nil)
	end
end

function methods.Clone(self: any): any
	local data = nodeData[self]
	local copy = newNode(data.world, data.name, data.className, nil)
	local copyData = nodeData[copy]
	copyData.file = data.file
	copyData.props = table.clone(data.props)
	copyData.attributes = table.clone(data.attributes)
	copyData.tags = table.clone(data.tags)
	for _, child in data.children do
		setParent(methods.Clone(child), copy)
	end
	return copy
end

function methods.GetAttribute(self: any, name: string): any
	return nodeData[self].attributes[name]
end

function methods.SetAttribute(self: any, name: string, value: any)
	nodeData[self].attributes[name] = value
end

function methods.GetAttributes(self: any): { [string]: any }
	return table.clone(nodeData[self].attributes)
end

function methods.GetAttributeChangedSignal(self: any, name: string): any
	return newSignal(`{fullName(self)}:GetAttributeChangedSignal("{name}")`)
end

function methods.GetPropertyChangedSignal(self: any, name: string): any
	return newSignal(`{fullName(self)}:GetPropertyChangedSignal("{name}")`)
end

function methods.AddTag(self: any, tag: string)
	nodeData[self].tags[tag] = true
end

function methods.RemoveTag(self: any, tag: string)
	nodeData[self].tags[tag] = nil
end

function methods.HasTag(self: any, tag: string): boolean
	return nodeData[self].tags[tag] == true
end

function methods.GetTags(self: any): { string }
	local tags = {}
	for tag in nodeData[self].tags do
		table.insert(tags, tag)
	end
	return tags
end

function methods.GetActor(): any?
	return nil
end

function methods.GetService(self: any, name: string): any
	local data = nodeData[self]
	for _, child in data.children do
		if nodeData[child].className == name then
			return child
		end
	end
	return makeNode(data.world, name, name, self)
end
methods.FindService = methods.GetService

---------------------------------------------------------------------------------------------
-- Engine members game code calls while booting

local function classDefaults(node: any)
	local data = nodeData[node]
	local props = data.props
	local className = data.className
	local name = fullName(node)

	if className == "RemoteEvent" or className == "UnreliableRemoteEvent" then
		props.OnServerEvent = newSignal(`{name}.OnServerEvent`)
		props.OnClientEvent = newSignal(`{name}.OnClientEvent`)
		props.FireServer = function() end
		props.FireClient = function() end
		props.FireAllClients = function() end
	elseif className == "RemoteFunction" then
		-- Hydrogen's ready handshake (id 0) gets an empty queue and matching names; the lint
		-- compares the names itself. Other calls have no other side to answer them, so they
		-- wait, as a call to a slow server would, instead of failing on a missing answer.
		props.InvokeServer = function(_: any, id: any): ...any
			if id == 0 then
				return {}, true
			end
			return coroutine.yield()
		end
		props.InvokeClient = function(): ...any
			return coroutine.yield()
		end
	elseif className == "BindableEvent" then
		local event = newSignal(`{name}.Event`)
		props.Event = event
		props.Fire = function(_: any, ...: any)
			event._fire(...)
		end
	elseif className == "BindableFunction" then
		props.Invoke = function(self: any, ...: any): ...any
			local callback = nodeData[self].props.OnInvoke
			if type(callback) == "function" then
				return callback(...)
			end
			return
		end
	elseif className == "Humanoid" then
		props.Health = 100
		props.MaxHealth = 100
		props.WalkSpeed = 16
	end
end

function makeNode(world: World, name: string, className: string, parent: any?): any
	local node = newNode(world, name, className, parent)
	classDefaults(node)
	return node
end

local function newPlayer(world: World): any
	local player = makeNode(world, "Player1", "Player", nil)
	local props = nodeData[player].props
	props.UserId = 1
	props.DisplayName = "Player1"
	props.AccountAge = 0
	props.Team = nil
	props.Kick = function() end
	props.GetMouse = function()
		return phantom("Player1:GetMouse()")
	end
	props.CharacterAdded = newSignal("Player1.CharacterAdded")
	props.CharacterRemoving = newSignal("Player1.CharacterRemoving")
	makeNode(world, "PlayerGui", "PlayerGui", player)
	makeNode(world, "PlayerScripts", "PlayerScripts", player)
	makeNode(world, "Backpack", "Backpack", player)

	-- A spawned character, so `player.Character or player.CharacterAdded:Wait()` doesn't wait.
	local character = makeNode(world, "Player1", "Model", nil)
	makeNode(world, "Humanoid", "Humanoid", character)
	makeNode(world, "HumanoidRootPart", "Part", character)
	makeNode(world, "Head", "Part", character)
	props.Character = character
	return player
end

local function installServices(world: World)
	local dataModel = world._dataModel
	local function service(name: string): any
		return methods.GetService(dataModel, name)
	end

	local server = world.side == "server"
	local runService = nodeData[service("RunService")].props
	runService.IsServer = function()
		return server
	end
	runService.IsClient = function()
		return not server
	end
	runService.IsStudio = function()
		return false
	end
	runService.IsRunning = function()
		return true
	end
	runService.IsRunMode = function()
		return false
	end
	runService.IsEdit = function()
		return false
	end
	-- No frames run while the lint boots the game.
	for _, event in { "Heartbeat", "Stepped", "RenderStepped", "PreSimulation", "PostSimulation", "PreRender", "PreAnimation" } do
		runService[event] = newSignal(`RunService.{event}`)
	end
	runService.BindToRenderStep = function() end
	runService.UnbindFromRenderStep = function() end

	local players = service("Players")
	local playersProps = nodeData[players].props
	playersProps.PlayerAdded = newSignal("Players.PlayerAdded")
	playersProps.PlayerRemoving = newSignal("Players.PlayerRemoving")
	playersProps.MaxPlayers = 8
	if server then
		playersProps.GetPlayers = function()
			return {}
		end
	else
		local player = newPlayer(world)
		world._localPlayer = player
		setParent(player, players)
		playersProps.LocalPlayer = player
		playersProps.GetPlayers = function()
			return { player }
		end
	end
	playersProps.GetPlayerByUserId = function(_: any, userId: number): any?
		local local_ = world._localPlayer
		return if local_ and userId == 1 then local_ else nil
	end
	playersProps.GetPlayerFromCharacter = function(): any?
		return nil
	end

	local http = nodeData[service("HttpService")].props
	http.JSONEncode = function(_: any, value: any): string
		return lune.serde.encode("json", value)
	end
	http.JSONDecode = function(_: any, text: string): any
		return lune.serde.decode("json", text)
	end
	local guid = 0
	http.GenerateGUID = function(_: any, braces: boolean?): string
		guid += 1
		local id = string.format("00000000-0000-4000-8000-%012d", guid)
		return if braces == false then id else `\{{id}\}`
	end

	local dataModelProps = nodeData[dataModel].props
	dataModelProps.PlaceId = 0
	dataModelProps.GameId = 0
	dataModelProps.CreatorId = 0
	dataModelProps.JobId = ""
	dataModelProps.PrivateServerId = ""
	dataModelProps.PrivateServerOwnerId = 0
	dataModelProps.Loaded = newSignal("game.Loaded")
	dataModelProps.IsLoaded = function()
		return true
	end
	dataModelProps.BindToClose = function() end

	-- Hydrogen's remotes, as the server would have made them, so its runtime starts on both sides.
	local replicatedStorage = service("ReplicatedStorage")
	for _, className in { "RemoteEvent", "UnreliableRemoteEvent", "RemoteFunction" } do
		if not childNamed(replicatedStorage, `HydrogenNetwork{className}`) then
			makeNode(world, `HydrogenNetwork{className}`, className, replicatedStorage)
		end
	end
end

---------------------------------------------------------------------------------------------
-- Globals

local function typeofIn(value: any): string
	if nodeData[value] then
		return "Instance"
	elseif signalObjects[value] then
		return "RBXScriptSignal"
	elseif connectionObjects[value] then
		return "RBXScriptConnection"
	end
	return typeof(value)
end

local function message(...: any): string
	local parts = table.pack(...)
	for index = 1, parts.n do
		parts[index] = tostring(parts[index])
	end
	return table.concat(parts :: any, " ", 1, parts.n)
end

local function installGlobals(world: World)
	local base = getfenv(0)
	local globals: { [string]: any } = setmetatable({}, { __index = base }) :: any
	world.globals = globals

	for _, name in DATATYPES do
		local value = lune.roblox[name]
		if value ~= nil then
			globals[name] = value
		end
	end

	globals.Instance = {
		new = function(className: string, parent: any?): any
			return makeNode(world, className, className, if nodeData[parent] then parent else nil)
		end,
		fromExisting = function(existing: any): any
			return methods.Clone(existing)
		end,
	}

	globals.Random = {
		new = function(seed: number?): any
			local random = {}
			local state = seed or os.clock()
			local function step(): number
				state = (state * 1103515245 + 12345) % 2147483648
				return state / 2147483648
			end
			function random.NextNumber(_: any, min: number?, max: number?): number
				local low, high = min or 0, max or 1
				return low + step() * (high - low)
			end
			function random.NextInteger(_: any, min: number, max: number): number
				return min + math.floor(step() * (max - min + 1))
			end
			function random.Clone(): any
				return globals.Random.new(state)
			end
			return random
		end,
	}
	globals.TweenInfo = {
		new = function(...: any): any
			return { ... }
		end,
	}
	globals.DateTime = {
		now = function(): any
			local seconds = os.time()
			return { UnixTimestamp = seconds, UnixTimestampMillis = seconds * 1000 }
		end,
		fromUnixTimestamp = function(seconds: number): any
			return { UnixTimestamp = seconds, UnixTimestampMillis = seconds * 1000 }
		end,
	}

	local began = os.clock()
	globals.game = world._dataModel
	globals.Game = world._dataModel
	globals.workspace = methods.GetService(world._dataModel, "Workspace")
	globals.Workspace = globals.workspace
	globals.task = lune.task
	globals.wait = lune.task.wait
	globals.delay = lune.task.delay
	globals.spawn = lune.task.defer
	globals.tick = os.clock
	globals.time = function(): number
		return os.clock() - began
	end
	globals.elapsedTime = globals.time
	globals.typeof = typeofIn
	globals.settings = function(): any
		return phantom("settings()")
	end
	globals.UserSettings = function(): any
		return phantom("UserSettings()")
	end
	globals.version = function(): string
		return "0.0.0.0"
	end
	globals.shared = {}
	globals._G = {}

	-- Game output would mix with the report (and break --json), so it is kept instead.
	globals.print = function(...: any)
		table.insert(world.prints, { text = message(...), frames = world:frames(2) })
	end
	globals.warn = function(...: any)
		table.insert(world.warnings, { text = message(...), frames = world:frames(2) })
	end
end

---------------------------------------------------------------------------------------------
-- Building the tree

local function build(world: World, entry: any, parent: any?): any
	local node = makeNode(world, entry.name, entry.className, nil)
	for _, path in entry.filePaths or {} do
		if string.match(path, "%.luau?$") then
			local file = normalize(path, world.root)
			nodeData[node].file = file
			world._nodeByFile[string.lower(file)] = node
			break
		end
	end
	if parent then
		nodeData[node].parent = parent
		table.insert(nodeData[parent].children, node)
	end
	for _, child in entry.children or {} do
		build(world, child, node)
	end
	return node
end

---------------------------------------------------------------------------------------------
-- require

local WorldMethods = {}

function WorldMethods.relative(self: World, file: string): string
	local root = self.root
	if string.lower(string.sub(file, 1, #root + 1)) == string.lower(root .. "/") then
		return string.sub(file, #root + 2)
	end
	-- Outside the project: walk up from it, so the path still reads relative.
	local rootParts = string.split(root, "/")
	local fileParts = string.split(file, "/")
	local shared = 0
	while shared < #rootParts and shared < #fileParts and string.lower(rootParts[shared + 1]) == string.lower(fileParts[shared + 1]) do
		shared += 1
	end
	if shared == 0 then
		return file
	end
	local parts = {}
	for _ = shared + 1, #rootParts do
		table.insert(parts, "..")
	end
	for index = shared + 1, #fileParts do
		table.insert(parts, fileParts[index])
	end
	return table.concat(parts, "/")
end

function WorldMethods.instanceOf(self: World, file: string): string?
	local node = self._nodeByFile[string.lower(file)]
	return if node then fullName(node) else nil
end

function WorldMethods.fullName(_self: World, node: any): string
	return if nodeData[node] then fullName(node) else tostring(node)
end

-- The game's frames on the stack, innermost first, from `level` (1 is the caller of frames).
function WorldMethods.frames(self: World, level: number, thread: thread?): { Frame }
	local frames: { Frame } = {}
	local index = level + 1
	while true do
		local source, line
		if thread then
			source, line = debug.info(thread, index - 1, "sl")
		else
			source, line = debug.info(index, "sl")
		end
		if source == nil then
			break
		end
		local file = self._sources[source]
		if file and line and line > 0 then
			table.insert(frames, { file = self:relative(file), line = line, instance = self:instanceOf(file) })
		end
		index += 1
		if index > 200 then
			break
		end
	end
	return frames
end

-- .luaurc aliases for a folder, inherited from its parents.
local function readAliases(world: World, directory: string): { [string]: string }
	local cached = world._aliases[directory]
	if cached then
		return cached
	end

	local aliases: { [string]: string } = {}
	local parent = dirname(directory)
	if parent ~= directory then
		for name, target in readAliases(world, parent) do
			aliases[name] = target
		end
	end

	local file = `{directory}/.luaurc`
	if lune.fs.isFile(file) then
		local source = string.gsub(lune.fs.readFile(file), ",(%s*[}%]])", "%1")
		local ok, config = pcall(lune.serde.decode, "json", source)
		if ok and type(config) == "table" and type(config.aliases) == "table" then
			for name, target in config.aliases do
				aliases[string.lower(name)] = normalize(`{directory}/{target}`, world.root)
			end
		end
	end

	world._aliases[directory] = aliases
	return aliases
end

-- Require-by-string as Roblox does it: relative to the file's folder, except in an init file,
-- whose own folder is @self.
local function resolve(world: World, file: string, path: string): string
	local folder = dirname(file)
	local base = if isInit(file) then dirname(folder) else folder

	local alias, rest = string.match(path, "^@([^/]+)/?(.*)$")
	if alias then
		if alias == "self" then
			return normalize(`{folder}/{rest}`, world.root)
		end
		local target = readAliases(world, folder)[string.lower(alias)]
		if not target then
			error(`[HYDROGEN] Unknown require alias @{alias} in {world:relative(file)}; add it to a .luaurc`, 3)
		end
		return if rest == "" then target else normalize(`{target}/{rest}`, world.root)
	end

	return normalize(`{base}/{path}`, world.root)
end

-- A node for a module that isn't in the sourcemap (a string require into a package), with
-- children read from disk so require(script.Child) inside it still works.
local function fileNode(world: World, file: string): any
	local path = modulePath(file)
	local node = makeNode(world, basename(path), "ModuleScript", nil)
	nodeData[node].file = file
	if isInit(file) then
		listInto(nodeData[node], path, 1)
	end
	world._fileNodes[string.lower(file)] = node
	return node
end

local function execute(world: World, file: string, node: any): any
	local debugName = world:relative(file)
	world._sources[debugName] = file

	local environment = setmetatable({
		script = node,
		require = function(target: any): any
			if type(target) == "string" then
				return world:requireString(file, target)
			end
			return world:require(target)
		end,
	}, { __index = world.globals })

	local chunk = lune.luau.load(lune.fs.readFile(file), {
		debugName = `@{debugName}`,
		environment = environment,
		injectGlobals = false,
	})

	-- Keep where the error happened: rethrowing below loses the stack.
	local result = table.pack(xpcall(chunk, function(err: any): any
		local text = tostring(err)
		if not world._errorFrames[text] then
			world._errorFrames[text] = world:frames(2)
		end
		return err
	end))
	if not result[1] then
		error(result[2], 0)
	end
	return result[2]
end

function WorldMethods.load(self: World, file: string): any
	local key = string.lower(file)
	local entry = self._cache[key]
	if entry then
		if entry.failed then
			error(`Requested module experienced an error while loading: {self:relative(file)}`, 3)
		elseif not entry.done then
			error(`[HYDROGEN] Cyclic require of {self:relative(file)}`, 3)
		end
		return entry.value
	end

	local record = { done = false, value = nil :: any, failed = nil :: string? }
	self._cache[key] = record

	local node = self._nodeByFile[key] or self._fileNodes[key] or fileNode(self, file)
	local ok, value = pcall(execute, self, file, node)
	if not ok then
		-- Roblox doesn't run a failed module again, which here would register its objects twice.
		record.failed = tostring(value)
		error(value, 0)
	end

	record.value = value
	record.done = true
	if self.onLoad then
		self.onLoad(self, file, value)
	end
	return value
end

-- require("path") from a file.
function WorldMethods.requireString(self: World, from: string, path: string): any
	if string.sub(path, 1, 6) == "@lune/" then
		return (require :: any)(path)
	end
	local resolved = resolve(self, from, path)
	local found = findFile(resolved)
	if not found then
		error(`[HYDROGEN] Can't find module {path} (looked for {self:relative(resolved)}) required from {self:relative(from)}`, 3)
	end
	return self:load(found)
end

-- require(instance).
function WorldMethods.require(self: World, target: any): any
	local data = nodeData[target]
	if data then
		if data.missing then
			error(`[HYDROGEN] require({fullName(target)}): it isn't in the Rojo project, so the lint can't load it`, 3)
		end
		local file = data.file
		if not file or data.className ~= "ModuleScript" then
			error(`[HYDROGEN] require({fullName(target)}): it is a {data.className}, not a ModuleScript`, 3)
		end
		return self:load(file)
	end
	if phantomNames[target] then
		error(`[HYDROGEN] require({phantomNames[target]}): it isn't in the Rojo project, so the lint can't load it`, 3)
	end
	if type(target) == "number" then
		error(`[HYDROGEN] require({target}): the lint can't load modules by asset id`, 3)
	end
	error(`[HYDROGEN] require expects a ModuleScript or a path, got {typeof(target)}`, 3)
end

---------------------------------------------------------------------------------------------
-- Scripts

local function scriptSide(data: NodeData): Side?
	local file = data.file
	if not file then
		return nil
	end
	if data.className == "LocalScript" then
		return "client"
	elseif data.className == "Script" then
		-- RunContext scripts (Rojo with emitLegacyScripts off) are all Scripts; the name says which.
		if string.match(file, "%.client%.luau?$") then
			return "client"
		end
		return "server"
	end
	return nil
end

-- With runContextOnly, only scripts that run wherever they are (RunContext Client or Server).
local function scriptsIn(container: any?, side: Side, into: { any }, runContextOnly: boolean?)
	if not container then
		return
	end
	local list = { container }
	for _, descendant in methods.GetDescendants(container) do
		table.insert(list, descendant)
	end
	for _, node in list do
		local data = nodeData[node]
		if scriptSide(data) == side then
			local runsAnywhere = data.className == "Script" and string.match(data.file :: string, `%.{side}%.luau?$`) ~= nil
			if runsAnywhere or not runContextOnly then
				table.insert(into, node)
			end
		end
	end
end

-- The scripts Roblox would run on this side, in the order it runs them. On the client, the
-- Starter folders are first copied into the player, and their scripts run from the copies.
function WorldMethods.entryScripts(self: World): { any }
	local dataModel = self._dataModel
	local scripts = {}

	if self.side == "server" then
		for _, serviceName in { "ServerScriptService", "Workspace" } do
			scriptsIn(childNamed(dataModel, serviceName), "server", scripts)
		end
		scriptsIn(childNamed(dataModel, "ReplicatedStorage"), "server", scripts, true)
		return scripts
	end

	local player = self._localPlayer
	local playerData = nodeData[player]
	local function copyInto(from: any?, into: any)
		if from then
			for _, child in methods.GetChildren(from) do
				setParent(methods.Clone(child), into)
			end
		end
	end
	local starterPlayer = childNamed(dataModel, "StarterPlayer")
	local playerScripts = methods.FindFirstChild(player, "PlayerScripts")
	local playerGui = methods.FindFirstChild(player, "PlayerGui")
	local backpack = methods.FindFirstChild(player, "Backpack")
	local character = playerData.props.Character

	copyInto(starterPlayer and childNamed(starterPlayer, "StarterPlayerScripts"), playerScripts)
	copyInto(childNamed(dataModel, "StarterGui"), playerGui)
	copyInto(childNamed(dataModel, "StarterPack"), backpack)
	copyInto(starterPlayer and childNamed(starterPlayer, "StarterCharacterScripts"), character)

	scriptsIn(childNamed(dataModel, "ReplicatedFirst"), "client", scripts)
	scriptsIn(playerScripts, "client", scripts)
	scriptsIn(playerGui, "client", scripts)
	for _, serviceName in { "ReplicatedStorage", "Workspace" } do
		scriptsIn(childNamed(dataModel, serviceName), "client", scripts, true)
	end
	-- The character spawns after the player's scripts have started.
	scriptsIn(backpack, "client", scripts)
	scriptsIn(character, "client", scripts)
	return scripts
end

function WorldMethods.runScript(self: World, node: any): ScriptRun
	local data = nodeData[node]
	local file = data.file :: string
	local run: ScriptRun = {
		-- The client runs copies of the Starter scripts; name the one in the project.
		instance = self:instanceOf(file) or fullName(node),
		file = self:relative(file),
		status = "running",
		error = nil,
		frames = {},
		afterStart = false,
		thread = nil,
	}
	table.insert(self.scripts, run)

	run.thread = lune.task.spawn(function()
		local ok, err = pcall(execute, self, file, node)
		if ok then
			run.status = "finished"
			return
		end
		run.status = "errored"
		run.error = tostring(err)
		run.frames = self._errorFrames[tostring(err)] or {}
		run.afterStart = self.started ~= nil and self.started()
	end)
	return run
end

-- Records where each script that is still running is waiting.
function WorldMethods.finish(self: World)
	for _, run in self.scripts do
		local thread = run.thread
		if run.status == "running" and thread then
			run.frames = self:frames(0, thread)
		end
	end
end

function World.new(options: Options): World
	local world = {
		side = options.side,
		root = slashes(options.root),
		warnings = {},
		prints = {},
		missing = {},
		scripts = {},
		onLoad = options.onLoad,
		started = options.started,
		_nodeByFile = {},
		_fileNodes = {},
		_sources = {},
		_cache = {},
		_aliases = {},
		_errorFrames = {},
	} :: any
	for name, method in WorldMethods do
		world[name] = method
	end

	local sourcemap = options.sourcemap
	if type(sourcemap) ~= "table" or sourcemap.className ~= "DataModel" then
		error(`[HYDROGEN] The Rojo project's root must be a DataModel (a game project); got {if type(sourcemap) == "table" then sourcemap.className else type(sourcemap)}`, 2)
	end
	world._dataModel = build(world, sourcemap, nil)
	nodeData[world._dataModel].name = "Game"
	installServices(world)
	installGlobals(world)

	return world :: World
end

-- Whether a node lives where only the server can see it (ServerScriptService, ServerStorage).
function World.serverOnly(instance: string?): boolean
	if not instance then
		return false
	end
	local service = string.match(instance, "^([^%.]+)")
	return service == "ServerScriptService" or service == "ServerStorage"
end

-- Whether a node lives where only clients run it (StarterPlayer, StarterGui, the player's folders).
function World.clientOnly(instance: string?): boolean
	if not instance then
		return false
	end
	local service = string.match(instance, "^([^%.]+)")
	return service == "StarterPlayer" or service == "StarterGui" or service == "StarterPack" or service == "Players"
end

-- Whether either world is still reading files.
function World.busy(): boolean
	return pending > 0
end

World.normalize = normalize
World.findFile = findFile

return World
