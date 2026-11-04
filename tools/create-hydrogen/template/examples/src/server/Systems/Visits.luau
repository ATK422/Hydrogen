--!strict

-- Counts how many times each player has joined this server. Shows the player hooks:
-- playerAdded runs for everyone already in the game and everyone who joins later.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function()
	local Visits = {}

	local counts: { [Player]: number } = {}
	local joinsByUserId: { [number]: number } = {}

	function Visits:init()
		-- Systems are module singletons; reset state here so tests start clean.
		table.clear(counts)
		table.clear(joinsByUserId)
	end

	function Visits:playerAdded(player: Player)
		local joins = (joinsByUserId[player.UserId] or 0) + 1
		joinsByUserId[player.UserId] = joins
		counts[player] = joins
	end

	function Visits:playerRemoving(player: Player)
		counts[player] = nil
	end

	-- How many times the player has joined this server, counting this time.
	function Visits.count(player: Player): number
		return counts[player] or 0
	end

	return Visits
end)
