local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local _GameState = require(ReplicatedStorage.Shared.GameState)

return Hydrogen.define(function()
	local Pinger = {}
	function Pinger:start() end

	return Pinger
end)
