local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)

return Hydrogen.define(function()
	local ChatClient = {}
	function ChatClient:start()
		Network.Chat:Fire("hi")
	end

	return ChatClient
end)
