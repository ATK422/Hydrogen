--!strict

-- Per-player state: fields loaded from a Data store and runtime-only fields, each optionally
-- replicated to its owner or to everyone. Created on join and dropped on leave, in dependency order.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Replication = require("./Replication")
local Definition = require("../Definition")
local Network = require("../Network")
local Store = require("../Data/Store")
local Tables = require("../Data/Tables")
local Data = require("../Data/Stores")
local Log = require("../Log")

export type Audience = Replication.Audience

export type Options<D, R> = {
	-- A Data.player store; every field of its data becomes a saved field of this state.
	data: Data.PlayerStore<D>?,
	-- Fields that live only while the player is in the game, with their starting values.
	runtime: R?,
	-- One word per field: "owner" sends it to that player's client, "everyone" to every client.
	-- Fields not listed stay on the server.
	replicate: { [string]: Audience }?,
}

export type PlayerState<S> = {
	name: string,
	-- The player's state. Read fields directly; assigning a field validates it (saved fields
	-- against the store's schema), saves it with the profile and replicates it. Values are frozen:
	-- assign a new table, or use update. On a client, holds what was replicated and is read-only.
	get: (self: any, player: Player) -> S,
	-- Like get, but nil before the player's state exists or after it is gone.
	find: (self: any, player: Player) -> S?,
	-- Edits one field through a copy: change it in place or return a new value. fn must not yield.
	update: (self: any, player: Player, field: string, fn: (value: any) -> ...any) -> (),
	-- Calls fn whenever the field changes for any player: on the server for every change, on a
	-- client when an update arrives (including the first). Returns a disconnect function.
	changed: (self: any, field: string, fn: (player: Player, value: any, old: any) -> ()) -> () -> (),
	-- What `viewer`'s client has received about `player`, for tests under Hydrogen.loopback.
	replica: (self: any, viewer: Player, player: Player) -> { [string]: any }?,
}

type Container = {
	values: { [string]: any },
	proxy: any,
}

local PlayerState = {}

local function report(fn: (...any) -> (), ...: any)
	local ok, err = xpcall(fn, debug.traceback, ...)
	if not ok then
		Log.warn(`[HYDROGEN] PlayerState changed listener failed: {err}`)
	end
end

local function frozen(value: any): any
	if type(value) == "table" then
		return Tables.freeze(Tables.copy(value))
	end
	return value
end

local function readOnly(): never
	error(`[HYDROGEN] PlayerState is read-only on the client; change it on the server`, 3)
end

--[=[
	local Session = Hydrogen.PlayerState.new("Session", {
		data = PlayerData,
		runtime = { inCombat = false },
		replicate = { coins = "owner", inCombat = "everyone" },
	})
]=]
function PlayerState.new<D, R>(name: string, options: Options<D, R>): Definition.Defined<PlayerState<D & R>>
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] PlayerState.new needs a name`, 2)
	end

	local store = options.data :: any
	local runtime = (options.runtime or {}) :: { [string]: any }
	local audiences = (options.replicate or {}) :: { [string]: Audience }

	-- Which fields come from the store: the template's, plus any the schema declares.
	local saved: { [string]: boolean } = {}
	if store ~= nil then
		if type(store) ~= "table" or type(store._template) ~= "table" then
			error(`[HYDROGEN] PlayerState {name}: data must be a store made with Hydrogen.Data.player`, 2)
		end
		for field in store._template do
			saved[field] = true
		end
		for field in store._fields or {} do
			saved[field] = true
		end
	end

	for field in runtime do
		if saved[field] then
			error(`[HYDROGEN] PlayerState {name}: "{field}" is both a saved field and a runtime field`, 2)
		end
	end
	for field, audience in audiences do
		if audience ~= "owner" and audience ~= "everyone" then
			error(`[HYDROGEN] PlayerState {name}: replicate.{field} must be "owner" or "everyone", got {tostring(audience)}`, 2)
		end
		if not saved[field] and runtime[field] == nil then
			error(`[HYDROGEN] PlayerState {name}: replicate names "{field}", which is neither a saved nor a runtime field`, 2)
		end
	end

	local containers: { [Player]: Container } = {}
	local listeners: { [string]: { (Player, any, any) -> () } } = {}
	local disconnects: { () -> () } = {}

	local function fire(field: string, player: Player, value: any, old: any)
		local list = listeners[field]
		if list then
			for _, listener in table.clone(list) do
				task.spawn(report, listener, player, value, old)
			end
		end
	end

	-- What a client starts with before anything arrives: defaults of the fields it will receive.
	local function defaults(player: Player, isOwner: boolean): { [string]: any }
		local values = {}
		for field, audience in audiences do
			if isOwner or audience == "everyone" then
				local default = if saved[field] then store._template[field] else runtime[field]
				values[field] = frozen(default)
			end
		end
		return values
	end

	local replication = if next(audiences)
		then Replication.new(name, audiences, function(player)
			local container = containers[player]
			return if container then container.values else nil
		end, defaults)
		else nil

	local function onClient(): boolean
		return RunService:IsClient()
	end

	-- A field changed on the server: keep the value, replicate it, tell listeners.
	local function apply(player: Player, container: Container, field: string, value: any)
		local old = container.values[field]
		if old == value then
			return
		end
		container.values[field] = value
		if replication then
			replication:set(player, field)
		end
		fire(field, player, value, old)
	end

	local function newContainer(player: Player): Container
		local values: { [string]: any } = {}
		if store ~= nil then
			for field, value in store:get(player) do
				values[field] = value
			end
		end
		for field, default in runtime do
			values[field] = frozen(default)
		end

		local container = { values = values, proxy = nil :: any }
		container.proxy = setmetatable({}, {
			__index = values,
			__iter = function()
				return next, values
			end,
			__newindex = function(_, field: string, value: any)
				if saved[field] then
					-- The store's changed listener applies it, so every path into the data replicates.
					store:setField(player, field, value)
				elseif runtime[field] ~= nil then
					apply(player, container, field, frozen(value))
				else
					error(`[HYDROGEN] PlayerState {name} has no field "{tostring(field)}"`, 2)
				end
			end,
			__tostring = function()
				return `PlayerState {name} of {player.Name}`
			end,
		})
		return container
	end

	-- A client's read-only view. It reads State on every access, so a view kept around stays current.
	local clientViews: { [Player]: any } = setmetatable({}, { __mode = "k" }) :: any
	local function clientView(player: Player): any?
		if not replication or player.Parent ~= Players then
			return nil
		end
		local view = clientViews[player]
		if not view then
			local live = replication :: Replication.Replication
			view = setmetatable({}, {
				__index = function(_, field: string)
					return live:read(player, field)
				end,
				__iter = function()
					local values = {}
					for _, field in live:visible(Players.LocalPlayer, player) do
						values[field] = live:read(player, field)
					end
					return next, values
				end,
				__newindex = readOnly,
			})
			clientViews[player] = view
		end
		return view
	end

	local system = {}

	function system:init()
		if store ~= nil then
			table.insert(
				disconnects,
				store:changed(function(player: Player, data: any)
					local container = containers[player]
					if not container then
						return
					end
					for field in saved do
						if data[field] ~= container.values[field] then
							apply(player, container, field, data[field])
						end
					end
				end)
			)
		end
		-- Under loopback this VM is the clients too, so it keeps their replicas for tests.
		if replication and (onClient() or Network.activeLoopback()) then
			table.insert(
				disconnects,
				replication:listen(function(player, field, value, old)
					fire(field, player, value, old)
				end)
			)
		end
	end

	function system:playerAdded(player: Player)
		if onClient() then
			return
		end
		local container = newContainer(player)
		containers[player] = container
		if replication then
			local existing = {}
			for other, otherContainer in containers do
				existing[other] = otherContainer.values
			end
			replication:join(player, container.values, existing)
		end
	end

	function system:playerRemoving(player: Player)
		if containers[player] then
			containers[player] = nil
			if replication then
				replication:leave(player)
			end
		end
	end

	function system:stop()
		for _, disconnect in disconnects do
			disconnect()
		end
		table.clear(disconnects)
	end

	function system:get(player: Player): any
		if onClient() then
			local view = clientView(player)
			if view == nil then
				error(`[HYDROGEN] PlayerState {name}: {player.Name} isn't in the game (or nothing is replicated); use find`, 2)
			end
			return view
		end
		local container = containers[player]
		if not container then
			error(`[HYDROGEN] PlayerState {name} has no state for {player.Name} (not added yet, or already removed)`, 2)
		end
		return container.proxy
	end

	function system:find(player: Player): any?
		if onClient() then
			return clientView(player)
		end
		local container = containers[player]
		return if container then container.proxy else nil
	end

	function system:update(player: Player, field: string, fn: (value: any) -> ...any)
		if onClient() then
			readOnly()
		end
		local container = containers[player]
		if not container then
			error(`[HYDROGEN] PlayerState {name} has no state for {player.Name}`, 2)
		end
		local draft = Tables.copy(container.values[field])
		local result = Store.runSync("PlayerState update", fn, draft)
		container.proxy[field] = if result ~= nil then result else draft
	end

	function system:changed(field: string, fn: (player: Player, value: any, old: any) -> ()): () -> ()
		if not saved[field] and runtime[field] == nil then
			error(`[HYDROGEN] PlayerState {name} has no field "{field}"`, 2)
		end
		local list = listeners[field]
		if not list then
			list = {}
			listeners[field] = list
		end
		table.insert(list, fn)
		return function()
			local index = table.find(list, fn)
			if index then
				table.remove(list, index)
			end
		end
	end

	function system:replica(viewer: Player, player: Player): { [string]: any }?
		if not replication then
			return nil
		end
		local replica = replication:replica(viewer, player)
		return if replica then table.clone(replica.values) else nil
	end

	return Definition.define(name, function(use)
		if store ~= nil then
			use(store)
		end
		local result = system :: any
		result.name = name
		return result
	end) :: any
end

return PlayerState
