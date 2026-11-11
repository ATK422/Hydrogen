--!strict

-- Characters for loopback players. Those are tables with no CharacterAdded, CharacterRemoving
-- or LoadCharacter, so tests spawn characters through here and the character hooks listen here.

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type Signal = {
	Connect: (self: Signal, callback: (Model) -> ()) -> Connection,
}

-- What the character hooks listen to: a real Player's signals, or fakes for a loopback player.
export type Source = {
	CharacterAdded: Signal,
	CharacterRemoving: Signal,
	-- Calls back with whether the character is in the DataModel whenever its ancestry changes:
	-- destroyed, or streamed out or back in on a client.
	ancestry: (character: Model, callback: (present: boolean) -> ()) -> Connection,
}

type FakeSignal = Signal & {
	_callbacks: { (Model) -> () },
}

local Fake = {}

local sources: { [any]: Source } = setmetatable({}, { __mode = "k" }) :: any
-- Fake characters' ancestry listeners, for streamFake.
local ancestries: { [Model]: { (present: boolean) -> () } } = setmetatable({}, { __mode = "k" }) :: any
-- Models spawn made, so replacing or resetting destroys them as Roblox destroys old characters.
local made: { [Model]: boolean } = {}

local function signal(): FakeSignal
	local callbacks: { (Model) -> () } = {}
	local fake = { _callbacks = callbacks } :: FakeSignal

	function fake.Connect(_: Signal, callback: (Model) -> ()): Connection
		table.insert(callbacks, callback)
		local connection = { Connected = true } :: Connection
		function connection.Disconnect(self: Connection)
			self.Connected = false
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
			end
		end
		return connection
	end

	return fake
end

-- Each callback in its own thread, as with a Roblox signal.
local function fire(target: Signal, character: Model)
	for _, callback in table.clone((target :: FakeSignal)._callbacks) do
		task.spawn(callback, character)
	end
end

-- Parents a fake character to workspace, or takes it out. Only when workspace is an Instance:
-- create_hydrogen's test runtime makes it a stand-in table, which can't hold a real Model.
-- Loopback players track presence through the ancestry callbacks, so nothing depends on it.
local function place(model: Model, present: boolean)
	if typeof(workspace) == "Instance" then
		model.Parent = if present then workspace else nil
	end
end

local function build(player: Player): Model
	local model = Instance.new("Model")
	model.Name = player.Name

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Size = Vector3.new(2, 2, 1)
	root.Parent = model
	model.PrimaryPart = root

	local humanoid = Instance.new("Humanoid")
	-- Roblox's defaults; under Lune, Health has none and reading it errors.
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = model

	place(model, true)
	return model
end

local function realAncestry(character: Model, callback: (present: boolean) -> ()): Connection
	return character.AncestryChanged:Connect(function()
		callback(character:IsDescendantOf(game))
	end) :: any
end

local function fakeAncestry(character: Model, callback: (present: boolean) -> ()): Connection
	local listeners = ancestries[character]
	if listeners == nil then
		listeners = {}
		ancestries[character] = listeners
	end
	table.insert(listeners, callback)

	local connection = { Connected = true } :: Connection
	function connection.Disconnect(self: Connection)
		self.Connected = false
		local index = table.find(listeners, callback)
		if index then
			table.remove(listeners, index)
		end
	end
	return connection
end

function Fake.source(player: Player): Source
	local source = sources[player]
	if source then
		return source
	end

	if typeof(player) == "Instance" then
		source = {
			CharacterAdded = player.CharacterAdded :: any,
			CharacterRemoving = player.CharacterRemoving :: any,
			ancestry = realAncestry,
		}
	else
		source = {
			CharacterAdded = signal(),
			CharacterRemoving = signal(),
			ancestry = fakeAncestry,
		}
	end
	sources[player] = source
	return source :: Source
end

local function checkPlayer(player: any, what: string)
	if typeof(player) == "Instance" then
		error(`[HYDROGEN] {what} is for loopback players; for a real player call player:LoadCharacter()`, 3)
	end
	if type(player) ~= "table" then
		error(`[HYDROGEN] {what} expects a player from t:join() or loopback:join(), got {typeof(player)}`, 3)
	end
end

function Fake.remove(player: Player)
	checkPlayer(player, "removeCharacter")
	local old = player.Character
	if old == nil then
		return
	end

	-- The hooks see player.Character still set, as during Roblox's CharacterRemoving.
	fire(Fake.source(player).CharacterRemoving, old)
	if player.Character == old then
		(player :: any).Character = nil
	end
	if made[old] then
		made[old] = nil
		old:Destroy()
	end
end

function Fake.spawn(player: Player, character: Model?): Model
	checkPlayer(player, "spawnCharacter")
	if character ~= nil and (typeof(character) ~= "Instance" or not character:IsA("Model")) then
		error(`[HYDROGEN] spawnCharacter expects a Model as the character, got {typeof(character)}`, 3)
	end

	-- Like LoadCharacter: the old character goes first.
	Fake.remove(player)

	local model = character or build(player)
	if character == nil then
		made[model] = true
	end
	(player :: any).Character = model
	fire(Fake.source(player).CharacterAdded, model)
	return model
end

-- Moves a loopback player's character out of the DataModel or back in, as streaming does on a
-- client, without CharacterRemoving or CharacterAdded.
function Fake.stream(player: Player, present: boolean)
	checkPlayer(player, "streamCharacter")
	local character = player.Character
	if character == nil then
		error(`[HYDROGEN] streamCharacter: {player.Name} has no character; spawn one first`, 3)
	end
	place(character, present)
	for _, callback in table.clone(ancestries[character] or {}) do
		task.spawn(callback, present)
	end
end

-- Destroys every model spawn made and forgets the listeners. The harness calls this on close.
function Fake.reset()
	for model in made do
		pcall(model.Destroy, model)
	end
	table.clear(made)
	table.clear(sources)
	table.clear(ancestries)
end

return Fake
