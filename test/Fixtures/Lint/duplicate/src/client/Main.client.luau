local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage:WaitForChild("roblox_packages"):WaitForChild("hydrogen"))

local app = Hydrogen.App.new()
app:addNetwork(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Network"), ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Effects"))
app:addSystemsFolders(script.Parent:WaitForChild("Systems"))
app:start() -- yields until the server's network is ready
