--!strict

-- characterAdded / characterRemoving system hooks, on Definition.hooks. A character is a
-- subject whose parent is its player, so its hooks run after the player's playerAdded hooks
-- and before their playerRemoving hooks, and each system's Scope.of(system, character) is
-- destroyed right after its characterRemoving. Nothing here runs until an app has a system
-- that defines one of the hooks.

local Definition = require("./Definition")
local Fake = require("@self/Fake")

type Feed = Definition.Feed

type Connection = {
	Disconnect: (any) -> (),
}

type Op = {
	add: boolean,
	character: Model,
}

-- One per player while the app has them.
type Watch = {
	player: Player,
	feed: Feed,
	source: Fake.Source,
	-- The character added last and not removed since.
	current: Model?,
	-- The character whose ancestry is watched. It outlives a stream-out, to see it come back.
	watched: Model?,
	ancestry: Connection?,
	-- The character feed:add is running for, which may still wait for playerAdded.
	adding: Model?,
	-- Adds and removes run one at a time, so the old character's characterRemoving has
	-- returned before the new one's characterAdded starts.
	queue: { Op },
	running: boolean,
	closed: boolean,
}

local function pump(watch: Watch)
	watch.running = true
	while not watch.closed do
		local op = table.remove(watch.queue, 1)
		if op == nil then
			break
		end
		if op.add then
			watch.adding = op.character
			watch.feed:add(op.character, { watch.player, op.character }, watch.player)
			watch.adding = nil
		else
			watch.feed:remove(op.character)
		end
	end
	watch.running = false
end

local function push(watch: Watch, add: boolean, character: Model)
	if not add then
		-- Still queued, so it never got a hook: it gets none.
		for index, op in watch.queue do
			if op.add and op.character == character then
				table.remove(watch.queue, index)
				return
			end
		end
		-- Still waiting for the player's playerAdded hooks: drop it now instead of after them.
		if watch.adding == character then
			task.spawn(watch.feed.remove, watch.feed, character)
		end
	end

	table.insert(watch.queue, { add = add, character = character })
	if not watch.running then
		task.spawn(pump, watch)
	end
end

local onAdded: (watch: Watch, character: Model) -> ()

local function onRemoving(watch: Watch, character: Model)
	if watch.closed or watch.current ~= character then
		return
	end
	watch.current = nil
	push(watch, false, character)
end

-- A character that leaves the DataModel without CharacterRemoving (destroyed, or streamed out
-- on a client) is removed; one that streams back in, still the player's character, is added again.
local function watchAncestry(watch: Watch, character: Model)
	if watch.watched == character then
		return
	end
	if watch.ancestry then
		watch.ancestry:Disconnect()
	end
	watch.watched = character
	watch.ancestry = watch.source.ancestry(character, function(present: boolean)
		if present then
			if watch.current == nil and watch.player.Character == character then
				onAdded(watch, character)
			end
		else
			onRemoving(watch, character)
		end
	end)
end

function onAdded(watch: Watch, character: Model)
	if watch.closed or watch.current == character then
		return
	end
	local previous = watch.current
	if previous then
		onRemoving(watch, previous)
	end
	watch.current = character
	watchAncestry(watch, character)
	push(watch, true, character)
end

-- Runs before the player's playerAdded hooks. The character's own hooks wait for those.
local function watchPlayer(feed: Feed, player: Player): () -> ()
	local source = Fake.source(player)
	local watch: Watch = {
		player = player,
		feed = feed,
		source = source,
		current = nil,
		watched = nil,
		ancestry = nil,
		adding = nil,
		queue = {},
		running = false,
		closed = false,
	}

	local added = source.CharacterAdded:Connect(function(character: Model)
		onAdded(watch, character)
	end)
	local removing = source.CharacterRemoving:Connect(function(character: Model)
		onRemoving(watch, character)
	end)

	local existing = player.Character
	if existing then
		onAdded(watch, existing)
	end

	-- After the player's playerRemoving hooks; their character was removed before those.
	return function()
		watch.closed = true
		table.clear(watch.queue)
		added:Disconnect()
		removing:Disconnect()
		if watch.ancestry then
			watch.ancestry:Disconnect()
			watch.ancestry = nil
		end
	end
end

Definition.hooks({
	name = "character",
	added = "characterAdded",
	removing = "characterRemoving",
	player = watchPlayer,
})

local Character = {}

-- Tests only: gives a loopback player a character, as LoadCharacter would. A character they
-- already have is removed first. Without a model, makes one (Humanoid, HumanoidRootPart) in
-- workspace, destroyed when replaced or when the harness closes.
function Character.spawnFake(player: Player, character: Model?): Model
	return Fake.spawn(player, character)
end

-- Tests only: removes a loopback player's character, as when it's destroyed.
function Character.removeFake(player: Player)
	Fake.remove(player)
end

-- Tests only: moves a loopback player's character out of the DataModel (streamedIn false) or
-- back in, as streaming does on a client. Out runs characterRemoving; back in runs characterAdded.
function Character.streamFake(player: Player, streamedIn: boolean)
	Fake.stream(player, streamedIn)
end

-- Used by Hydrogen itself: the harness calls this when it closes.
Character._reset = Fake.reset

return Character
