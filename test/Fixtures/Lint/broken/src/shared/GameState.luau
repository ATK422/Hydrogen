local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Round = Hydrogen.State.value("Round", gt.string(), "Lobby"),
}
