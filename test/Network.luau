--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local gt = require("../roblox_packages/.pesde/corecii+greentea/0.4.11/greentea/src/GreenTea")
local ClientEvent = require("../src/Network/ClientEvent")
local Runtime = require("../src/Network/Runtime")
local ServerEvent = require("../src/Network/ServerEvent")
local ServerFunction = require("../src/Network/ServerFunction")

return function()
	test.on_suite_enter(function(suite)
		if suite.name ~= "Network" then
			return
		end

		Runtime.Initialized = false
		Runtime.RemoteEvent = nil
		Runtime.RemoteFunction = nil
		Runtime.UnprocessedNames = {}
		Runtime.NameToIdMap = {}
		Runtime.IdToNameMap = {}
		Runtime.EventCallbacks = {}
		Runtime.FunctionCallbacks = {}
		Runtime.OutgoingQueue = {}
		Runtime.PlayerQueues = {}
		Runtime.ReadyPlayers = {}
	end)

	test.suite("Network", function()
		test.case("registers events and assigns stable alphabetical ids", function()
			ClientEvent.new("id-zeta", gt.string())
			ServerEvent.new("id-alpha", gt.number())

			Runtime:assignIds()

			local alpha = Runtime:getNetworkId("id-alpha")
			local zeta = Runtime:getNetworkId("id-zeta")

			check.not_nil(alpha)
			check.not_nil(zeta)
			check.equal(alpha < zeta, true)
			check.equal(Runtime:getNameFromId(alpha), "id-alpha")
			check.equal(Runtime:getNameFromId(zeta), "id-zeta")
		end)

		test.case("ignores duplicate event names", function()
			ClientEvent.new("dup-name", gt.string())
			local before = #Runtime.UnprocessedNames

			ClientEvent.new("dup-name", gt.number())

			check.equal(#Runtime.UnprocessedNames, before)
			return nil
		end)

		test.case("client event On can disconnect", function()
			local event = ClientEvent.new("client-on", gt.string())
			local off = event:On(function() end)

			check.equal(#event._listeners, 1)
			off()
			check.equal(#event._listeners, 0)
			return nil
		end)

		test.case("server event On can disconnect", function()
			local event = ServerEvent.new("server-on", gt.string())
			local off = event:On(function() end)

			check.equal(#event._listeners, 1)
			off()
			check.equal(#event._listeners, 0)
			return nil
		end)

		test.case("server event FireAll rejects invalid payloads", function()
			local event = ServerEvent.new("server-schema", gt.string())

			check.should_error(function()
				event:FireAll(123)
			end)
			return nil
		end)

		test.case("client event Fire rejects invalid payloads", function()
			local event = ClientEvent.new("client-schema", gt.string())

			check.should_error(function()
				event:Fire(123)
			end)
			return nil
		end)

		test.case("handleEvent dispatches to server event listeners", function()
			local event = ServerEvent.new("server-handle", gt.string())
			local received = nil :: string?

			event:On(function(value)
				received = value
			end)

			Runtime:assignIds()
			Runtime:handleEvent(Runtime:getNetworkId("server-handle"), "ping")

			check.equal(received, "ping")
			return nil
		end)

		test.case("server function is created with sending then receiving types", function()
			local fn = ServerFunction.new("fn-schema", gt.string())(gt.number())

			check.equal(fn._name, "fn-schema")
			check.should_error(function()
				fn._argsSchema:assert(123)
			end)
			return nil
		end)

		test.case("queues outgoing events before runtime starts", function()
			ServerEvent.new("queue-out", gt.string())
			local before = #Runtime.OutgoingQueue

			Runtime:fireClientEvent("queue-out", {}, "hello")

			check.equal(Runtime.Initialized, false)
			check.equal(#Runtime.OutgoingQueue, before + 1)
			check.equal(Runtime.OutgoingQueue[#Runtime.OutgoingQueue].name, "queue-out")
			check.equal(Runtime.OutgoingQueue[#Runtime.OutgoingQueue].args[1], "hello")
			return nil
		end)

		test.case("queues events for players that are not ready", function()
			ServerEvent.new("queue-unready", gt.string())
			Runtime:assignIds()

			local wasInitialized = Runtime.Initialized
			Runtime.Initialized = true

			local player = {} :: Player
			Runtime:fireClientEvent("queue-unready", { player }, "payload")

			check.equal(#Runtime.PlayerQueues[player], 1)
			check.equal(Runtime.PlayerQueues[player][1].args[1], "payload")

			Runtime.Initialized = wasInitialized
			return nil
		end)

		test.case("batches queued events when a player becomes ready", function()
			local player = {} :: Player
			Runtime.PlayerQueues[player] = {
				{ id = 1, args = table.pack("first") },
				{ id = 2, args = table.pack("second") },
			}

			local batch = Runtime:markPlayerReady(player)

			check.equal(#batch, 2)
			check.equal(batch[1].args[1], "first")
			check.equal(batch[2].args[1], "second")
			check.equal(Runtime.ReadyPlayers[player], true)
			check.equal(Runtime.PlayerQueues[player], nil)

			local again = Runtime:markPlayerReady(player)
			check.equal(#again, 0)
			return nil
		end)
		return nil
	end)
	return nil
end
