local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Network = require(ReplicatedStorage.Shared.Network)
local Trading = require(ReplicatedStorage.Shared.Trading)
local Admin = require(script.Parent.Parent.Admin)

return Hydrogen.define(function()
	local ChatServer = {}
	function ChatServer:init()
		Network.Chat:On(function(_player, _text) end)
		Trading.Trade:On(function(_player, _offer) end)
		print(Admin.Kick)
	end

	return ChatServer
end)
