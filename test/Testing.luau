--!strict

-- Examples of testing game systems: app:replace for faked dependencies, Hydrogen.loopback
-- for client and server systems talking in one VM.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Middleware = require("../src/Network/Middleware")
local Runtime = require("../src/Network/Runtime")

local gt = Hydrogen.gt

return function()
	-- Apps and loopbacks a test opened, so a failing test can't leak into the next one.
	local apps: { Hydrogen.App } = {}
	local loopbacks: { Hydrogen.Loopback } = {}

	local function newApp(): Hydrogen.App
		local app = Hydrogen.App.new()
		table.insert(apps, app)
		return app
	end

	local function openLoopback(): Hydrogen.Loopback
		local loopback = Hydrogen.loopback()
		table.insert(loopbacks, loopback)
		return loopback
	end

	test.on_suite_enter(function(suite)
		if suite.name ~= "Testing" then
			return
		end

		Runtime.Initialized = false
		Runtime.RemoteEvent = nil
		Runtime.UnreliableRemoteEvent = nil
		Runtime.RemoteFunction = nil
		Runtime.OutgoingQueue = {}
		Runtime.PlayerQueues = {}
		Runtime.ReadyPlayers = {}
		Runtime.DepartedPlayers = setmetatable({}, { __mode = "k" }) :: any
		Runtime.Loopback = nil
		Runtime.Batching = false
		Runtime.Batches = {}
		Runtime.ServerBatch = nil
		Middleware.global = {}
	end)

	test.on_test_leave(function()
		for _, app in apps do
			app:stop()
		end
		for _, loopback in loopbacks do
			loopback:close()
		end
		table.clear(apps)
		table.clear(loopbacks)
	end)

	test.suite("Testing", function()
		test.case("replace starts a system with a faked dependency", function()
			-- Every headless test that starts an app opens a loopback, so the network starts fresh.
			openLoopback()
			local events = {}

			local Data = Hydrogen.define("Data", function()
				local Data = { coins = {} :: { [string]: number } }

				function Data:init()
					table.insert(events, "Data:init")
				end

				function Data.getCoins(name: string): number
					return Data.coins[name] or 0
				end

				return Data
			end)

			local Shop = Hydrogen.define("Shop", function(use)
				local Data = use(Data)
				local Shop = { seen = 0 }

				function Shop:init()
					table.insert(events, "Shop:init")
				end

				function Shop:start()
					Shop.seen = Data.getCoins("Alice")
				end

				return Shop
			end)

			local fake = {
				init = function()
					table.insert(events, "fake:init")
				end,
				getCoins = function(_name: string): number
					return 500
				end,
			}

			local app = newApp()
			app:addSystem(Shop)
			app:replace(Data, fake)
			app:start()

			-- The fake took Data's place before Shop, and the real Data never booted.
			check.equal(events[1], "fake:init")
			check.equal(events[2], "Shop:init")
			check.equal(#events, 2)
			check.equal(Shop.seen, 500)
			check.equal(Data.getCoins("Alice"), 500)

			app:stop()
			check.equal(Data.getCoins("Alice"), 0)
			check.equal(getmetatable(Data :: any), nil)
			return nil
		end)

		test.case("method calls on a replaced system use the fake's state", function()
			openLoopback()
			local Inventory = Hydrogen.define("Inventory", function()
				local Inventory = { total = 0 }
				function Inventory:add(amount: number)
					self.total += amount
				end
				return Inventory
			end)

			local Quests = Hydrogen.define("Quests", function(use)
				local Inventory = use(Inventory)
				return {
					start = function()
						Inventory:add(5)
					end,
				}
			end)

			local fake = { total = 100 }
			function fake:add(amount: number)
				self.total += amount
			end

			local app = newApp()
			app:addSystems({ Quests, Inventory })
			app:replace(Inventory, fake)
			app:start()

			check.equal(fake.total, 105)
			check.equal(rawget(Inventory :: any, "total"), nil)

			app:stop()
			check.equal(Inventory.total, 0)
			return nil
		end)

		test.case("replace is checked and undone when the boot fails", function()
			openLoopback()
			local Real = Hydrogen.define("ReplaceChecks", function()
				return { value = "real" }
			end)
			local Broken = Hydrogen.define("ReplaceBroken", function(use)
				use(Real)
				return {
					start = function()
						error("boom")
					end,
				}
			end)

			check.should_error(function()
				newApp():replace({} :: any, {})
				return nil
			end)
			check.should_error(function()
				newApp():replace(Real, Real :: any)
				return nil
			end)

			local started = newApp()
			started:start()
			check.should_error(function()
				started:replace(Real, {})
				return nil
			end)

			local app = newApp()
			app:addSystem(Broken)
			app:replace(Real, { value = "fake" })
			check.should_error(function()
				app:start()
				return nil
			end)
			check.equal(Real.value, "real")

			-- Two running apps can't both own the original.
			local first = newApp()
			first:replace(Real, { value = "first" })
			first:start()
			local second = newApp()
			second:replace(Real, { value = "second" })
			local ok, err = pcall(function()
				second:start()
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "already replaced", 1, true))
			check.equal(Real.value, "first")

			first:stop()
			check.equal(Real.value, "real")
			return nil
		end)

		test.case("loopback round trip between client and server systems", function()
			local loopback = openLoopback()
			local alice = loopback:join("Alice")

			local Buy = Hydrogen.clientEvent("loop-Buy", gt.string())
			local Bought = Hydrogen.serverEvent("loop-Bought", gt.string(), gt.number())
			local GetPrice = Hydrogen.clientFunction("loop-GetPrice", gt.args(gt.string()), gt.returns(gt.number()))

			local seen = {}
			Hydrogen.useMiddleware(function(context, ...)
				table.insert(seen, `{context.name}:{context.direction}:{context.payload}`)
				return ...
			end)

			local ShopServer = Hydrogen.define("LoopShopServer", function()
				local ShopServer = { buyers = {} :: { Player } }
				function ShopServer:init()
					Buy:On(function(player, item)
						table.insert(ShopServer.buyers, player)
						Bought:Fire(player, item, 10)
					end)
					GetPrice:On(function(_player, item)
						return #item
					end)
				end
				return ShopServer
			end)

			local ShopClient = Hydrogen.define("LoopShopClient", function()
				local ShopClient = { bought = {} :: { string }, price = 0, receiver = nil :: Player? }
				function ShopClient:init()
					Bought:On(function(item, price)
						table.insert(ShopClient.bought, `{item}:{price}`)
						ShopClient.receiver = loopback:client()
					end)
				end
				function ShopClient:start()
					Buy:Fire("sword")
					ShopClient.price = GetPrice:Fire("bow")
				end
				return ShopClient
			end)

			local app = newApp()
			app:addSystems({ ShopServer, ShopClient })
			app:start()

			check.equal(ShopServer.buyers[1], alice)
			check.equal(ShopClient.bought[1], "sword:10")
			check.equal(ShopClient.receiver, alice)
			check.equal(ShopClient.price, 3)
			check.not_nil(table.find(seen, "loop-Buy:outgoing:event"))
			check.not_nil(table.find(seen, "loop-Buy:incoming:event"))
			check.not_nil(table.find(seen, "loop-GetPrice:incoming:request"))
			check.not_nil(table.find(seen, "loop-GetPrice:incoming:response"))
			return nil
		end)

		test.case("loopback validates payloads and copies tables", function()
			local loopback = openLoopback()
			loopback:join("Alice")

			local Save = Hydrogen.clientEvent("loop-Save", gt.table({ score = gt.number() }))
			local received = {}
			Save:On(function(_player, data)
				table.insert(received, data)
			end)
			-- What an exploiter could send: the client's own check is skipped, the server's isn't.
			Save:Use(function(context, data)
				if context.direction == "outgoing" and data.score < 0 then
					return { score = "lots" } :: any
				end
				return data
			end)

			newApp():start()

			local sent = { score = 1 }
			Save:Fire(sent)
			Save:Fire({ score = -1 })

			check.equal(#received, 1)
			check.equal(received[1].score, 1)
			check.not_equal(received[1], sent)
			return nil
		end)

		test.case("loopback with several clients", function()
			local loopback = openLoopback()
			local alice = loopback:join("Alice")
			local bob = loopback:join("Bob")

			local Ready = Hydrogen.clientEvent("loop-Ready", gt.boolean())
			local Welcome = Hydrogen.serverEvent("loop-Welcome", gt.string())
			local Announce = Hydrogen.serverEvent("loop-Announce", gt.string())
			local WhoAreYou = Hydrogen.serverFunction("loop-WhoAreYou", gt.string())(gt.string())

			local ready: { Player } = {}
			local inbox: { [Player]: { string } } = {}
			local function record(text: string)
				local client = loopback:client() :: Player
				inbox[client] = inbox[client] or {}
				table.insert(inbox[client], text)
			end

			local Lobby = Hydrogen.define("LoopLobby", function()
				return {
					init = function()
						Ready:On(function(player)
							table.insert(ready, player)
						end)
						Welcome:On(record)
						Announce:On(record)
						WhoAreYou:On(function(question)
							return `{(loopback:client() :: Player).Name} heard {question}`
						end)
					end,
					-- Fired before the client is ready, so it is queued and sent on the handshake.
					playerAdded = function(_, player: Player)
						Welcome:Fire(player, `hi {player.Name}`)
					end,
				}
			end)

			local app = newApp()
			app:addSystem(Lobby)
			app:start()

			check.should_error(function()
				Ready:Fire(true)
				return nil
			end)
			loopback:as(bob, function()
				Ready:Fire(true)
			end)
			check.equal(ready[1], bob)

			check.equal(WhoAreYou:Fire(bob, "hello"), "Bob heard hello")

			local carol = loopback:join("Carol")
			check.equal(inbox[carol][1], "hi Carol")

			loopback:leave(alice)
			Announce:FireAll("round over")
			check.equal(inbox[alice][1], "hi Alice")
			check.equal(inbox[alice][2], nil)
			check.equal(inbox[bob][2], "round over")
			check.equal(inbox[carol][2], "round over")
			return nil
		end)

		test.case("batching is skipped under loopback and reset on close", function()
			local Tick = Hydrogen.serverEvent("loop-Tick", gt.number())
			local received = {}
			Tick:On(function(value)
				table.insert(received, value)
			end)

			local loopback = openLoopback()
			local player = loopback:join()
			local app = Hydrogen.App.new({ batching = true })
			table.insert(apps, app)
			app:start()

			-- Sent straight away, not held for a Heartbeat the headless runtime doesn't have.
			check.equal(Runtime.Batching, false)
			Tick:Fire(player, 1)
			check.equal(received[1], 1)

			Runtime.Batching = true
			loopback:close()
			check.equal(Runtime.Batching, false)
			check.equal(Runtime.ServerBatch, nil)
			return nil
		end)

		test.case("closing the loopback undoes what the test added", function()
			local Ping = Hydrogen.serverEvent("loop-Ping", gt.number())
			local before = 0
			Ping:On(function()
				before += 1
			end)

			local first = openLoopback()
			first:join()
			Ping:On(function() end)
			newApp():start()
			check.equal(#Ping._listeners, 2)

			first:close()
			check.equal(#Ping._listeners, 1)
			check.equal(Runtime.Initialized, false)

			-- A later test can open a fresh loopback and start the network again.
			local second = openLoopback()
			local player = second:join()
			newApp():start()
			Ping:Fire(player, 1)
			check.equal(before, 1)
			return nil
		end)

		return nil
	end)
	return nil
end
