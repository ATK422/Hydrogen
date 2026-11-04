--!strict

-- A client system. Every ModuleScript under Systems that returns Hydrogen.define(...) is
-- booted by Main.client.luau. All hooks are optional; delete the ones you don't need.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function(use)
	-- Declare dependencies here: local Other = use(require(script.Parent.Other))
	local Interface = {}

	function Interface:init()
		-- Set up state. Don't touch other systems' runtime state yet.
	end

	function Interface:start()
		-- Every system is initialized and the network is live.
	end

	return Interface
end)
