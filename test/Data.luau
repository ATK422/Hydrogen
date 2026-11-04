--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Clock = require("../src/Data/Clock")

local Data = Hydrogen.Data

type Profile = { coins: number, items: { string } }

local TEMPLATE: Profile = { coins = 0, items = {} }

-- Polls until fn returns true, so tests don't depend on how many frames a step takes.
local function waitUntil(fn: () -> boolean, timeout: number?): boolean
	local began = os.clock()
	while not fn() do
		if os.clock() - began > (timeout or 2) then
			return false
		end
		task.wait()
	end
	return true
end

-- A server elsewhere holding the same keys: a second store over the same backend.
local function otherServer(name: string, backend: Hydrogen.DataBackend, options: { [string]: any }?): Hydrogen.KeyStore<Profile>
	local settings: any = { template = TEMPLATE, backend = backend }
	for key, value in options or {} do
		settings[key] = value
	end
	return Data.store(name, settings) :: any
end

return function()
	local apps: { Hydrogen.App } = {}
	local loopbacks: { Hydrogen.Loopback } = {}
	local realWait = Clock.wait
	local realNow = Clock.now
	local clockOffset = 0

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
		if suite.name ~= "Data" then
			return
		end
		-- Retry and lock-wait delays still count in full, but only take a frame.
		Clock.wait = function(_seconds: number)
			task.wait()
		end
		Clock.now = function()
			return realNow() + clockOffset
		end
	end)

	test.on_suite_leave(function(suite)
		if suite.name ~= "Data" then
			return
		end
		Clock.wait = realWait
		Clock.now = realNow
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
		clockOffset = 0
		Data.useBackend(nil)
	end)

	test.suite("Data", function()
		test.case("loads before dependents' playerAdded and saves on leave", function()
			local backend = Data.memory()
			local PlayerData = Data.player("PlayerData", { template = TEMPLATE, backend = backend })

			local seen: number? = nil
			local Shop = Hydrogen.define("DataShop", function(use)
				local Profiles = use(PlayerData)
				return {
					playerAdded = function(_, player: Player)
						seen = Profiles:get(player).coins
					end,
				}
			end)

			local net = openLoopback()
			local alice = net:join("Alice")
			local app = newApp()
			app:addSystems({ Shop, PlayerData })
			app:start()
			check.is_true(waitUntil(function()
				return seen ~= nil
			end))
			check.equal(seen, 0)

			check.is_true(PlayerData:update(alice, function(data)
				data.coins = 50
				table.insert(data.items, "sword")
				return nil
			end))
			check.equal(PlayerData:get(alice).coins, 50)
			check.equal(PlayerData:get(alice).items[1], "sword")
			-- Data is frozen: changing it by hand would skip validation and saving.
			check.should_error(function()
				(PlayerData:get(alice) :: any).coins = 1
				return nil
			end)

			net:leave(alice)
			check.is_true(waitUntil(function()
				return not PlayerData:isLoaded(alice)
			end))
			local record = backend:peek("PlayerData", tostring(alice.UserId))
			check.equal(record.data.coins, 50)
			check.equal(record.data.items[1], "sword")
			check.equal(record.lock, nil)
			return nil
		end)

		test.case("rejoining loads the saved data", function()
			local backend = Data.memory()
			-- Every fake player maps to one key, as a returning player's UserId would.
			local PlayerData = Data.player("PlayerData", {
				template = TEMPLATE,
				backend = backend,
				key = function()
					return "same"
				end,
			})
			local net = openLoopback()
			local app = newApp()
			app:addSystem(PlayerData)
			app:start()

			local alice = net:join("Alice")
			check.is_true(waitUntil(function()
				return PlayerData:isLoaded(alice)
			end))
			PlayerData:update(alice, function(data)
				data.coins += 7
				return nil
			end)
			net:leave(alice)
			check.is_true(waitUntil(function()
				return backend:peek("PlayerData", "same").lock == nil
			end))

			local again = net:join("Alice")
			check.is_true(waitUntil(function()
				return PlayerData:isLoaded(again)
			end))
			check.equal(PlayerData:get(again).coins, 7)
			return nil
		end)

		test.case("migrations run in order and missing fields come from the template", function()
			local backend = Data.memory()
			backend:write("Guilds", "red", { data = { gold = 5 }, version = 0, compatible = 0 })
			local Guilds = Data.store("Guilds", {
				template = { coins = 0, members = {} :: { string }, motto = "hi" },
				backend = backend,
				migrations = {
					function(old)
						return { coins = old.gold }
					end,
					{
						migrate = function(old)
							old.coins *= 2
							return old
						end,
					},
				},
			})

			check.is_true((Guilds:load("red")))
			local guild = Guilds:get("red")
			check.equal(guild.coins, 10)
			check.equal(guild.motto, "hi")
			check.equal(#guild.members, 0)
			check.equal(backend:peek("Guilds", "red").version, 2)

			-- A never-saved key starts as the template and runs no migrations.
			check.is_true((Guilds:load("blue")))
			check.equal(Guilds:get("blue").coins, 0)
			Guilds:unload("red")
			Guilds:unload("blue")
			return nil
		end)

		test.case("data saved by a newer server is refused unless backwards compatible", function()
			local backend = Data.memory()
			backend:write("Newer", "a", { data = { coins = 1, items = {} }, version = 3, compatible = 3 })
			backend:write("Newer", "b", { data = { coins = 2, items = {} }, version = 3, compatible = 1 })
			local store = otherServer("Newer", backend, { migrations = { function(old)
				return old
			end } })

			local ok, err = store:load("a")
			check.is_false(ok)
			check.not_nil(string.find(tostring(err), "newer server", 1, true))
			check.equal(backend:peek("Newer", "a").lock, nil)

			check.is_true((store:load("b")))
			store:unload("b")
			-- The newer server's version is kept.
			check.equal(backend:peek("Newer", "b").version, 3)
			return nil
		end)

		test.case("the schema is checked on the template, on load and on every update", function()
			local gt = Hydrogen.gt
			check.should_error(function()
				Data.store("BadTemplate", { template = { coins = "none" }, schema = gt.table({ coins = gt.number() }) :: any })
				return nil
			end)

			local backend = Data.memory()
			local store = Data.store("Checked", {
				template = { coins = 0 },
				schema = gt.table({ coins = gt.number({ range = "[0, inf]" }) }),
				backend = backend,
			})
			check.is_true((store:load("k")))
			check.should_error(function()
				store:update("k", function(data)
					data.coins = -5
					return nil
				end)
				return nil
			end)
			check.equal(store:get("k").coins, 0)

			-- Returning false aborts; errors abort too.
			check.is_false(store:update("k", function(data)
				data.coins = 5
				return false
			end))
			check.should_error(function()
				store:update("k", function(data)
					data.coins = 5
					error("nope")
				end)
				return nil
			end)
			check.equal(store:get("k").coins, 0)

			-- A yield would let another change interleave.
			check.should_error(function()
				store:update("k", function(data)
					task.wait()
					data.coins = 5
					return nil
				end)
				return nil
			end)
			check.equal(store:get("k").coins, 0)
			store:unload("k")

			backend:write("Checked", "broken", { data = { coins = "lots" }, version = 0, compatible = 0 })
			local ok, err = store:load("broken")
			check.is_false(ok)
			check.not_nil(string.find(tostring(err), "schema", 1, true))
			return nil
		end)

		test.case("a second server waits for the lock, then loads the saved data", function()
			local backend = Data.memory()
			local first = otherServer("Locked", backend)
			local second = otherServer("Locked", backend, { loadTimeout = 10000 })

			check.is_true((first:load("k")))
			first:update("k", function(data)
				data.coins = 3
				return nil
			end)

			local loaded: boolean? = nil
			task.spawn(function()
				loaded = (second:load("k"))
			end)
			for _ = 1, 5 do
				task.wait()
			end
			check.equal(loaded, nil)

			first:unload("k")
			check.is_true(waitUntil(function()
				return loaded ~= nil
			end))
			check.equal(loaded, true)
			check.equal(second:get("k").coins, 3)
			second:unload("k")
			return nil
		end)

		test.case("a load gives up after loadTimeout while the lock is held", function()
			local backend = Data.memory()
			local first = otherServer("Held", backend)
			local second = otherServer("Held", backend, { loadTimeout = 3 })
			check.is_true((first:load("k")))

			local ok, err = second:load("k")
			check.is_false(ok)
			check.not_nil(string.find(tostring(err), "another server", 1, true))
			check.equal(second:find("k"), nil)
			first:unload("k")
			return nil
		end)

		test.case("an abandoned lock is taken over and the old server stops saving", function()
			local backend = Data.memory()
			local crashed = otherServer("Stale", backend)
			local fresh = otherServer("Stale", backend)
			check.is_true((crashed:load("k")))
			crashed:update("k", function(data)
				data.coins = 1
				return nil
			end)
			check.is_true((crashed:save("k")))

			clockOffset = 601
			check.is_true((fresh:load("k")))
			check.equal(fresh:get("k").coins, 1)

			crashed:update("k", function(data)
				data.coins = 999
				return nil
			end)
			local ok, err = crashed:save("k")
			check.is_false(ok)
			check.not_nil(string.find(tostring(err), "lost", 1, true))
			check.is_false(crashed:isLoaded("k"))
			check.equal(backend:peek("Stale", "k").data.coins, 1)

			fresh:unload("k")
			crashed:unload("k")
			check.equal(backend:peek("Stale", "k").data.coins, 1)
			return nil
		end)

		test.case("failed requests are retried, and a save that keeps failing reports it", function()
			local backend = Data.memory()
			local store = otherServer("Flaky", backend, { retries = 3 })
			backend:fail(2)
			check.is_true((store:load("k")))

			store:update("k", function(data)
				data.coins = 4
				return nil
			end)
			backend:fail(3, "update")
			local ok, err = store:save("k")
			check.is_false(ok)
			check.not_nil(err)
			check.equal(backend:peek("Flaky", "k").data.coins, 0)

			-- Still dirty, so the next save stores it.
			check.is_true((store:save("k")))
			check.equal(backend:peek("Flaky", "k").data.coins, 4)
			store:unload("k")
			return nil
		end)

		test.case("a player who leaves while waiting for a lock gets nothing saved", function()
			local backend = Data.memory()
			local PlayerData = Data.player("PlayerData", { template = TEMPLATE, backend = backend, loadTimeout = 10000 })
			local elsewhere = otherServer("PlayerData", backend)

			local sawTemplate: boolean? = nil
			local Dependent = Hydrogen.define("DataDependent", function(use)
				local Profiles = use(PlayerData)
				return {
					playerAdded = function(_, player: Player)
						sawTemplate = Profiles:get(player).coins == 0 and not Profiles:isLoaded(player)
					end,
				}
			end)

			local net = openLoopback()
			local app = newApp()
			app:addSystems({ Dependent, PlayerData })
			app:start()

			check.is_true((elsewhere:load("-1")))
			elsewhere:update("-1", function(data)
				data.coins = 77
				return nil
			end)
			check.is_true((elsewhere:save("-1")))

			local alice = net:join("Alice")
			check.equal(alice.UserId, -1)
			task.wait()
			net:leave(alice)

			check.is_true(waitUntil(function()
				return sawTemplate ~= nil
			end))
			check.equal(sawTemplate, true)
			check.is_true(waitUntil(function()
				return PlayerData:find(alice) == nil
			end))
			-- The other server's lock and data are untouched.
			local record = backend:peek("PlayerData", "-1")
			check.equal(record.data.coins, 77)
			check.not_nil(record.lock)
			elsewhere:unload("-1")
			return nil
		end)

		test.case("a player whose data can't load is kicked", function()
			local backend = Data.memory()
			local failed: string? = nil
			local PlayerData = Data.player("PlayerData", {
				template = TEMPLATE,
				backend = backend,
				loadTimeout = 3,
				onLoadFailed = function(player, message)
					failed = message
					player:Kick("try again")
				end,
			})
			local elsewhere = otherServer("PlayerData", backend)
			check.is_true((elsewhere:load("-1")))

			local net = openLoopback()
			local app = newApp()
			app:addSystem(PlayerData)
			app:start()
			net:join("Alice")

			check.is_true(waitUntil(function()
				return failed ~= nil
			end))
			check.equal(#net:players(), 0)
			elsewhere:unload("-1")
			return nil
		end)

		test.case("stopping the app saves and releases every player and key", function()
			local backend = Data.memory()
			local PlayerData = Data.player("PlayerData", { template = TEMPLATE, backend = backend })
			local Guilds = otherServer("ShutdownGuilds", backend)

			local net = openLoopback()
			local alice = net:join("Alice")
			local bob = net:join("Bob")
			local app = newApp()
			app:addSystems({ PlayerData, Guilds })
			app:start()
			check.is_true(waitUntil(function()
				return PlayerData:isLoaded(alice) and PlayerData:isLoaded(bob)
			end))
			check.is_true((Guilds:load("red")))

			for _, player in { alice, bob } do
				PlayerData:update(player, function(data)
					data.coins = 10
					return nil
				end)
			end
			Guilds:update("red", function(data)
				data.coins = 3
				return nil
			end)

			app:stop()
			for _, player in { alice, bob } do
				local record = backend:peek("PlayerData", tostring(player.UserId))
				check.equal(record.data.coins, 10)
				check.equal(record.lock, nil)
			end
			check.equal(backend:peek("ShutdownGuilds", "red").data.coins, 3)
			check.equal(backend:peek("ShutdownGuilds", "red").lock, nil)

			-- No new loads once the server is shutting down.
			local ok = Guilds:load("blue")
			check.is_false(ok)
			return nil
		end)

		test.case("a transaction changes several keys all-or-nothing", function()
			local backend = Data.memory()
			local store = otherServer("Trades", backend)
			check.is_true((store:load("a")))
			check.is_true((store:load("b")))
			store:update("a", function(data)
				data.coins = 100
				table.insert(data.items, "sword")
				return nil
			end)

			-- Aborted: nothing changes.
			check.is_false(store:transaction({ "a", "b" }, function(all)
				all.a.coins -= 50
				return false
			end))
			check.equal(store:get("a").coins, 100)

			-- Invalid on one side: nothing changes.
			check.should_error(function()
				store:transaction({ "a", "b" }, function(all)
					all.a.coins = "x" :: any
					all.b.coins = 1
					return nil
				end)
				return nil
			end)
			check.equal(store:get("b").coins, 0)

			check.is_true(store:transaction({ "a", "b" }, function(all)
				all.a.coins -= 50
				all.b.coins += 50
				table.insert(all.b.items, table.remove(all.a.items) :: string)
				return nil
			end))
			check.equal(store:get("a").coins, 50)
			check.equal(store:get("b").coins, 50)
			check.equal(store:get("b").items[1], "sword")
			check.equal(#store:get("a").items, 0)

			-- Stored together right away, without waiting for autosave.
			check.is_true(waitUntil(function()
				return backend:peek("Trades", "a").data.coins == 50 and backend:peek("Trades", "b").data.coins == 50
			end))
			store:unload("a")
			store:unload("b")
			check.equal(backend:peek("Trades", "a").tx, nil)
			return nil
		end)

		test.case("a transaction interrupted by a crash loads consistently elsewhere", function()
			local memory = Data.memory()
			local failKey: string? = nil
			-- Fails writes to one key, as if the server died partway through the commit.
			local backend = setmetatable({
				update = function(_, store: string, key: string, transform: any)
					if key == failKey then
						error("server crashed", 0)
					end
					return memory:update(store, key, transform)
				end,
			}, { __index = memory }) :: any

			local crashed = otherServer("CrashTrades", backend, { retries = 1 })
			check.is_true((crashed:load("a")))
			check.is_true((crashed:load("b")))
			crashed:update("a", function(data)
				data.coins = 10
				return nil
			end)
			check.is_true((crashed:save("a")))

			-- "a" is written with the transaction, "b" fails, and the server never recovers.
			failKey = "b"
			crashed:transaction({ "a", "b" }, function(all)
				all.a.coins -= 10
				all.b.coins += 10
				return nil
			end)
			check.is_true(waitUntil(function()
				local record = memory:peek("CrashTrades", "a")
				return record.tx ~= nil
			end))
			task.wait()

			clockOffset = 601
			local fresh = otherServer("CrashTrades", memory)
			check.is_true((fresh:load("a")))
			check.is_true((fresh:load("b")))
			-- The marker was never removed, so neither side of the trade happened.
			check.equal(fresh:get("a").coins, 10)
			check.equal(fresh:get("b").coins, 0)
			fresh:unload("a")
			fresh:unload("b")
			return nil
		end)

		test.case("a transaction member losing its lock doesn't stop the others saving", function()
			local memory = Data.memory()
			local failKey: string? = nil
			local backend = setmetatable({
				update = function(_, store: string, key: string, transform: any)
					if key == failKey then
						error("unavailable", 0)
					end
					return memory:update(store, key, transform)
				end,
			}, { __index = memory }) :: any

			local server = otherServer("LostTrades", backend, { retries = 1 })
			check.is_true((server:load("a")))
			check.is_true((server:load("b")))
			failKey = "b"
			server:transaction({ "a", "b" }, function(all)
				all.a.coins = 1
				all.b.coins = 2
				return nil
			end)

			-- Another server takes "b" over while this one couldn't write it.
			failKey = nil
			clockOffset = 601
			local other = otherServer("LostTrades", memory)
			check.is_true((other:load("b")))

			check.is_false((server:save("a")))
			check.is_false(server:isLoaded("b"))
			check.is_true((server:save("a")))
			check.equal(memory:peek("LostTrades", "a").data.coins, 1)
			check.equal(memory:peek("LostTrades", "a").tx, nil)
			server:unload("a")
			other:unload("b")
			return nil
		end)

		test.case("a committed transaction survives a crash before the next save", function()
			local backend = Data.memory()
			local crashed = otherServer("CommittedTrades", backend)
			check.is_true((crashed:load("a")))
			check.is_true((crashed:load("b")))
			crashed:transaction({ "a", "b" }, function(all)
				all.a.coins = 5
				all.b.coins = 6
				return nil
			end)
			check.is_true(waitUntil(function()
				return backend:peek("CommittedTrades", "b").data.coins == 6
			end))
			check.not_nil(backend:peek("CommittedTrades", "a").tx)

			clockOffset = 601
			local fresh = otherServer("CommittedTrades", backend)
			check.is_true((fresh:load("a")))
			check.is_true((fresh:load("b")))
			check.equal(fresh:get("a").coins, 5)
			check.equal(fresh:get("b").coins, 6)
			fresh:unload("a")
			fresh:unload("b")
			return nil
		end)

		test.case("updateOnce applies once and only reports success once stored", function()
			local backend = Data.memory()
			local store = otherServer("Receipts", backend, { retries = 1 })
			check.is_true((store:load("k")))

			local runs = 0
			local function grant(data: Profile): boolean?
				runs += 1
				data.coins += 100
				return nil
			end

			check.equal(store:updateOnce("k", "purchase-1", grant), "applied")
			check.equal(backend:peek("Receipts", "k").data.coins, 100)
			check.equal(store:updateOnce("k", "purchase-1", grant), "duplicate")
			check.equal(runs, 1)

			-- The save fails: not reported as granted, but the grant isn't repeated either.
			backend:fail(1, "update")
			check.equal(store:updateOnce("k", "purchase-2", grant), "failed")
			check.equal(store:get("k").coins, 200)
			check.equal(store:updateOnce("k", "purchase-2", grant), "duplicate")
			check.equal(runs, 2)
			check.equal(backend:peek("Receipts", "k").data.coins, 200)

			check.equal(store:updateOnce("k", "purchase-3", function()
				return false
			end), "aborted")
			check.equal(store:updateOnce("missing", "purchase-4", grant), "failed")

			-- Ids are stored with the record, so another server knows them.
			store:unload("k")
			local other = otherServer("Receipts", backend)
			check.is_true((other:load("k")))
			check.equal(other:updateOnce("k", "purchase-1", grant), "duplicate")
			check.equal(runs, 2)
			other:unload("k")
			return nil
		end)

		test.case("updates nested in another update's callback join that change", function()
			local backend = Data.memory()
			local store = otherServer("Nested", backend)
			check.is_true((store:load("k")))
			check.is_true((store:load("other")))

			-- A game helper that uses the store's own API, called from a purchase grant.
			local function addCoins(key: string, amount: number)
				store:update(key, function(data)
					data.coins += amount
					return nil
				end)
			end

			check.equal(store:updateOnce("k", "purchase-1", function(data)
				table.insert(data.items, "crate")
				addCoins("k", 100)
				return nil
			end), "applied")
			check.equal(store:get("k").coins, 100)
			check.equal(store:get("k").items[1], "crate")
			check.equal(backend:peek("Nested", "k").data.coins, 100)

			-- The outer abort undoes the nested change too.
			check.is_false(store:update("k", function()
				addCoins("k", 5)
				return false
			end))
			check.equal(store:get("k").coins, 100)

			-- A nested update can't abort by itself, and these can't nest at all.
			check.should_error(function()
				store:update("k", function()
					store:update("k", function()
						return false
					end)
					return nil
				end)
				return nil
			end)
			check.should_error(function()
				store:update("k", function()
					store:updateOnce("k", "purchase-2", function() end)
					return nil
				end)
				return nil
			end)
			check.should_error(function()
				store:update("k", function()
					store:transaction({ "k", "other" }, function() end)
					return nil
				end)
				return nil
			end)
			check.equal(store:get("k").coins, 100)

			-- Other keys are unaffected by the pending copy.
			store:update("k", function()
				addCoins("other", 1)
				return nil
			end)
			check.equal(store:get("other").coins, 1)
			store:unload("k")
			store:unload("other")
			return nil
		end)

		test.case("waitForLoad waits for a player's load and reports failures", function()
			local backend = Data.memory()
			local PlayerData = Data.player("PlayerData", {
				template = TEMPLATE,
				backend = backend,
				loadTimeout = 10000,
				onLoadFailed = function() end,
			})
			local elsewhere = otherServer("PlayerData", backend)
			check.is_true((elsewhere:load("-2")))

			local net = openLoopback()
			local app = newApp()
			app:addSystem(PlayerData)
			app:start()
			local alice = net:join("Alice")
			local bob = net:join("Bob")
			check.is_true(PlayerData:waitForLoad(alice))

			-- Bob's data is held elsewhere; he is still loading.
			local result: boolean? = nil
			task.spawn(function()
				result = PlayerData:waitForLoad(bob)
			end)
			task.wait()
			check.equal(result, nil)
			elsewhere:unload("-2")
			check.is_true(waitUntil(function()
				return result ~= nil
			end))
			check.equal(result, true)

			net:leave(alice)
			check.is_true(waitUntil(function()
				return not PlayerData:isLoaded(alice)
			end))
			check.is_false(PlayerData:waitForLoad(alice))
			return nil
		end)

		test.case("unloading waits for a purchase that is still saving", function()
			local backend = Data.memory()
			local store = otherServer("SlowReceipts", backend)
			check.is_true((store:load("k")))

			backend.latency = 0.05
			local result: string? = nil
			task.spawn(function()
				result = store:updateOnce("k", "purchase-1", function(data)
					data.coins = 10
					return nil
				end)
			end)
			store:unload("k")
			check.equal(result, "applied")
			local record = backend:peek("SlowReceipts", "k")
			check.equal(record.data.coins, 10)
			check.equal(record.once[1], "purchase-1")
			check.equal(record.lock, nil)
			-- Too late once the lock is going: the purchase is retried on the next server.
			check.equal(store:updateOnce("k", "purchase-2", function() end), "failed")
			return nil
		end)

		test.case("requests wait for DataStore budget", function()
			local backend = Data.memory()
			local store = otherServer("Budget", backend)
			check.is_true((store:load("k")))
			store:update("k", function(data)
				data.coins = 1
				return nil
			end)

			backend:setBudget("update", 0)
			local saved: boolean? = nil
			task.spawn(function()
				saved = (store:save("k"))
			end)
			for _ = 1, 5 do
				task.wait()
			end
			check.equal(saved, nil)

			backend:setBudget("update", nil)
			check.is_true(waitUntil(function()
				return saved ~= nil
			end))
			check.equal(saved, true)
			store:unload("k")
			return nil
		end)

		test.case("changed data is autosaved", function()
			local backend = Data.memory()
			local store = otherServer("Autosaved", backend, { autosave = 0.05 })
			check.is_true((store:load("k")))
			store:update("k", function(data)
				data.coins = 9
				return nil
			end)
			check.is_true(waitUntil(function()
				return backend:peek("Autosaved", "k").data.coins == 9
			end))
			store:unload("k")
			return nil
		end)

		test.case("view reads without locking, and changed fires on every commit", function()
			local backend = Data.memory()
			local store = otherServer("Viewed", backend)
			check.equal(store:view("k"), nil)

			check.is_true((store:load("k")))
			local changes = {}
			local disconnect = store:changed(function(key, data, old)
				table.insert(changes, `{key}:{old.coins}->{data.coins}`)
			end)
			store:update("k", function(data)
				data.coins = 2
				return nil
			end)
			-- No change, no commit.
			store:update("k", function()
				return nil
			end)
			disconnect()
			store:update("k", function(data)
				data.coins = 3
				return nil
			end)
			check.equal(#changes, 1)
			check.equal(changes[1], "k:0->2")

			store:save("k")
			local viewed = store:view("k")
			check.equal((viewed :: Profile).coins, 3)
			check.not_nil(backend:peek("Viewed", "k").lock)
			store:unload("k")
			return nil
		end)

		test.case("useBackend sets the backend for stores without one", function()
			local backend = Data.memory()
			Data.useBackend(backend)
			local store = Data.store("Defaulted", { template = TEMPLATE })
			check.is_true((store:load("k")))
			store:unload("k")
			check.not_nil(backend:peek("Defaulted", "k"))
			return nil
		end)

		return nil
	end)
	return nil
end
