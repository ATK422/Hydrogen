local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Log = require("../Log")
local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

-- Stands in for the remotes and the Players service so one VM is the server and every
-- client at once. Messages still go through ids, middleware, validation and the handshake.
export type Loopback = {
	-- Adds a fake client and runs playerAdded hooks for it. Once the network runs, it also
	-- does the client's ready handshake, delivering anything queued for it.
	join: (self: Loopback, name: string?) -> Player,
	-- Runs playerRemoving hooks; later sends to the player are dropped.
	leave: (self: Loopback, player: Player) -> (),
	players: (self: Loopback) -> { Player },
	-- Runs fn as that client: client events and functions fired inside it come from player.
	as: (self: Loopback, player: Player, fn: (...any) -> ...any, ...any) -> ...any,
	-- The client the running code acts as: inside as, or while a server message is delivered to
	-- it. nil while the server handles a client's message.
	client: (self: Loopback) -> Player?,
	-- Removes the remaining players, undoes listeners and middleware added since the loopback
	-- was created, and stops the network so the next test can start it again.
	close: (self: Loopback) -> (),

	-- Used by Hydrogen itself.
	owns: (self: Loopback, value: any) -> boolean,
	handshake: (self: Loopback) -> (),
	watch: (self: Loopback, added: (Player) -> (), removing: (Player) -> ()) -> (),
}

type Watcher = {
	added: (Player) -> (),
	removing: (Player) -> (),
}

type Signal = {
	Connect: (self: Signal, callback: (...any) -> ()) -> (),
	_callbacks: { (...any) -> () },
}

-- What an object had when the loopback opened; what systems add while it runs is undone on close.
type Snapshot = {
	objects: { [any]: { [string]: any } },
	callbacks: { [string]: (...any) -> ...any },
	global: { Middleware.AnyMiddleware },
}

local CHAINS = { "_listeners", "_middleware", "_requestMiddleware", "_responseMiddleware" }

local function signal(): Signal
	local callbacks = {}
	return {
		_callbacks = callbacks,
		Connect = function(_, callback)
			table.insert(callbacks, callback)
		end,
	} :: Signal
end

local function deliver(callback: (...any) -> (), ...: any)
	local ok, err = xpcall(callback, debug.traceback, ...)
	if not ok then
		Log.warn(`[HYDROGEN] Loopback event handler failed: {err}`)
	end
end

-- Each handler gets its own thread, as with a real remote: it runs right away, but an error
-- or a yield in it doesn't reach the sender.
local function fire(target: Signal, ...: any)
	for _, callback in table.clone(target._callbacks) do
		task.spawn(deliver, callback, ...)
	end
end

local function refill(target: { any }, from: { any })
	table.clear(target)
	table.move(from, 1, #from, 1, target)
end

local function snapshot(): Snapshot
	local objects = {}
	for object in Runtime.Objects do
		local saved = {}
		for _, field in CHAINS do
			if object[field] then
				saved[field] = table.clone(object[field])
			end
		end
		saved._callback = object._callback
		objects[object] = saved
	end

	return {
		objects = objects,
		callbacks = table.clone(Runtime.FunctionCallbacks),
		global = table.clone(Middleware.global),
	}
end

local function restore(saved: Snapshot)
	for object, fields in saved.objects do
		for _, field in CHAINS do
			if fields[field] then
				refill(object[field], fields[field])
			end
		end
		object._callback = fields._callback
	end

	Runtime.FunctionCallbacks = table.clone(saved.callbacks)
	refill(Middleware.global, saved.global)
end

-- Back to before the network started. Registered names, ids and handlers stay.
local function disconnect()
	Runtime.Initialized = false
	Runtime.RemoteEvent = nil
	Runtime.UnreliableRemoteEvent = nil
	Runtime.RemoteFunction = nil
	Runtime.OutgoingQueue = {}
	Runtime.PlayerQueues = {}
	Runtime.ReadyPlayers = {}
	Runtime.DepartedPlayers = setmetatable({}, { __mode = "k" }) :: any
	Runtime.Batching = false
	Runtime.Batches = {}
	Runtime.ServerBatch = nil
	Runtime.Loopback = nil
end

local Loopback = {}

function Loopback.new(): Loopback
	if Runtime.Loopback then
		error(`[HYDROGEN] A loopback is already open; close it before opening another`, 2)
	end
	if Runtime.Initialized and (RunService:IsServer() or RunService:IsClient()) then
		error(`[HYDROGEN] Open the loopback before app:start(); the network is already running`, 2)
	end
	-- Start from an empty network: headless, an earlier app may have started one with no
	-- remotes, and events an earlier test queued would otherwise reach this test's clients.
	disconnect()

	local loopback = {} :: Loopback
	local players: { Player } = {}
	local owned: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local handshaken: { [Player]: boolean } = {}
	local watchers: { Watcher } = {}
	local current: Player? = nil
	local joined = 0
	local saved = snapshot()

	-- Remotes copy tables and drop their metatables, so a receiver never shares the sender's table.
	-- Fake players are tables too, but stand for Instances, which pass by reference.
	local function copy(value: any, seen: { [any]: any }): any
		if type(value) ~= "table" or owned[value] then
			return value
		end
		if seen[value] then
			return seen[value]
		end

		local result = {}
		seen[value] = result
		for key, inner in next, value do
			result[copy(key, seen)] = copy(inner, seen)
		end
		return result
	end

	local function copyArgs(...: any): ...any
		local args = table.pack(...)
		local seen = {}
		for index = 1, args.n do
			args[index] = copy(args[index], seen)
		end
		return table.unpack(args, 1, args.n)
	end

	-- While the server handles a message, code is running as the server, not as the client
	-- that sent it, so client() is nil there.
	local function asServer(fn: (...any) -> ...any, ...: any): ...any
		local previous = current
		current = nil
		local results = table.pack(pcall(fn, ...))
		current = previous

		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end

	local function sender(): Player
		if current then
			return current
		elseif #players == 1 then
			return players[1]
		elseif #players == 0 then
			error(`[HYDROGEN] A client sent a message over loopback before any client joined; call loopback:join() first`, 0)
		end
		error(`[HYDROGEN] {#players} loopback clients have joined; wrap client code in loopback:as(player, fn) to say which one is sending`, 0)
	end

	local function remoteEvent()
		local remote = {
			OnServerEvent = signal(),
			OnClientEvent = signal(),
		}

		function remote:FireServer(...: any)
			asServer(fire, remote.OnServerEvent, sender(), copyArgs(...))
		end

		-- A player who left gets nothing, as with a real remote.
		function remote:FireClient(player: Player, ...: any)
			if not table.find(players, player) then
				return
			end
			loopback:as(player, fire, remote.OnClientEvent, copyArgs(...))
		end

		return remote
	end

	local remoteFunction = {
		OnServerInvoke = nil :: ((...any) -> ...any)?,
		OnClientInvoke = nil :: ((...any) -> ...any)?,
	}

	function remoteFunction:InvokeServer(...: any): ...any
		local callback = remoteFunction.OnServerInvoke
		if not callback then
			error(`[HYDROGEN] Loopback server has no OnServerInvoke; is the network started?`, 0)
		end
		return copyArgs(asServer(callback, sender(), copyArgs(...)))
	end

	function remoteFunction:InvokeClient(player: Player, ...: any): ...any
		if not table.find(players, player) then
			error(`[HYDROGEN] Can't invoke {player.Name}: the player has left`, 0)
		end
		local callback = remoteFunction.OnClientInvoke
		if not callback then
			error(`[HYDROGEN] Loopback client has no OnClientInvoke; is the network started?`, 0)
		end
		return copyArgs(loopback:as(player, callback, copyArgs(...)))
	end

	local function shake(player: Player)
		if handshaken[player] then
			return
		end
		handshaken[player] = true
		loopback:as(player, Runtime.requestReady, Runtime)
	end

	function loopback:join(name: string?): Player
		joined += 1
		local player = {
			Name = name or `Player{joined}`,
			DisplayName = name or `Player{joined}`,
			-- Negative like Studio's test players, so they can't collide with real UserIds.
			UserId = -joined,
			Parent = Players,
		} :: any
		function player.Kick(_: any, _message: string?)
			loopback:leave(player)
		end

		owned[player] = true
		table.insert(players, player)

		-- Like Roblox: the server sees PlayerAdded before the client finishes starting.
		for _, watcher in table.clone(watchers) do
			task.spawn(watcher.added, player)
		end
		if Runtime.Initialized then
			shake(player)
		end

		return player
	end

	function loopback:leave(player: Player)
		local index = table.find(players, player)
		if not index then
			return
		end

		table.remove(players, index)
		handshaken[player] = nil

		-- Runtime's PlayerRemoving connection is made first in a real game, so it runs first here too.
		Runtime:removePlayer(player)
		for _, watcher in table.clone(watchers) do
			task.spawn(watcher.removing, player)
		end
		(player :: any).Parent = nil
	end

	function loopback:players(): { Player }
		return table.clone(players)
	end

	function loopback:as(player: Player, fn: (...any) -> ...any, ...: any): ...any
		if not owned[player] then
			error(`[HYDROGEN] loopback:as expects a player from loopback:join()`, 2)
		end

		local previous = current
		current = player
		local results = table.pack(pcall(fn, ...))
		current = previous

		if not results[1] then
			error(results[2], 0)
		end
		return table.unpack(results, 2, results.n)
	end

	function loopback:client(): Player?
		return current
	end

	function loopback:owns(value: any): boolean
		return owned[value] == true
	end

	-- Called by Runtime once the network starts: each client that already joined gets ready.
	function loopback:handshake()
		for _, player in table.clone(players) do
			shake(player)
		end
	end

	-- App's player hooks follow the fake clients instead of the Players service.
	function loopback:watch(added: (Player) -> (), removing: (Player) -> ())
		table.insert(watchers, {
			added = added,
			removing = removing,
		})
		for _, player in table.clone(players) do
			task.spawn(added, player)
		end
	end

	function loopback:close()
		if Runtime.Loopback ~= loopback then
			return
		end

		for _, player in table.clone(players) do
			loopback:leave(player)
		end
		table.clear(watchers)
		restore(saved)
		disconnect()
	end

	Runtime.RemoteEvent = remoteEvent() :: any
	Runtime.UnreliableRemoteEvent = remoteEvent() :: any
	Runtime.RemoteFunction = remoteFunction :: any
	Runtime.Loopback = loopback

	return loopback
end

return Loopback
