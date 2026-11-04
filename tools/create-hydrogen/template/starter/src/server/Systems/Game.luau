--!strict

-- A server system. Every ModuleScript under Systems that returns Hydrogen.define(...) is
-- booted by Main.server.luau. All hooks are optional; delete the ones you don't need.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function(use)
	-- Declare dependencies here: local Other = use(require(script.Parent.Other))
	local Game = {}

	function Game:init()
		-- Set up state. Don't touch other systems' runtime state yet.
	end

	function Game:start()
		-- Every system is initialized and the network is live.
	end

	function Game:playerAdded(_player: Player) end

	function Game:playerRemoving(_player: Player) end

	return Game
end)
