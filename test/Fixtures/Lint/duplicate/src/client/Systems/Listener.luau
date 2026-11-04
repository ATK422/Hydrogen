local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)
local _GameState = require(ReplicatedStorage.Shared.GameState)

return Hydrogen.define(function()
	local Listener = {}
	function Listener:init()
		Network.Ping:On(function(_n) end)
	end

	return Listener
end)
