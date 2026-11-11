--!strict

-- Examples of testing game systems: Hydrogen.test for one-call tests with expectations and a
-- fake clock, and the tools under it: app:replace for faked dependencies, Hydrogen.loopback
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

	-- Hydrogen.test is the one-call way to test systems; the "Testing" suite below shows the
	-- loopback and replace tools it is built on.
	test.suite("Harness", function()
		-- The testing.md recipe "Hit detection without spatial queries", as written there.
		test.case("a replaced query system stands in for spatial queries", function()
			local SpatialSystem = Hydrogen.define("RecipeSpatial", function()
				local Spatial = {}
				function Spatial.charactersInBox(cframe: CFrame, size: Vector3, ignore: { Instance }): { Model }
					local params = OverlapParams.new()
					params.FilterDescendantsInstances = ignore
					local list: { Model } = {}
					for _, part in workspace:GetPartBoundsInBox(cframe, size, params) do
						table.insert(list, part:FindFirstAncestorOfClass("Model") :: Model)
					end
					return list
				end
				return Spatial
			end)
			local Melee = Hydrogen.define("RecipeMelee", function(use)
				local Spatial = use(SpatialSystem)
				local Melee = {}
				function Melee.swing(attacker: Model, root: CFrame): { Model }
					local hitbox = root * CFrame.new(0, 0, -3)
					return Spatial.charactersInBox(hitbox, Vector3.new(5, 5, 4), { attacker })
				end
				return Melee
			end)

			local victim = Instance.new("Model")
			local lastBox: CFrame? = nil
			Hydrogen.test({
				systems = { Melee },
				replace = {
					[SpatialSystem] = {
						charactersInBox = function(cframe: CFrame, _size: Vector3, _ignore: { Instance }): { Model }
							lastBox = cframe
							return { victim }
						end,
					},
				},
			}, function(_t)
				local hits = Melee.swing(Instance.new("Model"), CFrame.new(0, 0, 0))
				check.equal(hits[1], victim)
				check.equal((lastBox :: CFrame).Position.Z, -3)
			end)
			return nil
		end)

		test.case("client listeners registered in init hear events queued before the network started", function()
			local Welcome = Hydrogen.serverEvent("ListenerHookWelcome", gt.string())
			local heard: { string } = {}
			local target: Player? = nil
			local Sender = Hydrogen.define("ListenerHookSender", function()
				return {
					-- Queued: the network starts after every init.
					init = function()
						Welcome:Fire(target :: Player, "hello")
					end,
				}
			end)
			local InInit = Hydrogen.define("ListenerHookInit", function()
				return {
					init = function()
						Welcome:On(function(text: string)
							table.insert(heard, `init:{text}`)
						end)
					end,
				}
			end)
			local InStart = Hydrogen.define("ListenerHookStart", function()
				return {
					start = function()
						Welcome:On(function(text: string)
							table.insert(heard, `start:{text}`)
						end)
					end,
				}
			end)

			Hydrogen.test({ systems = { Sender, InInit, InStart }, players = 1, start = false }, function(t, player)
				target = player
				t:start()
				t:advance(0)
			end)
			check.equal(table.concat(heard, ","), "init:hello")
			return nil
		end)

		test.case("Hydrogen.test boots systems with fakes and players", function()
			local Buy = Hydrogen.clientEvent("h-Buy", gt.string())
			local Bought = Hydrogen.serverEvent("h-Bought", gt.string(), gt.number())

			local Data = Hydrogen.define("HarnessData", function()
				local Data = {}
				function Data.coins(_player: Player): number
					return 0
				end
				return Data
			end)

			local Shop = Hydrogen.define("HarnessShop", function(use)
				local Data = use(Data)
				return {
					init = function()
						Buy:On(function(player, item)
							Bought:Fire(player, item, Data.coins(player))
						end)
					end,
				}
			end)

			local fakeData = {
				coins = function(_player: Player): number
					return 500
				end,
			}

			Hydrogen.test({
				systems = { Shop },
				replace = { [Data] = fakeData },
				players = { "Alice", "Bob" },
			}, function(t, alice, bob)
				t:as(alice, function()
					Buy:Fire("sword")
				end)

				t:expect(Buy):firedBy(alice, "sword")
				t:expect(Bought):firedTo(alice, "sword", 500):firedTimes(1)
				t:expect(Bought):notFired(bob)
			end)

			-- The harness stopped the app, so the real Data is back.
			check.equal(Data.coins(nil :: any), 0)
			return nil
		end)

		test.case("expectations compare Vector3 and CFrame arguments by value", function()
			-- Network objects are created before the harness starts the network.
			local Aim = Hydrogen.clientEvent("ExpectAim", Hydrogen.gt.any())
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				t:as(alice, function()
					Aim:Fire(Vector3.new(1, 2, 3))
					Aim:Fire(CFrame.new(4, 5, 6))
				end)
				t:expect(Aim):firedBy(alice, Vector3.new(1, 2, 3))
				t:expect(Aim):firedBy(alice, CFrame.new(4, 5, 6))
				local ok = pcall(function()
					t:expect(Aim):firedBy(alice, Vector3.new(9, 9, 9))
				end)
				check.equal(ok, false)
			end)
			return nil
		end)

		test.case("failed expectations say what happened instead", function()
			local Ping = Hydrogen.serverEvent("h-Ping", gt.number())
			local Pong = Hydrogen.clientEvent("h-Pong", gt.number())

			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				Ping:Fire(alice, 1)

				local ok, err = pcall(function()
					t:expect(Ping):firedTo(alice, 2)
				end)
				check.equal(ok, false)
				local message = tostring(err)
				check.not_nil(string.find(message, "Expected h-Ping to be fired to Alice with (2), but it was fired 1 time:", 1, true))
				check.not_nil(string.find(message, "to Alice: (1)", 1, true))
				-- The error points at the test, not at the harness.
				check.not_nil(string.find(message, "test.Testing:", 1, true))

				ok, err = pcall(function()
					t:expect(Ping):notFired()
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "not to be fired, but it was fired 1 time", 1, true))

				-- A client event is checked with firedBy, and the error says so.
				ok, err = pcall(function()
					t:expect(Pong):firedTo(alice)
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "use firedBy", 1, true))

				-- A missing player is an error, not a match with everyone.
				ok, err = pcall(function()
					t:expect(Ping):firedTo(nil :: any)
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "firedTo expects a player", 1, true))

				-- t.any stands for one value of any kind.
				t:expect(Ping):firedTo(alice, t.any):notFired(bob)

				t:clear()
				t:expectNothingFired()
				Ping:FireAll(3)
				t:expect(Ping):firedTimes(2)
				ok, err = pcall(function()
					t:expectNothingFired()
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "h-Ping to Bob: (3)", 1, true))
			end)
			return nil
		end)

		test.case("server handlers run as the server, not as the sending client", function()
			local Hello = Hydrogen.clientEvent("h-Hello", gt.string())
			local Who = Hydrogen.clientFunction("h-Who", gt.args(), gt.returns(gt.boolean()))
			local Welcome = Hydrogen.serverEvent("h-Welcome", gt.string())

			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local onServer: { any } = {}
				local onClient: { any } = {}
				Hello:On(function(player, text)
					table.insert(onServer, t.net:client() or "server")
					Welcome:Fire(player, text)
				end)
				Welcome:On(function()
					table.insert(onClient, t.net:client())
				end)
				Who:On(function()
					return t.net:client() == nil
				end)

				t:as(alice, function()
					Hello:Fire("hi")
					check.equal(Who:Fire(), true)
				end)
				check.equal(onServer[1], "server")
				check.equal(onClient[1], alice)
			end)
			return nil
		end)

		test.case("tables are compared by value and recorded as delivered", function()
			local Inventory = Hydrogen.serverEvent("h-Inventory", gt.table({ items = gt.array(gt.string()) }))

			Hydrogen.test({ players = 1 }, function(t, player)
				Inventory:On(function(inventory)
					-- A listener changing what it got doesn't change what was recorded.
					table.insert(inventory.items, "changed")
				end)

				local sent = { items = { "sword" } }
				Inventory:Fire(player, sent)

				t:expect(Inventory):firedTo(player, { items = { "sword" } })
				check.should_error(function()
					t:expect(Inventory):firedTo(player, { items = { "sword", "changed" } })
					return nil
				end)
				check.equal(#sent.items, 1)
			end)
			return nil
		end)

		test.case("function expectations: called, calledBy, returned", function()
			local GetPrice = Hydrogen.clientFunction("h-GetPrice", gt.args(gt.string()), gt.returns(gt.number()))
			local Confirm = Hydrogen.serverFunction("h-Confirm", gt.string())(gt.boolean())

			local ShopServer = Hydrogen.define("HarnessShopServer", function()
				return {
					init = function()
						GetPrice:On(function(_player, item)
							return #item
						end)
					end,
				}
			end)
			local ShopClient = Hydrogen.define("HarnessShopClient", function()
				return {
					init = function()
						Confirm:On(function(question)
							return question == "buy?"
						end)
					end,
				}
			end)

			Hydrogen.test({ systems = { ShopServer, ShopClient }, players = { "Alice" } }, function(t, alice)
				-- With one client, client code needs no t:as.
				check.equal(GetPrice:Fire("bow"), 3)
				t:expect(GetPrice):calledBy(alice, "bow"):returned(3):calledTimes(1)

				check.equal(Confirm:Fire(alice, "buy?"), true)
				t:expect(Confirm):calledBy(alice, "buy?"):returned(true)

				check.should_error(function()
					t:expect(Confirm):returned(false)
					return nil
				end)
				check.should_error(function()
					t:expect(GetPrice):fired()
					return nil
				end)
			end)
			return nil
		end)

		test.case("warnings are captured", function()
			local Save = Hydrogen.clientEvent("h-Save", gt.number())

			Hydrogen.test({ players = 1 }, function(t)
				-- What an exploiter could send: the server drops it with a warning.
				Save:Use(function(context, value)
					if context.direction == "outgoing" then
						return "lots" :: any
					end
					return value
				end)
				Save:Fire(5)

				t:expect(Save):notFired()
				local ok, err = pcall(function()
					t:expectNoWarnings()
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "Dropped invalid h-Save from Player1", 1, true))

				t:expectWarning("Dropped invalid h-Save")
				t:expectNoWarnings()
				check.equal(#t:warnings(), 1)

				check.should_error(function()
					t:expectWarning("never emitted")
					return nil
				end)
			end)
			return nil
		end)

		test.case("teardown runs even when the test errors", function()
			local stopped = false
			local Saver = Hydrogen.define("HarnessSaver", function()
				return {
					stop = function()
						stopped = true
					end,
				}
			end)

			local ok, err = pcall(Hydrogen.test, { systems = { Saver } }, function()
				error("test body failed")
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "test body failed", 1, true))

			check.equal(stopped, true)
			check.equal(Runtime.Loopback, nil)
			check.equal(Runtime.Initialized, false)
			check.equal(Runtime.Observer, nil)
			check.equal(Hydrogen.Clock.active(), nil)
			check.equal(Hydrogen.Clock.now, os.clock)
			return nil
		end)

		test.case("a boot that fails cleans up too", function()
			local Broken = Hydrogen.define("HarnessBroken", function()
				return {
					start = function()
						error("boot boom")
					end,
				}
			end)

			local ran = false
			local ok, err = pcall(Hydrogen.test, { systems = { Broken } }, function()
				ran = true
			end)
			check.equal(ok, false)
			check.equal(ran, false)
			check.not_nil(string.find(tostring(err), "boot boom", 1, true))
			check.equal(Runtime.Loopback, nil)
			check.equal(Hydrogen.Clock.active(), nil)
			return nil
		end)

		test.case("start = false leaves setup to the test", function()
			local events = {}
			local Real = Hydrogen.define("HarnessManualReal", function()
				return {
					playerAdded = function(_, player: Player)
						table.insert(events, `real:{player.Name}`)
					end,
				}
			end)
			local fake = {
				playerAdded = function(_, player: Player)
					table.insert(events, `fake:{player.Name}`)
				end,
			}

			Hydrogen.test({ start = false }, function(t)
				t:add(Real)
				t:replace(Real, fake)
				t:join("Alice")
				t:start()
				check.equal(events[1], "fake:Alice")
				check.equal(#events, 1)

				-- Too late to replace once the app runs; the error says what to do instead.
				local ok, err = pcall(function()
					t:replace(Real, fake)
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "pass replace", 1, true))
				check.should_error(function()
					t:start()
					return nil
				end)
			end)
			return nil
		end)

		test.case("the fake clock drives server function timeouts", function()
			local Ask = Hydrogen.serverFunction("h-Ask", gt.string())(gt.string())
			local AskClient = Hydrogen.define("HarnessAskClient", function()
				return {
					init = function()
						-- A client that takes a minute to answer.
						Ask:On(function(_question)
							Hydrogen.Clock.wait(60)
							return "late"
						end)
					end,
				}
			end)

			Hydrogen.test({ systems = { AskClient }, players = { "Alice" } }, function(t, alice)
				local result: { [number]: any, n: number }? = nil
				task.spawn(function()
					result = table.pack(pcall(Ask.Fire, Ask, alice, "hello?"))
				end)

				t:advance(9)
				check.equal(result, nil)
				t:advance(1)

				local packed = result :: { [number]: any, n: number }
				check.equal(packed[1], false)
				check.not_nil(string.find(tostring(packed[2]), "timed out after 10s waiting for Alice", 1, true))
				t:expect(Ask):called("hello?")
			end)
			return nil
		end)

		test.case("the fake clock refills rate limits", function()
			local Tap = Hydrogen.clientEvent("h-Tap", gt.number())

			Hydrogen.test({ players = 1 }, function(t)
				Tap:Use(Hydrogen.rateLimit({ perSecond = 1, burst = 2 }))
				for index = 1, 3 do
					Tap:Fire(index)
				end
				t:expect(Tap):firedTimes(2):fired(2)

				t:advance(1)
				Tap:Fire(4)
				t:expect(Tap):firedTimes(3):fired(4)
			end)
			return nil
		end)

		test.case("timers in systems run deterministically", function()
			local saves = 0
			local Autosave = Hydrogen.define("HarnessAutosave", function()
				return {
					start = function()
						task.spawn(function()
							while true do
								Hydrogen.Clock.wait(60)
								saves += 1
							end
						end)
					end,
				}
			end)

			Hydrogen.test({ systems = { Autosave } }, function(t)
				t:advance(59)
				check.equal(saves, 0)
				t:advance(5 * 60 - 59)
				check.equal(saves, 5)
			end)
			return nil
		end)

		test.case("teardown waits for player hooks that wait on the fake clock", function()
			local saved: { string } = {}
			local Profiles = Hydrogen.define("HarnessProfiles", function()
				return {
					playerRemoving = function(_, player: Player)
						-- Stands in for a DataStore save with a retry delay.
						Hydrogen.Clock.wait(2)
						table.insert(saved, player.Name)
					end,
				}
			end)

			Hydrogen.test({ systems = { Profiles }, players = { "Alice", "Bob" } }, function(t, alice)
				t:leave(alice)
				check.equal(#saved, 0)
				t:advance(2)
				check.equal(saved[1], "Alice")
			end)

			-- Bob was still in when the test ended; closing ran his save to the end.
			check.equal(saved[2], "Bob")
			return nil
		end)

		test.case("harness() for frameworks with setup and teardown hooks", function()
			local first = Hydrogen.harness({ players = { "Alice" } })
			check.equal(first:player("Alice").Name, "Alice")
			check.equal(#first:players(), 1)
			check.should_error(function()
				first:player("Nobody")
				return nil
			end)

			-- Forgetting close doesn't break the next test: the next harness closes it first.
			local second = Hydrogen.harness()
			check.equal(#second:players(), 0)
			second:close()
			second:close()

			check.equal(Runtime.Loopback, nil)
			check.equal(Hydrogen.Clock.active(), nil)
			return nil
		end)

		test.case("clock = false keeps real time", function()
			Hydrogen.test({ clock = false }, function(t)
				check.equal(t.clock, nil)
				check.equal(Hydrogen.Clock.now, os.clock)
				check.should_error(function()
					t:advance(1)
					return nil
				end)
			end)
			return nil
		end)

		return nil
	end)

	test.suite("Lune runtime", function()
		test.case("CFrame.lookAt faces its target, as in Roblox", function()
			local function near(a: Vector3, b: Vector3)
				check.is_true((a - b).Magnitude < 1e-5)
			end
			local from = Vector3.new(1, 1, 1)
			for _, direction in { Vector3.new(0, 0, -1), Vector3.new(0, 0, 1), Vector3.new(3, 4, 5).Unit, Vector3.new(0, -1, 0), Vector3.new(1, 0, 0) } do
				local cframe = CFrame.lookAt(from, from + direction * 10)
				near(cframe.LookVector, direction)
				near(cframe.Position, from)
			end
			check.equal(CFrame.new(1, 2, 3).Position, Vector3.new(1, 2, 3))
			return nil
		end)

		test.case("script requires and inferred ids work as in Studio", function()
			local Wallet = require("./Fixtures/Wallet") :: any
			check.equal(Wallet.id, "Wallet")
			-- require(script.Parent...) reached the same Hydrogen as require("../src").
			check.equal(Wallet.hydrogen, Hydrogen)
			return nil
		end)
		return nil
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
