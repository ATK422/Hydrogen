--!strict

-- Network objects are declared in shared modules that the server and the client both register
-- (see Main.server.luau and Main.client.luau). Every payload is checked against its schema.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	-- Fired by a client, heard by the server: the player says something.
	SayHello = Hydrogen.clientEvent("SayHello", gt.string()),

	-- Fired by the server, heard by clients: the server's reply.
	Greeted = Hydrogen.serverEvent("Greeted", gt.string()),
}
