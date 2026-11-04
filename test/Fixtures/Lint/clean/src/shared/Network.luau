local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt
local Shop = Hydrogen.namespace("Shop")

return {
	SayHello = Hydrogen.clientEvent("SayHello", gt.string()),
	Greeted = Hydrogen.serverEvent("Greeted", gt.string()),
	GetCoins = Hydrogen.clientFunction("GetCoins", gt.args(), gt.returns(gt.number())),
	Ping = Hydrogen.serverFunction("Ping", gt.number())(gt.number()),
	Buy = Shop.clientEvent("Buy", gt.string()):Encode(),
}
