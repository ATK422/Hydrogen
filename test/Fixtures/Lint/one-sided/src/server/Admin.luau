local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

-- Server-only: clients can't see ServerScriptService, so they never register Kick.
return {
	Kick = Hydrogen.serverEvent("Kick", gt.string()),
}
