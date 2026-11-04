local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage.Shared.Network, ReplicatedStorage.Shared.Effects)
app:addSystemsFolders(script.Parent.Systems)
app:start()
