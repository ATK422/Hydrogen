local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)
local GameState = require(ReplicatedStorage.Shared.GameState)

return Hydrogen.define(function()
	local Greeter = {}
	function Greeter:init()
		Network.SayHello:On(function(player, text)
			Network.Greeted:Fire(player, `hi {player.Name}: {text}`)
		end)
		Network.GetCoins:On(function(_player)
			return 10
		end)
		Network.Buy:On(function(_player, _item) end)

		local remote = Instance.new("RemoteEvent")
		remote.Name = "Legacy"
		remote.Parent = ReplicatedStorage
		remote.OnServerEvent:Connect(function(_player) end)
		local Players = game:GetService("Players")
		Players.PlayerAdded:Connect(function(_player) end)
		local MarketplaceService = game:GetService("MarketplaceService")
		MarketplaceService.ProcessReceipt = function()
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
	end

	function Greeter:start()
		GameState.Round:set("Playing")
	end

	return Greeter
end)
