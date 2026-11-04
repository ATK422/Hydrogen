local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)

return Hydrogen.define(function()
	local Answers = {}
	function Answers:init()
		Network.Query:On(function(_player, _text)
			return nil
		end)
		Network.Bare:On(function(_player, _text)
			return 1
		end)
		Network.Coins:On(function(_player, _n) end)
		Network.coins:On(function(_player, _n) end)
	end

	return Answers
end)
