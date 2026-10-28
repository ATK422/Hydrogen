--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local gt = require("../roblox_packages/.pesde/corecii+greentea/0.4.11/greentea/src/GreenTea")
local App = require("../src/App")
local Network = require("../src/Network")
local ClientEvent = require("../src/Network/ClientEvent")
local ClientFunction = require("../src/Network/ClientFunction")
local Codec = require("../src/Network/Codec")
local Middleware = require("../src/Network/Middleware")
local Runtime = require("../src/Network/Runtime")
local ServerEvent = require("../src/Network/ServerEvent")
local ServerFunction = require("../src/Network/ServerFunction")

type Call = { player: any, remote: string, args: { [number]: any, n: number } }

-- Swaps in recording remotes with batching on, runs body, then puts the runtime back.
local function withBatching(body: (calls: { Call }) -> ())
	local saved = {
		Initialized = Runtime.Initialized,
		Batching = Runtime.Batching,
		RemoteEvent = Runtime.RemoteEvent,
		UnreliableRemoteEvent = Runtime.UnreliableRemoteEvent,
		RemoteFunction = Runtime.RemoteFunction,
	}

	local calls: { Call } = {}
	local function remote(kind: string)
		return {
			FireClient = function(_, player, ...)
				table.insert(calls, { player = player, remote = kind, args = table.pack(...) })
			end,
			FireServer = function(_, ...)
				table.insert(calls, { remote = kind, args = table.pack(...) })
			end,
			-- Answers with the arguments it was sent.
			InvokeClient = function(_, player, id, ...)
				table.insert(calls, { player = player, remote = kind, args = table.pack(id, ...) })
				return ...
			end,
		}
	end

	Runtime.Initialized = true
	Runtime.Batching = true
	Runtime.RemoteEvent = remote("reliable") :: any
	Runtime.UnreliableRemoteEvent = remote("unreliable") :: any
	Runtime.RemoteFunction = remote("function") :: any

	local ok, err = pcall(body, calls)

	for key, value in saved do
		(Runtime :: any)[key] = value
	end
	Runtime.Batches = {}
	Runtime.ServerBatch = nil

	if not ok then
		error(err, 0)
	end
end

local function readyPlayer(name: string): any
	local player = { Name = name, Parent = game:GetService("Players") } :: any
	Runtime.ReadyPlayers[player] = true
	return player
end

-- What a receiver gets: the values after the batch id.
local function batchValues(call: Call): ...any
	return table.unpack(call.args, 2, call.args.n)
end

local function roundTrip(codec: Codec.Codec, ...: any): ...any
	return codec.decode(codec.encode(...))
end

return function()
	test.on_suite_enter(function(suite)
		if suite.name ~= "Network" then
			return
		end

		Runtime.Initialized = false
		Runtime.RemoteEvent = nil
		Runtime.UnreliableRemoteEvent = nil
		Runtime.RemoteFunction = nil
		Runtime.Batching = false
		Runtime.Batches = {}
		Runtime.ServerBatch = nil
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

		test.case("batching sends a frame's events as one call per player, in order", function()
			local text = ServerEvent.new("batch-text", gt.string())
			local pair = ServerEvent.new("batch-pair", gt.number(), gt.optional(gt.string()))
			Runtime:assignIds()

			local received = {}
			text:On(function(value)
				table.insert(received, value)
			end)
			pair:On(function(value, label)
				table.insert(received, value)
				table.insert(received, label == nil)
			end)

			withBatching(function(calls)
				local first = readyPlayer("First")
				local second = readyPlayer("Second")

				text:Fire({ first }, "one")
				pair:Fire({ first, second }, 2, nil)
				text:Fire({ first }, "three")
				check.equal(#calls, 0)

				Runtime:flushBatches()
				check.equal(#calls, 2)

				local toFirst = if calls[1].player == first then calls[1] else calls[2]
				local toSecond = if calls[1].player == second then calls[1] else calls[2]
				check.equal(toFirst.remote, "reliable")
				check.equal(toFirst.args[1], 0)

				-- A lone message goes as itself, keeping its trailing nil.
				check.equal(toSecond.args[1], Runtime:getNetworkId("batch-pair"))
				check.equal(toSecond.args[2], 2)
				check.equal(toSecond.args.n, 3)

				Runtime:handleBatch(nil, batchValues(toFirst))
				check.equal(#received, 4)
				check.equal(received[1], "one")
				check.equal(received[2], 2)
				check.equal(received[3], true)
				check.equal(received[4], "three")

				Runtime:flushBatches()
				check.equal(#calls, 2)
			end)
			return nil
		end)

		test.case("client batches reach server listeners with the sender, in order", function()
			local event = ClientEvent.new("batch-client", gt.number())
			Runtime:assignIds()

			local received = {}
			event:On(function(player, value)
				table.insert(received, `{player.Name}:{value}`)
			end)

			withBatching(function(calls)
				for value = 1, 3 do
					event:Fire(value)
				end
				check.equal(#calls, 0)

				Runtime:flushBatches()
				check.equal(#calls, 1)
				check.equal(calls[1].player, nil)

				Runtime:handleBatch({ Name = "Sender" } :: any, batchValues(calls[1]))
				check.equal(table.concat(received, ","), "Sender:1,Sender:2,Sender:3")
			end)
			return nil
		end)

		test.case("batching keeps queuing for unready players and dropping departed ones", function()
			local event = ServerEvent.new("batch-queue", gt.string())
			Runtime:assignIds()

			withBatching(function(calls)
				local ready = readyPlayer("Ready")
				local leaving = readyPlayer("Leaving")
				local orphaned = readyPlayer("Orphaned")
				local unready = { Name = "Unready", Parent = game:GetService("Players") } :: any
				local departed = readyPlayer("Departed")
				Runtime:removePlayer(departed)

				event:Fire({ ready, leaving, orphaned, unready, departed }, "hi")
				check.equal(#Runtime.PlayerQueues[unready], 1)
				check.equal(Runtime.Batches[departed], nil)

				-- Leaving between the fire and the flush drops what was batched.
				Runtime:removePlayer(leaving)
				orphaned.Parent = nil
				Runtime:flushBatches()

				check.equal(#calls, 1)
				check.equal(calls[1].player, ready)
				check.equal(calls[1].args[2], "hi")
			end)
			return nil
		end)

		test.case("unreliable batches are split to stay under the size limit", function()
			local messages = {}
			for index = 1, 50 do
				table.insert(messages, { id = 1, args = table.pack(string.rep("x", 100), index) })
			end
			-- Too big for any batch: sent on its own between the others.
			table.insert(messages, 26, { id = 2, args = table.pack(string.rep("y", 2000)) })

			local sends = Runtime:packBatch(messages, 900)
			check.equal(#sends > 2, true)

			local order = {}
			for _, send in sends do
				if send[1] == 0 then
					local bytes = 0
					local messageCount = 0
					local index = 2
					while index <= send.n do
						local count = send[index + 1]
						bytes += #send[index + 2] + 18
						messageCount += 1
						table.insert(order, send[index + 3])
						index += 2 + count
					end
					check.equal(messageCount > 1, true)
					check.equal(bytes < 900, true)
				else
					table.insert(order, if send[1] == 2 then "big" else send[3])
				end
			end

			check.equal(#order, 51)
			for index = 1, 25 do
				check.equal(order[index], index)
			end
			check.equal(order[26], "big")
			for index = 26, 50 do
				check.equal(order[index + 1], index)
			end

			-- Reliable batches have no size limit.
			check.equal(#Runtime:packBatch(messages), 1)
			return nil
		end)

		test.case("unreliable events batch separately over the unreliable remote", function()
			local reliable = ServerEvent.new("batch-reliable", gt.number())
			local frame = ServerEvent.new("batch-frame", gt.number()):Unreliable()
			Runtime:assignIds()

			withBatching(function(calls)
				local player = readyPlayer("Player")
				for value = 1, 3 do
					frame:Fire({ player }, value)
					reliable:Fire({ player }, value)
				end
				Runtime:flushBatches()

				check.equal(#calls, 2)
				check.equal(calls[1].remote, "reliable")
				check.equal(calls[2].remote, "unreliable")
				check.equal(calls[1].args.n, 1 + 3 * 3)
				check.equal(calls[2].args.n, 1 + 3 * 3)
			end)
			return nil
		end)

		test.case("calling a function sends batched events first", function()
			local event = ServerEvent.new("batch-before-fn", gt.string())
			local fn = ServerFunction.new("batch-fn", gt.number())(gt.number()):SetTimeout(math.huge)
			Runtime:assignIds()

			withBatching(function(calls)
				local player = readyPlayer("Player")
				event:Fire({ player }, "first")
				check.equal(fn:Fire(player, 5), 5)

				check.equal(#calls, 2)
				check.equal(calls[1].remote, "reliable")
				check.equal(calls[2].remote, "function")
			end)
			return nil
		end)

		test.case("malformed batches are dropped without erroring", function()
			local event = ClientEvent.new("batch-malformed", gt.string())
			Runtime:assignIds()
			local id = Runtime:getNetworkId("batch-malformed")

			local received = {}
			event:On(function(_, value)
				table.insert(received, value)
			end)

			local player = { Name = "Exploiter" } :: any
			check.should_not_error(function()
				Runtime:handleBatch(player, id, "one", "a")
				Runtime:handleBatch(player, id, 5, "a")
				Runtime:handleBatch(player, id, -1)
				Runtime:handleBatch(player, id, 0.5, "a")
				Runtime:handleBatch(player, 0, 0)
				Runtime:handleBatch(player, id, 1, "kept", id, 9, "cut")
				return nil
			end)

			check.equal(#received, 1)
			check.equal(received[1], "kept")
			return nil
		end)

		test.case("App.new passes batching to the network", function()
			check.equal(App.new({ batching = true })._batching, true)
			check.equal(App.new()._batching, false)
			return nil
		end)

		test.case("codec round trips numbers, strings and booleans", function()
			local numbers = Codec.new(gt.build(gt.number(), gt.number(), gt.number()), "numbers")
			local a, b, c = roundTrip(numbers, 1.5, -1e300, math.huge)
			check.equal(a, 1.5)
			check.equal(b, -1e300)
			check.equal(c, math.huge)
			check.equal(buffer.len((numbers.encode(1, 2, 3))), 24)

			local widths = {
				{ range = "[0, 255]", value = 200, size = 1 },
				{ range = "[-100, 100]", value = -100, size = 1 },
				{ range = "[0, 60000]", value = 60000, size = 2 },
				{ range = "[-1000, 1000]", value = -999, size = 2 },
				{ range = "[0, 4000000000]", value = 3999999999, size = 4 },
				{ range = "[-2000000000, 2000000000]", value = -2000000000, size = 4 },
			}
			for _, width in widths do
				local codec = Codec.new(gt.build(gt.number({ integer = true, range = width.range })), "int")
				check.equal(buffer.len((codec.encode(width.value))), width.size)
				check.equal(roundTrip(codec, width.value), width.value)
			end

			local strings = Codec.new(gt.build(gt.string()), "strings")
			for _, value in { "", "héllo", "a\0b", string.rep("z", 300) } do
				check.equal(roundTrip(strings, value), value)
			end
			-- One length byte below 128.
			check.equal(buffer.len((strings.encode("hi"))), 3)

			local booleans = Codec.new(gt.build(gt.boolean(), gt.boolean()), "booleans")
			local yes, no = roundTrip(booleans, true, false)
			check.equal(yes, true)
			check.equal(no, false)
			return nil
		end)

		test.case("codec round trips Vector3, CFrame and buffer", function()
			local codec = Codec.new(gt.build(gt.Vector3(), gt.CFrame(), gt.buffer()), "datatypes")
			local position = Vector3.new(1.5, -2.25, 1e6)
			local transform = CFrame.new(4, 5, 6) * CFrame.Angles(0.3, -1.2, 2)
			local data = buffer.fromstring("raw\0bytes")

			local encoded = codec.encode(position, transform, data)
			check.equal(buffer.len(encoded), 12 + 48 + 1 + 9)

			local v, cf, buf = codec.decode(encoded)
			check.equal(v, position)
			check.equal(cf, transform)
			check.equal(buffer.tostring(buf), "raw\0bytes")
			return nil
		end)

		test.case("codec round trips arrays, tables, dictionaries, optionals and literals", function()
			local unit = gt.table({
				name = gt.string(),
				hp = gt.number({ integer = true, range = "[0, 255]" }),
				position = gt.Vector3(),
				tag = gt.optional(gt.string()),
				state = gt.literal("alive"),
			})
			local codec = Codec.new(gt.build(gt.array(unit), gt.dictionary(gt.string(), gt.number()), gt.array(gt.boolean())), "units")

			local units = {
				{ name = "a", hp = 10, position = Vector3.new(1, 2, 3), tag = "boss", state = "alive" },
				{ name = "b", hp = 0, position = Vector3.zero, state = "alive" },
			}
			local decodedUnits, scores, flags = roundTrip(codec, units, { red = 1, blue = 2.5 }, {})

			check.equal(#decodedUnits, 2)
			check.equal(decodedUnits[1].name, "a")
			check.equal(decodedUnits[1].hp, 10)
			check.equal(decodedUnits[1].position, Vector3.new(1, 2, 3))
			check.equal(decodedUnits[1].tag, "boss")
			check.equal(decodedUnits[1].state, "alive")
			check.equal(decodedUnits[2].tag, nil)
			check.equal(decodedUnits[2].hp, 0)
			check.equal(scores.red, 1)
			check.equal(scores.blue, 2.5)
			check.equal(#flags, 0)
			return nil
		end)

		test.case("codec round trips varargs and falls back for types it can't pack", function()
			local varargs = Codec.new(gt.build(gt.vararg(gt.number())), "varargs")
			local packed = table.pack(roundTrip(varargs, 1, 2, 3))
			check.equal(packed.n, 3)
			check.equal(packed[3], 3)
			check.equal(select("#", roundTrip(varargs)), 0)

			local folder = Instance.new("Folder")
			local mixed = Codec.new(gt.build(gt.union(gt.string(), gt.number()), gt.any(), gt.Instance(), gt.optional(gt.any())), "mixed")
			local buf, refs = mixed.encode(5, { nested = true }, folder, nil)
			check.not_nil(refs)
			check.equal(#(refs :: any), 3)

			local a, b, c, d = mixed.decode(buf, refs)
			check.equal(a, 5)
			check.equal(b.nested, true)
			check.equal(c, folder)
			check.equal(d, nil)

			-- Nothing to fall back on means no side table at all.
			local _, none = Codec.new(gt.build(gt.string()), "plain").encode("x")
			check.equal(none, nil)

			local empty = Codec.new(gt.build(), "empty")
			check.equal(buffer.len((empty.encode())), 0)
			return nil
		end)

		test.case("codec rejects malformed input and values outside the schema", function()
			local codec = Codec.new(gt.build(gt.array(gt.number({ integer = true, range = "[0, 255]" }))), "bytes")

			check.should_error(function()
				codec.encode({ 300 })
				return nil
			end)
			check.should_error(function()
				codec.encode({ "nope" })
				return nil
			end)

			local valid = codec.encode({ 1, 2, 3 })
			check.should_error(function()
				codec.decode("not a buffer")
				return nil
			end)

			local truncated = buffer.create(2)
			buffer.copy(truncated, 0, valid, 0, 2)
			check.should_error(function()
				codec.decode(truncated)
				return nil
			end)

			local trailing = buffer.create(buffer.len(valid) + 1)
			buffer.copy(trailing, 0, valid)
			check.should_error(function()
				codec.decode(trailing)
				return nil
			end)

			-- A huge claimed length is refused before anything is allocated.
			local huge = buffer.create(5)
			buffer.writeu32(huge, 0, 0xFFFFFFFF)
			buffer.writeu8(huge, 4, 0x0F)
			check.should_error(function()
				codec.decode(huge)
				return nil
			end)
			return nil
		end)

		test.case("encoded events keep middleware and validation on plain values", function()
			local event = ServerEvent.new("enc-event", gt.number({ range = "[0, 10]" }), gt.Vector3()):Encode()
			local seen = {}
			event:Use(function(context, value, position)
				table.insert(seen, `{context.direction}:{typeof(value)}:{typeof(position)}`)
				return value, position
			end)

			local received = {}
			event:On(function(value, position)
				table.insert(received, { value = value, position = position })
			end)

			event:Fire({}, 5, Vector3.new(1, 2, 3))
			local packet = Runtime.OutgoingQueue[#Runtime.OutgoingQueue]
			check.equal(typeof(packet.args[1]), "buffer")

			Runtime:assignIds()
			local id = Runtime:getNetworkId("enc-event")
			Runtime:handleEvent(id, table.unpack(packet.args, 1, packet.args.n))

			check.equal(seen[1], "outgoing:number:Vector3")
			check.equal(seen[2], "incoming:number:Vector3")
			check.equal(#received, 1)
			check.equal(received[1].value, 5)
			check.equal(received[1].position, Vector3.new(1, 2, 3))

			-- Decodes fine, but fails the schema, so it's still dropped.
			Runtime:handleEvent(id, (event._codec :: any).encode(99, Vector3.zero))
			check.should_not_error(function()
				Runtime:handleEvent(id, "garbage")
				return nil
			end)
			check.equal(#received, 1)
			return nil
		end)

		test.case("encoded client events decode before reaching the sending player's listeners", function()
			local event = ClientEvent.new("enc-client", gt.string()):Encode()
			local received = nil
			event:On(function(player, value)
				received = `{player.Name}:{value}`
			end)

			event:Fire("hello")
			local packet = Runtime.OutgoingQueue[#Runtime.OutgoingQueue]
			check.equal(typeof(packet.args[1]), "buffer")

			Runtime:assignIds()
			Runtime:handleEvent(Runtime:getNetworkId("enc-client"), { Name = "Tester" }, table.unpack(packet.args, 1, packet.args.n))
			check.equal(received, "Tester:hello")
			return nil
		end)

		test.case("encoded functions pack requests and responses", function()
			local fn = ClientFunction.new("enc-fn", gt.args(gt.string(), gt.number()), gt.returns(gt.array(gt.number()))):Encode()
			local requests = {}
			fn:UseRequest(function(context, label, value)
				table.insert(requests, `{context.direction}:{label}:{value}`)
				return label, value
			end)
			fn:On(function(_, _, value)
				return { value, value * 2 }
			end)

			local callback = Runtime.FunctionCallbacks["enc-fn"]
			local response = table.pack(callback({ Name = "Tester" }, (fn._argsCodec :: any).encode("x", 2)))
			check.equal(typeof(response[1]), "buffer")

			local values = (fn._returnsCodec :: any).decode(table.unpack(response, 1, response.n))
			check.equal(values[1], 2)
			check.equal(values[2], 4)
			check.equal(requests[1], "incoming:x:2")

			check.should_error(function()
				callback({ Name = "Tester" }, "garbage")
				return nil
			end)

			local serverFn = ServerFunction.new("enc-server-fn", gt.Vector3())(gt.boolean()):Encode():SetTimeout(math.huge)
			Runtime:assignIds()
			withBatching(function(calls)
				Runtime.RemoteFunction = {
					InvokeClient = function(_, _, _, ...)
						check.equal(typeof((...)), "buffer")
						return (serverFn._returnsCodec :: any).encode(true)
					end,
				} :: any
				check.equal(serverFn:Fire({ Name = "Client" } :: any, Vector3.one), true)
			end)
			return nil
		end)
		return nil
	end)
	return nil
end
