--!strict

-- Sends each player's replicated fields to the clients allowed to see them. Kept apart from
-- PlayerState so the State module can take over: PlayerState only calls join, set, leave and listen.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Network = require("../Network")
local Tables = require("../Data/Tables")
local gt = require("../../roblox_packages/gt")

export type Audience = "owner" | "everyone"

-- What one message carries: a player's fields, the fields set to nil, or that the player left.
type Patch = {
	player: Player,
	values: { [string]: any }?,
	cleared: { string }?,
	gone: boolean?,
}

-- What a client has received about one player.
export type Replica = {
	values: { [string]: any },
}

export type Replication = {
	-- Server: a player's state now exists; send it to everyone allowed to see it, and send the
	-- new player everyone else's public fields.
	join: (self: Replication, player: Player, values: { [string]: any }, existing: { [Player]: { [string]: any } }) -> (),
	-- Server: a field changed. Sent at the end of the frame, coalesced.
	set: (self: Replication, player: Player, field: string) -> (),
	-- Server: the player left.
	leave: (self: Replication, player: Player) -> (),
	-- Client: apply incoming patches; onChange is called per changed field.
	listen: (self: Replication, onChange: (player: Player, field: string, value: any, old: any) -> ()) -> () -> (),
	-- What a client has received about a player (viewer is the receiving client).
	replica: (self: Replication, viewer: Player, player: Player) -> Replica?,
}

local Replication = {}

function Replication.new(
	name: string,
	audiences: { [string]: Audience },
	current: (player: Player) -> { [string]: any }?,
	defaults: (player: Player, isOwner: boolean) -> { [string]: any }
): Replication
	local event = Network.serverEvent(`Hydrogen/PlayerState/{name}`, gt.any())
	local replication = {} :: Replication

	-- Server side: changed fields per player, flushed once per frame.
	local pending: { [Player]: { [string]: boolean } } = {}
	local scheduled = false
	-- Client side, per receiving client (one in a game, several under loopback).
	local replicas: { [Player]: { [Player]: Replica } } = {}

	local function pick(values: { [string]: any }, isOwner: boolean, fields: { [string]: boolean }?): ({ [string]: any }, { string })
		local picked = {}
		local cleared = {}
		for field, audience in audiences do
			if (fields == nil or fields[field]) and (isOwner or audience == "everyone") then
				local value = values[field]
				if value == nil then
					table.insert(cleared, field)
				else
					picked[field] = value
				end
			end
		end
		return picked, cleared
	end

	local function send(target: Player | { Player }, player: Player, values: { [string]: any }, cleared: { string })
		if next(values) == nil and #cleared == 0 then
			return
		end
		event:Fire(target, {
			player = player,
			values = values,
			cleared = if #cleared > 0 then cleared else nil,
		} :: Patch)
	end

	local function others(player: Player): { Player }
		local loopback = Network.activeLoopback()
		local everyone = if loopback then loopback:players() else Players:GetPlayers()
		local index = table.find(everyone, player)
		if index then
			table.remove(everyone, index)
		end
		return everyone
	end

	local function flush()
		scheduled = false
		local batch = pending
		pending = {}
		for player, fields in batch do
			local values = current(player)
			if not values then
				continue
			end
			local ownerValues, ownerCleared = pick(values, true, fields)
			send(player, player, ownerValues, ownerCleared)

			local publicValues, publicCleared = pick(values, false, fields)
			local audience = others(player)
			if #audience > 0 then
				send(audience, player, publicValues, publicCleared)
			end
		end
	end

	function replication:join(player: Player, values: { [string]: any }, existing: { [Player]: { [string]: any } })
		local ownerValues, ownerCleared = pick(values, true, nil)
		send(player, player, ownerValues, ownerCleared)

		local publicValues, publicCleared = pick(values, false, nil)
		local audience = others(player)
		if #audience > 0 then
			send(audience, player, publicValues, publicCleared)
		end

		for other, otherValues in existing do
			if other ~= player then
				local otherPublic, otherCleared = pick(otherValues, false, nil)
				send(player, other, otherPublic, otherCleared)
			end
		end
	end

	function replication:set(player: Player, field: string)
		if not audiences[field] then
			return
		end
		local fields = pending[player]
		if not fields then
			fields = {}
			pending[player] = fields
		end
		fields[field] = true
		if not scheduled then
			scheduled = true
			task.defer(flush)
		end
	end

	function replication:leave(player: Player)
		pending[player] = nil
		local audience = others(player)
		if #audience > 0 then
			event:Fire(audience, { player = player, gone = true } :: Patch)
		end
	end

	-- The receiving client: the one a loopback is delivering to, or the local player.
	local function viewer(): Player?
		local loopback = Network.activeLoopback()
		if loopback then
			return loopback:client()
		end
		return Players.LocalPlayer
	end

	function replication:listen(onChange: (Player, string, any, any) -> ()): () -> ()
		return event:On(function(message: any)
			local receiver = viewer()
			if not receiver or type(message) ~= "table" or message.player == nil then
				return
			end
			local player = message.player :: Player

			local views = replicas[receiver]
			if not views then
				views = {}
				replicas[receiver] = views
			end

			if message.gone then
				views[player] = nil
				return
			end

			local replica = views[player]
			if not replica then
				replica = { values = defaults(player, player == receiver) }
				views[player] = replica
			end

			local changes = {}
			for field, value in message.values or {} do
				local old = replica.values[field]
				replica.values[field] = Tables.freeze(value)
				table.insert(changes, { field = field, value = value, old = old })
			end
			for _, field in message.cleared or {} do
				local old = replica.values[field]
				replica.values[field] = nil
				table.insert(changes, { field = field, value = nil, old = old })
			end

			-- Under loopback every fake client shares one VM; only a real client runs the callbacks.
			if RunService:IsClient() then
				for _, change in changes do
					onChange(player, change.field, change.value, change.old)
				end
			end
		end)
	end

	function replication:replica(receiver: Player, player: Player): Replica?
		local views = replicas[receiver]
		return if views then views[player] else nil
	end

	return replication
end

return Replication
