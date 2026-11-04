local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage.Shared.Network)
app:addSystemsFolders(script.Parent.Systems)
app:start()

-- Too late: the network has started, so this registration is ignored.
local Lazy = require(ReplicatedStorage.Shared.Lazy)
print(Lazy.Later)
