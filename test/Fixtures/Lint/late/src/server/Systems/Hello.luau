local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)

return Hydrogen.define(function()
	local HelloServer = {}
	function HelloServer:init()
		Network.Hello:On(function(_player, _text) end)
	end

	return HelloServer
end)
