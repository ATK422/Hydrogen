local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Players = game:GetService("Players")
local Network = require(ReplicatedStorage.Shared.Network)
local GameState = require(ReplicatedStorage.Shared.GameState)

return Hydrogen.define(function()
	local Hud = {}
	function Hud:init()
		-- Engine APIs the lint doesn't emulate get stand-ins, so the boot carries on.
		local UserInputService = game:GetService("UserInputService")
		UserInputService.InputBegan:Connect(function(_input) end)
		local TweenService = game:GetService("TweenService")
		TweenService:Create(workspace.CurrentCamera, TweenInfo.new(1), {}):Play()
		local spawnPoint = workspace:WaitForChild("Map"):WaitForChild("Spawn")
		print(spawnPoint.Name, Players.LocalPlayer.UserId)

		GameState.Round:observe(function(round)
			print(round)
		end)
		Network.Greeted:On(function(text)
			print(text)
		end)
		Network.Ping:On(function(n)
			return n
		end)
	end

	function Hud:start()
		local gui = Players.LocalPlayer:WaitForChild("PlayerGui")
		local character = Players.LocalPlayer.Character or Players.LocalPlayer.CharacterAdded:Wait()
		print(gui.Name, character.Name)
		Network.SayHello:Fire("hello")
		print(Network.GetCoins:Fire())
	end

	return Hud
end)
