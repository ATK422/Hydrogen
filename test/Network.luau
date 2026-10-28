--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local gt = require("../roblox_packages/.pesde/corecii+greentea/0.4.11/greentea/src/GreenTea")
local App = require("../src/App")
local Network = require("../src/Network")
local ClientEvent = require("../src/Network/ClientEvent")
local ClientFunction = require("../src/Network/ClientFunction")
local Middleware = require("../src/Network/Middleware")
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
		Runtime.RegisteredNames = {}
		Runtime.Objects = {}
		Runtime.NameToIdMap = {}
		Runtime.IdToNameMap = {}
		Runtime.EventHandlers = {}
		Runtime.FunctionCallbacks = {}
		Runtime.OutgoingQueue = {}
		Runtime.PlayerQueues = {}
		Runtime.ReadyPlayers = {}
		Runtime.Unreliable = {}
		Runtime.DepartedPlayers = setmetatable({}, { __mode = "k" }) :: any
		Middleware.global = {}
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

		test.case("duplicate names error", function()
			ClientEvent.new("dup-name", gt.string())
			local before = #Runtime.UnprocessedNames

			check.should_error(function()
				ServerEvent.new("dup-name", gt.number())
				return nil
			end)

			check.equal(#Runtime.UnprocessedNames, before)
			return nil
		end)

		test.case("namespaces prefix names so they don't clash", function()
			local lobby = Network.namespace("Lobby")
			local plain = ClientEvent.new("ns-play", gt.string())
			local prefixed = lobby.clientEvent("ns-play", gt.string())
			local nested = lobby.namespace("Queue").serverEvent("ns-play", gt.string())
			local fn = lobby.serverFunction("ns-ping", gt.number())(gt.number())

			check.equal(plain._name, "ns-play")
			check.equal(prefixed._name, "Lobby/ns-play")
			check.equal(nested._name, "Lobby/Queue/ns-play")
			check.equal(fn._name, "Lobby/ns-ping")
			check.should_error(function()
				Network.namespace("")
				return nil
			end)
			return nil
		end)

		test.case("addNetwork requires a ModuleScript passed directly", function()
			local module = Instance.new("ModuleScript")
			local folder = Instance.new("Folder")
			local child = Instance.new("ModuleScript")
			child.Parent = folder

			local registered = false
			_G.instanceModules[module] = { Play = ServerEvent.new("addnetwork-direct", gt.string()) }
			_G.instanceModules[child] = setmetatable({}, {
				__index = function()
					registered = true
					return nil
				end,
			})

			App.new():addNetwork(module, folder)

			check.equal(Runtime.RegisteredNames["addnetwork-direct"], true)
			check.equal(registered, false)
			return nil
		end)

		test.case("handshake reports whether the names match", function()
			ServerEvent.new("hash-a", gt.string())
			Runtime:assignIds()

			local hash = Runtime:namesHash()
			local _, matches = Runtime:markPlayerReady({ Name = "Same" } :: any, hash)
			check.equal(matches, true)

			local _, mismatched = Runtime:markPlayerReady({ Name = "Other" } :: any, "0:0")
			check.equal(mismatched, false)

			ServerEvent.new("hash-b", gt.string())
			Runtime:assignIds()
			check.not_equal(Runtime:namesHash(), hash)
			return nil
		end)

		test.case("unreliable events are never queued", function()
			ServerEvent.new("unreliable-frame", gt.number()):Unreliable()
			Runtime:assignIds()

			local wasInitialized = Runtime.Initialized
			Runtime.Initialized = false
			Runtime:fireClientEvent("unreliable-frame", { { Parent = game:GetService("Players") } :: any }, 1)
			check.equal(#Runtime.OutgoingQueue, 0)

			Runtime.Initialized = true
			local player = { Parent = game:GetService("Players") } :: any
			Runtime:fireClientEvent("unreliable-frame", { player }, 1)
			check.equal(Runtime.PlayerQueues[player], nil)

			Runtime.Initialized = wasInitialized
			return nil
		end)

		test.case("server functions time out when the client never answers", function()
			local fn = ServerFunction.new("timeout-ping", gt.number())(gt.number()):SetTimeout(0.05)
			Runtime:assignIds()

			local wasInitialized = Runtime.Initialized
			local wasRemote = Runtime.RemoteFunction
			Runtime.Initialized = true

			local player = { Name = "Silent" } :: any
			Runtime.RemoteFunction = {
				InvokeClient = function(_, _, _, value)
					task.wait(0.2)
					return value
				end,
			} :: any
			local ok, err = pcall(function()
				return fn:Fire(player, 1)
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "timed out", 1, true))

			Runtime.RemoteFunction = {
				InvokeClient = function(_, _, _, value)
					task.wait()
					return value + 1
				end,
			} :: any
			check.equal(fn:Fire(player, 1), 2)

			Runtime.RemoteFunction = {
				InvokeClient = function(_, _, _, value)
					return value + 2
				end,
			} :: any
			check.equal(fn:Fire(player, 1), 3)

			Runtime.Initialized = wasInitialized
			Runtime.RemoteFunction = wasRemote
			return nil
		end)

		test.case("middleware returning DROP stops events and fails functions", function()
			local event = ClientEvent.new("drop-event", gt.string())
			local called = false
			event:On(function()
				called = true
			end)
			event:Use(function(context, ...)
				if context.direction == "incoming" then
					return Middleware.DROP
				end
				return ...
			end)

			local fn = ClientFunction.new("drop-fn", gt.args(gt.number()), gt.returns(gt.number()))
			fn:On(function(_, value)
				return value
			end)
			fn:UseRequest(function()
				return Middleware.DROP
			end)

			Runtime:assignIds()
			Runtime:handleEvent(Runtime:getNetworkId("drop-event"), { Name = "Tester" }, "hi")
			check.equal(called, false)

			check.should_error(function()
				Runtime:handleFunction(Runtime:getNetworkId("drop-fn"), { Name = "Tester" }, 1)
				return nil
			end)
			return nil
		end)

		test.case("rateLimit drops a player's messages beyond the burst", function()
			local limited = 0
			local limit = Middleware.rateLimit({
				perSecond = 1,
				burst = 2,
				onLimit = function()
					limited += 1
				end,
			})

			local player = {} :: any
			local other = {} :: any
			local incoming = { name = "Spam", kind = "ClientEvent", direction = "incoming", payload = "event", player = player } :: any
			local fromOther = { name = "Spam", kind = "ClientEvent", direction = "incoming", payload = "event", player = other } :: any
			local outgoing = { name = "Spam", kind = "ServerEvent", direction = "outgoing", payload = "event" } :: any

			check.equal(limit(incoming, "a"), "a")
			check.equal(limit(incoming, "b"), "b")
			check.equal(limit(incoming, "c"), Middleware.DROP)
			check.equal(limit(fromOther, "d"), "d")
			check.equal(limit(outgoing, "e"), "e")
			check.equal(limited, 1)
			check.should_error(function()
				Middleware.rateLimit({ perSecond = 0 })
				return nil
			end)
			return nil
		end)

		test.case("countObjects finds network objects in module results", function()
			local event = ServerEvent.new("count-a", gt.string())
			local fn = ClientFunction.new("count-b", gt.args(gt.number()), gt.returns(gt.number()))

			check.equal(Network.countObjects(event), 1)
			check.equal(Network.countObjects({ A = event, Nested = { B = fn } }), 2)
			check.equal(Network.countObjects({ helper = function() end }), 0)
			check.equal(Network.countObjects(nil), 0)
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

			local player = { Parent = game:GetService("Players") } :: any
			Runtime:fireClientEvent("queue-unready", { player }, "payload")

			check.equal(#Runtime.PlayerQueues[player], 1)
			check.equal(Runtime.PlayerQueues[player][1].args[1], "payload")

			Runtime.Initialized = wasInitialized
			return nil
		end)

		test.case("drops events for players who have left", function()
			ServerEvent.new("queue-departed", gt.string())
			Runtime:assignIds()

			local wasInitialized = Runtime.Initialized
			Runtime.Initialized = true

			-- Removed by PlayerRemoving but still parented while other handlers run.
			local leaving = { Parent = game:GetService("Players") } :: any
			Runtime:fireClientEvent("queue-departed", { leaving }, "before")
			Runtime:removePlayer(leaving)
			Runtime:fireClientEvent("queue-departed", { leaving }, "after")

			local gone = { Parent = nil } :: any
			Runtime:fireClientEvent("queue-departed", { gone }, "payload")

			check.equal(Runtime.PlayerQueues[leaving], nil)
			check.equal(Runtime.PlayerQueues[gone], nil)

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

		test.case("client event listeners receive the sending player first", function()
			local event = ClientEvent.new("client-recv", gt.string())
			local player = { Name = "Tester" } :: any
			local sender, received = nil, nil

			event:On(function(from, value)
				sender = from
				received = value
			end)

			Runtime:assignIds()
			Runtime:handleEvent(Runtime:getNetworkId("client-recv"), player, "hi")

			check.equal(sender, player)
			check.equal(received, "hi")
			return nil
		end)

		test.case("client event drops invalid payloads from clients", function()
			local event = ClientEvent.new("client-invalid", gt.string())
			local called = false

			event:On(function()
				called = true
			end)

			Runtime:assignIds()
			check.should_not_error(function()
				Runtime:handleEvent(Runtime:getNetworkId("client-invalid"), { Name = "Tester" }, 123)
				return nil
			end)
			check.equal(called, false)
			return nil
		end)

		test.case("unknown event ids are dropped without erroring", function()
			check.should_not_error(function()
				Runtime:handleEvent(999999, "junk")
				Runtime:handleEvent("not-an-id" :: any)
				return nil
			end)
			return nil
		end)

		test.case("outgoing middleware runs object middleware then global", function()
			local event = ClientEvent.new("mw-out", gt.string())
			local order = {}

			local removeGlobal = Middleware.use(function(context, ...)
				table.insert(order, `global:{context.direction}`)
				return ...
			end)
			event:Use(function(context, value)
				table.insert(order, `object:{context.direction}`)
				return string.upper(value)
			end)

			event:Fire("hello")
			removeGlobal()

			local packet = Runtime.OutgoingQueue[#Runtime.OutgoingQueue]
			check.equal(packet.name, "mw-out")
			check.equal(packet.args[1], "HELLO")
			check.equal(order[1], "object:outgoing")
			check.equal(order[2], "global:outgoing")
			return nil
		end)

		test.case("incoming middleware runs global then object in reverse before validation", function()
			local event = ServerEvent.new("mw-in", gt.string())
			local order = {}
			local received = nil :: string?

			local removeGlobal = Middleware.use(function(_, ...)
				table.insert(order, "global")
				return ...
			end)
			event:Use(function(_, value)
				table.insert(order, "first")
				return value
			end)
			event:Use(function(_, value: any)
				table.insert(order, "second")
				return tostring(value) :: any
			end)
			event:On(function(value)
				received = value
			end)

			Runtime:assignIds()
			Runtime:handleEvent(Runtime:getNetworkId("mw-in"), 42)
			removeGlobal()

			check.equal(order[1], "global")
			check.equal(order[2], "second")
			check.equal(order[3], "first")
			check.equal(received, "42")
			return nil
		end)

		test.case("removing middleware stops it running", function()
			local event = ServerEvent.new("mw-remove", gt.string())
			local calls = 0

			local remove = event:Use(function(_, ...)
				calls += 1
				return ...
			end)
			event:On(function() end)

			Runtime:assignIds()
			local id = Runtime:getNetworkId("mw-remove")
			Runtime:handleEvent(id, "a")
			remove()
			Runtime:handleEvent(id, "b")

			check.equal(calls, 1)
			check.equal(#event._middleware, 0)
			return nil
		end)

		test.case("function middleware sees the request and the response", function()
			local fn = ClientFunction.new("mw-fn", gt.args(gt.number()), gt.returns(gt.number()))
			local player = { Name = "Tester" } :: any
			local seen = {}

			fn:UseRequest(function(context, value)
				table.insert(seen, `{context.payload}:{context.direction}:{value}`)
				check.equal(context.player, player)
				return value * 2
			end)
			fn:UseResponse(function(context, value)
				table.insert(seen, `{context.payload}:{context.direction}:{value}`)
				return value + 1
			end)
			fn:On(function(_, value)
				return value * 10
			end)

			local result = Runtime.FunctionCallbacks["mw-fn"](player, 3)

			check.equal(seen[1], "request:incoming:3")
			check.equal(seen[2], "response:outgoing:60")
			check.equal(result, 61)
			return nil
		end)

		test.case("logger middleware formats messages and passes values through", function()
			local lines = {}
			local log = Middleware.logger({
				output = function(message)
					table.insert(lines, message)
				end,
			})

			local a, b = log({
				name = "Chat",
				kind = "ClientEvent",
				direction = "incoming",
				payload = "event",
				player = { Name = "Tester" } :: any,
			}, "hi", { score = 1 })

			check.equal(a, "hi")
			check.equal(b.score, 1)
			check.equal(lines[1], `[HYDROGEN] <- Chat from Tester: "hi", \{score = 1}`)

			log({
				name = "Ping",
				kind = "ServerFunction",
				direction = "outgoing",
				payload = "request",
				players = { { Name = "A" }, { Name = "B" } } :: any,
			}, 5)
			check.equal(lines[2], "[HYDROGEN] -> Ping request to 2 players: 5")
			return nil
		end)

		test.case("functions error before the network starts", function()
			local fn = ClientFunction.new("early-fn", gt.args(gt.number()), gt.returns(gt.number()))

			check.equal(Runtime.Initialized, false)
			local ok, err = pcall(function()
				fn:Fire(1)
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "before the network started", 1, true))
			return nil
		end)

		test.case("a listener disconnecting itself doesn't skip the next listener", function()
			local event = ServerEvent.new("self-disconnect", gt.string())
			local calls = {}

			local off
			off = event:On(function()
				table.insert(calls, "first")
				off()
			end)
			event:On(function()
				table.insert(calls, "second")
			end)

			Runtime:assignIds()
			Runtime:handleEvent(Runtime:getNetworkId("self-disconnect"), "x")

			check.equal(calls[1], "first")
			check.equal(calls[2], "second")
			check.equal(#event._listeners, 1)
			return nil
		end)

		test.case("logger truncates long strings", function()
			local lines = {}
			local log = Middleware.logger({
				output = function(message)
					table.insert(lines, message)
				end,
			})

			log({ name = "Spam", kind = "ClientEvent", direction = "incoming", payload = "event" }, string.rep("a", 500))

			check.equal(#lines[1] < 300, true)
			check.not_nil(string.find(lines[1], "(500 chars)", 1, true))
			return nil
		end)

		test.case("logger filter skips messages", function()
			local lines = {}
			local log = Middleware.logger({
				filter = function(context)
					return context.name ~= "Noisy"
				end,
				output = function(message)
					table.insert(lines, message)
				end,
			})

			log({ name = "Noisy", kind = "ServerEvent", direction = "incoming", payload = "event" }, 1)
			log({ name = "Quiet", kind = "ServerEvent", direction = "incoming", payload = "event" }, 1)

			check.equal(#lines, 1)
			return nil
		end)
		return nil
	end)
	return nil
end
