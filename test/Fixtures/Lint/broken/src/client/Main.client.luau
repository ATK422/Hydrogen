local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage:WaitForChild("roblox_packages"):WaitForChild("hydrogen"))

local options: any = nil
local volume = options.Volume -- errors before the client registers anything

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"))
app:start()
print(volume)
