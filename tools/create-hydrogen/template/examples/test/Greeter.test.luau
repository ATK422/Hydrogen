--!nonstrict
-- Nonstrict for now: under luau-lsp's new type solver, Hydrogen 0.4's App type doesn't match
-- its own methods when an app is passed around, so strict mode flags app:start() here. The
-- game code itself is strict.

-- Example tests. They require game code through the DataModel, like game code does, and use
-- Hydrogen's testing tools: Hydrogen.loopback() for players and a network in one VM, and
-- app:replace to swap a dependency for a fake.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local StarterPlayer = game:GetService("StarterPlayer")

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Greeting = require(ReplicatedStorage.Shared.Network.Greeting)

local ServerSystems = ServerScriptService.Server.Systems
local ClientSystems = StarterPlayer.StarterPlayerScripts.Client.Systems
local Visits = require(ServerSystems.Visits)
local Greetings = require(ClientSystems.Greetings)

test.suite("Greeter", function()
	-- Undo what each test opened, newest first, even when the test fails.
	local cleanup: { () -> () } = {}

	test.on_test_leave(function()
		for i = #cleanup, 1, -1 do
			cleanup[i]()
		end
		table.clear(cleanup)
	end)

	local function newApp()
		local app = Hydrogen.App.new()
		table.insert(cleanup, function()
			app:stop()
		end)
		return app
	end

	local function openLoopback()
		local net = Hydrogen.loopback()
		table.insert(cleanup, function()
			net:close()
		end)
		return net
	end

	-- Collects what the server sends back, as a client listener would see it.
	local function replies(): { string }
		local received = {}
		Greeting.Greeted:On(function(message)
			table.insert(received, message)
		end)
		return received
	end

	test.case("greets a player who says hello", function()
		local net = openLoopback()
		local alice = net:join("Alice")

		local server = newApp()
		server:addSystemsFolders(ServerSystems)
		server:start()

		local received = replies()
		Greeting.SayHello:Fire("hi") -- with one fake client, this comes from Alice

		check.equal(Visits.count(alice), 1)
		check.equal(received[1], 'Hello, Alice! You said "hi". This is your first visit.')
	end)

	test.case("app:replace swaps Visits for a fake", function()
		local net = openLoopback()
		net:join("Alice")

		local server = newApp()
		server:addSystemsFolders(ServerSystems)
		server:replace(Visits, {
			count = function(_player: Player): number
				return 3
			end,
		})
		server:start()

		local received = replies()
		Greeting.SayHello:Fire("hi")

		check.equal(received[1], 'Hello, Alice! You said "hi". This is your visit #3.')
	end)

	test.case("the client system and the server systems talk through the loopback", function()
		local net = openLoopback()
		net:join("Alice")

		-- A server app and a client app, as in a real game. The server starts first, so it's
		-- listening (and has run playerAdded for Alice) when the client's start says hello.
		local server = newApp()
		server:addSystemsFolders(ServerSystems)
		server:start()

		local client = newApp()
		client:addSystemsFolders(ClientSystems)
		client:start()

		check.equal(Greetings.last, 'Hello, Alice! You said "hi". This is your first visit.')
	end)
end)
