--!strict

-- Answers SayHello with a greeting. Shows `use` (a dependency on Visits, which then starts
-- first) and a network listener registered in init.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Greeting = require(ReplicatedStorage.Shared.Network.Greeting)
local VisitsSystem = require(script.Parent.Visits)

return Hydrogen.define(function(use)
	local Visits = use(VisitsSystem)

	local Greeter = {}

	function Greeter.message(player: Player, said: string): string
		local visits = Visits.count(player)
		local times = if visits == 1 then "first visit" else `visit #{visits}`
		return `Hello, {player.DisplayName}! You said "{said}". This is your {times}.`
	end

	function Greeter:init()
		Greeting.SayHello:On(function(player, said)
			Greeting.Greeted:Fire(player, Greeter.message(player, said))
		end)
	end

	return Greeter
end)
