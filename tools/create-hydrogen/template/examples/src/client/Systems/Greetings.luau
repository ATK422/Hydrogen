--!strict

-- The client half of the greeting: says hello once the network is live and prints the reply.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Greeting = require(ReplicatedStorage.Shared.Network.Greeting)

return Hydrogen.define(function()
	local Greetings = {
		-- The last greeting the server sent, so tests (or UI) can read it.
		last = nil :: string?,
	}

	-- Listeners go in init: the network starts between init and start, and events the server
	-- queued for this client are handled right then.
	function Greetings:init()
		Greeting.Greeted:On(function(message)
			Greetings.last = message
			print(message)
		end)
	end

	function Greetings:start()
		Greeting.SayHello:Fire("hi")
	end

	return Greetings
end)
