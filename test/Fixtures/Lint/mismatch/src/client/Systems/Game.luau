local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)

return Hydrogen.define(function()
	local GameClient = {}
	function GameClient:init()
		Network.Score:On(function(_score) end)
	end

	return GameClient
end)
