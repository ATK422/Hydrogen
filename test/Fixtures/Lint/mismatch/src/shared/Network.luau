local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local RunService = game:GetService("RunService")
local gt = Hydrogen.gt

local isServer = RunService:IsServer()

local Score = Hydrogen.serverEvent("Score", gt.number())
if isServer then
	Score:Encode()
end

return {
	Score = Score,
	Move = Hydrogen.clientEvent("Move", if isServer then gt.number() else gt.string()),
	Swap = if isServer then Hydrogen.serverEvent("Swap", gt.number()) else Hydrogen.clientEvent("Swap", gt.number()),
}
