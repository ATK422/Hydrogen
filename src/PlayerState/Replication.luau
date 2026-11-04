--!strict

-- Sends each player's replicated fields to the clients allowed to see them, through
-- Hydrogen.State: one per-player State value per replicated field, named "<name>/<field>",
-- visible to its owner or to everyone. PlayerState only calls join, set, leave, listen and replica.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Network = require("../Network")
local State = require("../State")
local gt = require("../../roblox_packages/gt")

export type Audience = "owner" | "everyone"

-- What a client has received about one player: the fields it is allowed to see.
export type Replica = {
	values: { [string]: any },
}

export type Replication = {
	-- Server: a player's state now exists. State sends it, and late joiners get a snapshot.
	join: (self: Replication, player: Player, values: { [string]: any }, existing: { [Player]: { [string]: any } }) -> (),
	-- Server: a field changed. State sends it at the end of the frame, coalesced.
	set: (self: Replication, player: Player, field: string) -> (),
	-- Server: the player left. State drops them from every client on its own.
	leave: (self: Replication, player: Player) -> (),
	-- Client: onChange is called per changed field, including the values that arrive on join.
	listen: (self: Replication, onChange: (player: Player, field: string, value: any, old: any) -> ()) -> () -> (),
	-- What a client sees of a player (viewer is the receiving client), or nil once they left.
	replica: (self: Replication, viewer: Player, player: Player) -> Replica?,
	-- One field as the local client sees it right now (nil if it can't see the field).
	read: (self: Replication, player: Player, field: string) -> any,
	-- The replicated fields the local client can see of player.
	visible: (self: Replication, viewer: Player, player: Player) -> { string },
}

local Replication = {}

function Replication.new(
	name: string,
	audiences: { [string]: Audience },
	current: (player: Player) -> { [string]: any }?,
	defaults: (player: Player, isOwner: boolean) -> { [string]: any }
): Replication
	-- Defaults don't depend on the player: the template value or the runtime default.
	local initial = defaults(nil :: any, true)
	local fields: { [string]: State.PlayerValue<any> } = {}
	for field, audience in audiences do
		fields[field] = State.playerValue(`{name}/{field}`, gt.optional(gt.any()), initial[field], { visibleTo = audience })
	end

	local replication = {} :: Replication

	function replication:join(player: Player, values: { [string]: any }, _existing: { [Player]: { [string]: any } })
		for field, value in fields do
			value:set(player, values[field])
		end
	end

	function replication:set(player: Player, field: string)
		local value = fields[field]
		local values = current(player)
		if value and values then
			value:set(player, values[field])
		end
	end

	function replication:leave(_player: Player) end

	function replication:listen(onChange: (Player, string, any, any) -> ()): () -> ()
		-- Under loopback every fake client shares one VM; only a real client runs the callbacks.
		if not RunService:IsClient() then
			return function() end
		end
		local disconnects = {}
		for field, value in fields do
			table.insert(
				disconnects,
				value:observeAll(function(player: Player, new: any, old: any)
					onChange(player, field, new, old)
				end)
			)
		end
		return function()
			for _, disconnect in disconnects do
				disconnect()
			end
		end
	end

	function replication:replica(viewer: Player, player: Player): Replica?
		local loopback = Network.activeLoopback()
		local present = if loopback then table.find(loopback:players(), player) ~= nil else player.Parent == Players
		if not present then
			return nil
		end

		local function read(): { [string]: any }
			local values = {}
			for field, value in fields do
				if viewer == player or audiences[field] == "everyone" then
					values[field] = value:get(player)
				end
			end
			return values
		end

		return { values = if loopback then loopback:as(viewer, read) else read() }
	end

	function replication:read(player: Player, field: string): any
		local value = fields[field]
		if not value or (audiences[field] ~= "everyone" and player ~= Players.LocalPlayer) then
			return nil
		end
		return value:get(player)
	end

	function replication:visible(viewer: Player, player: Player): { string }
		local names = {}
		for field in fields do
			if viewer == player or audiences[field] == "everyone" then
				table.insert(names, field)
			end
		end
		return names
	end

	return replication
end

return Replication
