local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Coins = Hydrogen.State.value("Coins", gt.number(), 0),
	-- Hydrogen.State already registers State/Coins for the state above.
	CoinsChanged = Hydrogen.namespace("State").serverEvent("Coins", gt.number()),
}
