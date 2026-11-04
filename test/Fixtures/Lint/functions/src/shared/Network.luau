local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Ask = (Hydrogen.serverFunction :: any)("Ask", gt.string()),
	Query = (Hydrogen.clientFunction :: any)("Query", gt.args(gt.string())),
	Bare = (Hydrogen.clientFunction :: any)("Bare", gt.string(), gt.number()),
	Unheard = Hydrogen.serverEvent("Unheard", gt.string()),
	Coins = Hydrogen.clientEvent("Coins", gt.number()),
	coins = Hydrogen.clientEvent("coins", gt.number()),
	Mine = Hydrogen.serverEvent("Hydrogen/Mine", gt.string()),
}
