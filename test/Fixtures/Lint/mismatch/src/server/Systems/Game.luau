local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)

return Hydrogen.define(function()
	local GameServer = {}
	function GameServer:init()
		Network.Move:On(function(_player, _value) end)
	end

	return GameServer
end)
