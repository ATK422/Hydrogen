--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Clock = require("../src/Receipts/Clock")
local Log = require("../src/Receipts/Log")
local Middleware = require("../src/Network/Middleware")
local Runtime = require("../src/Network/Runtime")

local Receipts = Hydrogen.Receipts

type Gate = {
	wait: () -> (),
	open: () -> (),
	waiting: () -> boolean,
}

-- A point a handler can stop at until the test opens it.
local function gate(): Gate
	local opened = false
	local parked: { thread } = {}
	return {
		wait = function()
			if opened then
				return
			end
			table.insert(parked, coroutine.running())
			coroutine.yield()
		end,
		open = function()
			opened = true
			local threads = table.clone(parked)
			table.clear(parked)
			for _, thread in threads do
				task.spawn(thread)
			end
		end,
		waiting = function()
			return #parked > 0
		end,
	}
end

local nextUserId = 0
local function fakePlayer(name: string): Player
	nextUserId += 1
	return { Name = name, UserId = 1000 + nextUserId, Parent = game } :: any
end

local nextProductId = 0
local function productId(): number
	nextProductId += 1
	return 5000 + nextProductId
end

return function()
	local apps: { Hydrogen.App } = {}
	local loopbacks: { Hydrogen.Loopback } = {}
	local cleanups: { () -> () } = {}
	local warnings: { string } = {}
	local originalWarn = Log.warn
	local originalWait = Clock.wait

	local function newApp(market: Hydrogen.FakeMarketplace, store: Hydrogen.ReceiptStore, systems: { any }?): Hydrogen.App
		-- A loopback per test, so the network starts fresh.
		if #loopbacks == 0 then
			table.insert(loopbacks, Hydrogen.loopback())
		end
		Receipts.configure({ marketplace = market, store = store, loadTimeout = 0.2 })
		local app = Hydrogen.App.new()
		app:addSystem(Receipts)
		for _, system in systems or {} do
			app:addSystem(system)
		end
		app:start()
		table.insert(apps, app)
		return app
	end

	local function register(remove: () -> ())
		table.insert(cleanups, remove)
	end

	local function warnedAbout(text: string): boolean
		for _, message in warnings do
			if string.find(message, text, 1, true) then
				return true
			end
		end
		return false
	end

	test.on_suite_enter(function(suite)
		if suite.name ~= "Receipts" then
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

	test.on_test_enter(function()
		table.clear(warnings)
		Log.warn = function(...)
			local parts = {}
			for _, value in { ... } do
				table.insert(parts, tostring(value))
			end
			table.insert(warnings, table.concat(parts, " "))
		end
		-- Retries happen at once instead of after real seconds.
		Clock.wait = function(_seconds: number?): number
			return 0
		end
	end)

	test.on_test_leave(function()
		for _, app in apps do
			app:stop()
		end
		for _, loopback in loopbacks do
			loopback:close()
		end
		for _, remove in cleanups do
			remove()
		end
		table.clear(apps)
		table.clear(loopbacks)
		table.clear(cleanups)
		Log.warn = originalWarn
		Clock.wait = originalWait
	end)

	test.suite("Receipts", function()
		test.case("grants a product once and records it", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local granted = 0
			local announced: { string } = {}

			register(Receipts.product(coins, function(_player, _receipt)
				granted += 1
			end))
			register(Receipts.onGranted(function(_player, receipt)
				table.insert(announced, receipt.PurchaseId)
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision, receipt = market:purchase(alice, coins)
			check.equal(decision, "PurchaseGranted")
			check.equal(granted, 1)
			check.equal(store:isSaved(receipt.PurchaseId), true)
			check.equal(announced[1], receipt.PurchaseId)
			check.equal(#market:pending(), 0)
			return nil
		end)

		test.case("a duplicate receipt is not granted twice, in this server or the next", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local granted = 0
			register(Receipts.product(coins, function()
				granted += 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local _, receipt = market:purchase(alice, coins)
			check.equal(market:deliver(receipt), "PurchaseGranted")
			check.equal(granted, 1)

			-- A new server, with the same durable store.
			app:stop()
			local nextApp = newApp(market, store)
			local again = fakePlayer("Alice again")
			;(again :: any).UserId = alice.UserId
			nextApp:_addPlayer(again)

			check.equal(market:deliver(receipt), "PurchaseGranted")
			check.equal(granted, 1)
			check.equal(store:savedCount(), 1)
			return nil
		end)

		test.case("the same receipt offered while the first call yields is granted once", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local hold = gate()
			local granted = 0
			register(Receipts.product(coins, function()
				hold.wait()
				granted += 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local receipt = {
				PurchaseId = "dup-1",
				PlayerId = alice.UserId,
				ProductId = coins,
				PlaceIdWherePurchased = 0,
				CurrencySpent = 10,
				CurrencyType = "Robux",
				ProductPurchaseChannel = "InExperience",
			}
			local first, second
			task.spawn(function()
				first = market:deliver(receipt)
			end)
			task.spawn(function()
				second = market:deliver(table.clone(receipt))
			end)
			check.equal(hold.waiting(), true)
			hold.open()

			check.equal(first, "PurchaseGranted")
			check.equal(second, "PurchaseGranted")
			check.equal(granted, 1)
			return nil
		end)

		test.case("a handler error leaves the purchase for later", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local broken = true
			local granted = 0
			register(Receipts.product(coins, function()
				if broken then
					error("inventory full")
				end
				granted += 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision, receipt = market:purchase(alice, coins)
			check.equal(decision, "NotProcessedYet")
			check.equal(store:isSaved(receipt.PurchaseId), false)
			check.equal(warnedAbout("inventory full"), true)

			broken = false
			check.equal(market:retryPending(alice)[1], "PurchaseGranted")
			check.equal(granted, 1)
			return nil
		end)

		test.case("a handler that returns false declines without recording", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local ready = false
			register(Receipts.product(coins, function()
				return ready
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision, receipt = market:purchase(alice, coins)
			check.equal(decision, "NotProcessedYet")
			check.equal(store:isSaved(receipt.PurchaseId), false)
			check.equal(#warnings, 0)

			ready = true
			check.equal(market:deliver(receipt), "PurchaseGranted")
			return nil
		end)

		test.case("an unknown product warns and waits for a handler", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local unknown = productId()

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			check.equal(market:purchase(alice, unknown), "NotProcessedYet")
			check.equal(warnedAbout(`no handler for developer product {unknown}`), true)

			-- Added in a later update: the pending receipt is granted.
			register(Receipts.product(unknown, function() end))
			check.equal(market:retryPending()[1], "PurchaseGranted")
			return nil
		end)

		test.case("a receipt waits for its player to load", function()
			local market = Receipts.fakeMarketplace()
			local memory = Receipts.memoryStore()
			local loading = gate()
			local store = setmetatable({
				load = function(_self: any, _player: Player): boolean
					loading.wait()
					return true
				end,
			}, { __index = memory }) :: any
			local coins = productId()
			register(Receipts.product(coins, function() end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")

			-- The receipt can arrive before the player is even added.
			local decision
			task.spawn(function()
				decision = market:purchase(alice, coins)
			end)
			check.equal(decision, nil)

			app:_addPlayer(alice)
			check.equal(decision, nil)

			loading.open()
			check.equal(decision, "PurchaseGranted")
			return nil
		end)

		test.case("a receipt for a player who never loads is left for later", function()
			local market = Receipts.fakeMarketplace()
			local coins = productId()
			register(Receipts.product(coins, function() end))

			newApp(market, Receipts.memoryStore())
			local began = os.clock()
			check.equal(market:purchase(fakePlayer("Ghost"), coins), "NotProcessedYet")
			-- loadTimeout is 0.2 in these tests.
			check.equal(os.clock() - began >= 0.15, true)
			return nil
		end)

		test.case("a player who leaves while loading or after loading isn't granted", function()
			local market = Receipts.fakeMarketplace()
			local memory = Receipts.memoryStore()
			local loading = gate()
			local store = setmetatable({
				load = function(_self: any, _player: Player): boolean
					loading.wait()
					return true
				end,
			}, { __index = memory }) :: any
			local coins = productId()
			local granted = 0
			register(Receipts.product(coins, function()
				granted += 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision
			task.spawn(function()
				decision = market:purchase(alice, coins)
			end)
			app:_removePlayer(alice)
			check.equal(decision, "NotProcessedYet")

			-- Arriving after they left.
			check.equal(market:purchase(alice, coins), "NotProcessedYet")
			check.equal(granted, 0)
			loading.open()
			return nil
		end)

		test.case("a player leaving mid-grant waits for the grant to be saved", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local hold = gate()
			local events: { string } = {}
			register(Receipts.product(coins, function()
				hold.wait()
				table.insert(events, "granted")
			end))

			-- Saves the player's data on leave; added first, so its playerRemoving runs after Receipts'.
			local SaveData = Hydrogen.define("SaveData", function()
				local SaveData = {}
				function SaveData:playerRemoving(_player: Player)
					table.insert(events, "saved data")
				end
				return SaveData
			end)

			table.insert(loopbacks, Hydrogen.loopback())
			Receipts.configure({ marketplace = market, store = store, loadTimeout = 0.2 })
			local app = Hydrogen.App.new()
			app:addSystem(SaveData)
			app:addSystem(Receipts)
			app:start()
			table.insert(apps, app)

			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision, receipt
			task.spawn(function()
				decision, receipt = market:purchase(alice, coins)
			end)
			local removed = false
			task.spawn(function()
				app:_removePlayer(alice)
				removed = true
			end)
			check.equal(removed, false)

			hold.open()
			-- Let the removal finish its wait.
			task.wait()
			check.equal(decision, "PurchaseGranted")
			check.equal(store:isSaved(receipt.PurchaseId), true)
			check.equal(removed, true)
			check.equal(events[1], "granted")
			check.equal(events[2], "saved data")
			return nil
		end)

		test.case("a failed save after the grant is retried, never granted twice", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local granted = 0
			register(Receipts.product(coins, function()
				granted += 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			-- One failure: the retry inside the same call saves it.
			store:failSaves(1)
			check.equal(market:purchase(alice, coins), "PurchaseGranted")
			check.equal(granted, 1)

			-- Every try fails: left for later, still recorded, so the retry only saves.
			store:failSaves(10)
			local decision, receipt = market:purchase(alice, coins)
			check.equal(decision, "NotProcessedYet")
			check.equal(granted, 2)
			check.equal(store:isSaved(receipt.PurchaseId), false)
			check.equal(warnedAbout("couldn't save purchase"), true)

			store:failSaves(0)
			check.equal(market:deliver(receipt), "PurchaseGranted")
			check.equal(granted, 2)
			check.equal(store:isSaved(receipt.PurchaseId), true)
			return nil
		end)

		test.case("a store that can't tell whether a purchase was granted doesn't grant", function()
			local market = Receipts.fakeMarketplace()
			local memory = Receipts.memoryStore()
			local store = setmetatable({
				isGranted = function(_self: any, _player: Player, _receipt: Hydrogen.Receipt): boolean
					error("DataStore unavailable")
				end,
			}, { __index = memory }) :: any
			local coins = productId()
			local granted = 0
			register(Receipts.product(coins, function()
				granted += 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			check.equal(market:purchase(alice, coins), "NotProcessedYet")
			check.equal(granted, 0)
			check.equal(warnedAbout("DataStore unavailable"), true)
			return nil
		end)

		test.case("a player whose record fails to load is left for another server", function()
			local market = Receipts.fakeMarketplace()
			local memory = Receipts.memoryStore()
			local store = setmetatable({
				load = function(_self: any, _player: Player): boolean
					return false
				end,
			}, { __index = memory }) :: any
			local coins = productId()
			register(Receipts.product(coins, function() end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)
			check.equal(market:purchase(alice, coins), "NotProcessedYet")
			return nil
		end)

		test.case("one receipt at a time per player", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local active = 0
			local overlapped = false
			local holds = { gate(), gate() }
			local calls = 0
			register(Receipts.product(coins, function()
				calls += 1
				active += 1
				if active > 1 then
					overlapped = true
				end
				holds[calls].wait()
				active -= 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decisions = {}
			for index = 1, 2 do
				task.spawn(function()
					decisions[index] = market:purchase(alice, coins)
				end)
			end
			check.equal(calls, 1)
			holds[1].open()
			check.equal(calls, 2)
			holds[2].open()

			check.equal(overlapped, false)
			check.equal(decisions[1], "PurchaseGranted")
			check.equal(decisions[2], "PurchaseGranted")
			return nil
		end)

		test.case("shutdown finishes grants in progress and refuses new receipts", function()
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local hold = gate()
			register(Receipts.product(coins, function()
				hold.wait()
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local inProgress
			task.spawn(function()
				inProgress = market:purchase(alice, coins)
			end)
			-- Waiting for a player who never joins.
			local waiting
			task.spawn(function()
				waiting = market:purchase(fakePlayer("Late"), coins)
			end)

			local stopped = false
			task.spawn(function()
				app:stop()
				stopped = true
			end)
			check.equal(stopped, false)

			hold.open()
			task.wait(0.05)
			check.equal(inProgress, "PurchaseGranted")
			check.equal(waiting, "NotProcessedYet")
			check.equal(stopped, true)

			-- ProcessReceipt stays bound, and answers NotProcessedYet after shutdown.
			check.equal(market:purchase(alice, coins), "NotProcessedYet")
			return nil
		end)

		test.case("game pass handlers run for owners on join and on purchase", function()
			local market = Receipts.fakeMarketplace()
			local VIP = 77
			local applied: { string } = {}
			register(Receipts.gamePass(VIP, function(player, passId)
				table.insert(applied, `{player.Name}:{passId}`)
			end))

			local app = newApp(market, Receipts.memoryStore())
			local alice = fakePlayer("Alice")
			local bob = fakePlayer("Bob")
			market:setOwnsGamePass(alice, VIP, true)
			app:_addPlayer(alice)
			app:_addPlayer(bob)

			check.equal(#applied, 1)
			check.equal(applied[1], "Alice:77")
			check.equal(market.ownershipChecks, 2)

			-- Cached for the session.
			check.equal(Receipts.owns(alice, VIP), true)
			check.equal(Receipts.owns(bob, VIP), false)
			check.equal(market.ownershipChecks, 2)

			market:buyGamePass(bob, VIP)
			check.equal(applied[2], "Bob:77")
			check.equal(Receipts.owns(bob, VIP), true)
			check.equal(market.ownershipChecks, 2)

			-- Bought again (a repeated event): the handler still runs once.
			market:buyGamePass(bob, VIP)
			check.equal(#applied, 2)
			return nil
		end)

		test.case("a failed ownership check returns false and asks again next time", function()
			local market = Receipts.fakeMarketplace()
			local PASS = 88
			local app = newApp(market, Receipts.memoryStore())
			local alice = fakePlayer("Alice")
			market:setOwnsGamePass(alice, PASS, true)
			app:_addPlayer(alice)

			market:failOwnershipChecks(3)
			check.equal(Receipts.owns(alice, PASS), false)
			check.equal(warnedAbout("couldn't check game pass 88"), true)
			check.equal(Receipts.owns(alice, PASS), true)

			-- One failure is retried within the call.
			local bob = fakePlayer("Bob")
			market:setOwnsGamePass(bob, PASS, true)
			app:_addPlayer(bob)
			market:failOwnershipChecks(1)
			check.equal(Receipts.owns(bob, PASS), true)
			return nil
		end)

		test.case("the DataStore store writes one key per purchase", function()
			local data: { [string]: any } = {}
			local userIdsSeen: { number } = {}
			local failWrites = 0
			local fakeDataStore = {
				GetAsync = function(_self: any, key: string): any
					return data[key]
				end,
				SetAsync = function(_self: any, key: string, value: any, userIds: { number }?): any
					if failWrites > 0 then
						failWrites -= 1
						error("write throttled")
					end
					data[key] = value
					if userIds then
						table.insert(userIdsSeen, userIds[1])
					end
					return nil
				end,
			}

			local market = Receipts.fakeMarketplace()
			local coins = productId()
			local granted = 0
			register(Receipts.product(coins, function()
				granted += 1
			end))

			local app = newApp(market, Receipts.dataStore(fakeDataStore))
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision, receipt = market:purchase(alice, coins)
			check.equal(decision, "PurchaseGranted")
			check.equal(data[receipt.PurchaseId].productId, coins)
			check.equal(userIdsSeen[1], alice.UserId)

			-- A write that fails twice succeeds on the third try.
			failWrites = 2
			check.equal(market:purchase(alice, coins), "PurchaseGranted")
			check.equal(granted, 2)

			-- A key written by another server counts as granted.
			data["from-another-server"] = { productId = coins }
			check.equal(market:purchase(alice, coins, { PurchaseId = "from-another-server" }), "PurchaseGranted")
			check.equal(granted, 2)

			-- Failing every try (3 writes for record, then 3 saves of 3 writes): not granted
			-- yet, saved when the player leaves.
			failWrites = 12
			local _, unsaved = market:purchase(alice, coins)
			check.equal(data[unsaved.PurchaseId], nil)
			app:_removePlayer(alice)
			check.not_nil(data[unsaved.PurchaseId])
			check.equal(granted, 3)
			return nil
		end)

		test.case("registration and configuration errors", function()
			local coins = productId()
			register(Receipts.product(coins, function() end))
			check.should_error(function()
				Receipts.product(coins, function() end)
				return nil
			end)
			check.should_error(function()
				Receipts.product("coins" :: any, function() end)
				return nil
			end)
			check.should_error(function()
				Receipts.configure({ store = {} :: any })
				return nil
			end)

			-- A table registers every product; one that is taken registers none of them.
			local a, b = productId(), productId()
			check.should_error(function()
				Receipts.products({
					[a] = function() end,
					[coins] = function() end,
				})
				return nil
			end)
			local removeAll = Receipts.products({
				[a] = function() end,
				[b] = function() end,
			})
			check.should_error(function()
				Receipts.product(b, function() end)
				return nil
			end)
			removeAll()
			register(Receipts.product(b, function() end))

			newApp(Receipts.fakeMarketplace(), Receipts.memoryStore())
			check.should_error(function()
				Receipts.configure({})
				return nil
			end)
			return nil
		end)

		test.case("a store built on an apply-once data update", function()
			-- Stands in for a data system with updateOnce(player, id, fn) -> "applied" |
			-- "duplicate" | "aborted" | "failed", which commits fn's change and the id together
			-- and returns once the save holding both is durable.
			local saveFailures = 0
			local profiles: { [number]: { data: { coins: number }, ids: { [string]: true }, dirty: boolean, durable: { coins: number }? } } =
				{}
			local function profile(player: Player)
				local found = profiles[player.UserId]
				if not found then
					found = { data = { coins = 0 }, ids = {}, dirty = false, durable = nil }
					profiles[player.UserId] = found
				end
				return found
			end
			local function saveProfile(player: Player): (boolean, string?)
				if saveFailures > 0 then
					saveFailures -= 1
					return false, "save failed"
				end
				local found = profile(player)
				found.durable = table.clone(found.data)
				found.dirty = false
				return true, nil
			end
			local function updateOnce(player: Player, id: string, fn: (data: { coins: number }) -> boolean?): string
				local found = profile(player)
				if found.ids[id] then
					if found.dirty and not saveProfile(player) then
						return "failed"
					end
					return "duplicate"
				end
				local copy = table.clone(found.data)
				local ok, result = pcall(fn, copy)
				if not ok then
					return "failed"
				elseif result == false then
					return "aborted"
				end
				found.data = copy
				found.ids[id] = true
				found.dirty = true
				return if saveProfile(player) then "applied" else "failed"
			end

			local store = {
				isGranted = function(_self: any, _player: Player, _receipt: Hydrogen.Receipt): boolean
					return false
				end,
				record = function(_self: any, player: Player, receipt: Hydrogen.Receipt, grant: (...any) -> ())
					local result = updateOnce(player, receipt.PurchaseId, function(data)
						grant(data)
						return nil
					end)
					if result == "failed" or result == "aborted" then
						error(`updateOnce {result}`)
					end
				end,
				save = function(_self: any, player: Player, _receipt: Hydrogen.Receipt)
					local ok, err = saveProfile(player)
					if not ok then
						error(err)
					end
				end,
			}

			local market = Receipts.fakeMarketplace()
			local coins = productId()
			local broken = false
			local announced = 0
			register(Receipts.product(coins, function(_player, _receipt, data)
				if broken then
					error("broken handler")
				end
				data.coins += 100
			end))
			register(Receipts.onGranted(function()
				announced += 1
			end))

			local app = newApp(market, store)
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision, receipt = market:purchase(alice, coins)
			check.equal(decision, "PurchaseGranted")
			check.equal(profiles[alice.UserId].durable and profiles[alice.UserId].durable.coins, 100)
			check.equal(announced, 1)

			-- The same receipt in the next server: updateOnce reports a duplicate, so no grant.
			app:stop()
			local nextApp = newApp(market, store)
			nextApp:_addPlayer(alice)
			check.equal(market:deliver(receipt), "PurchaseGranted")
			check.equal(profiles[alice.UserId].data.coins, 100)
			check.equal(announced, 1)

			-- The commit happened but its save failed: Receipts saves again, never grants twice.
			saveFailures = 1
			check.equal(market:purchase(alice, coins), "PurchaseGranted")
			check.equal(profiles[alice.UserId].durable and profiles[alice.UserId].durable.coins, 200)

			-- A handler error commits nothing.
			broken = true
			check.equal(market:purchase(alice, coins), "NotProcessedYet")
			check.equal(profiles[alice.UserId].data.coins, 200)
			check.equal(warnedAbout("broken handler"), true)
			return nil
		end)

		test.case("Receipts.fromData grants each purchase once through Hydrogen.Data", function()
			local backend = Hydrogen.Data.memory()
			local PlayerData = Hydrogen.Data.player("ReceiptsFromData", { template = { coins = 0 }, backend = backend })
			local market = Receipts.fakeMarketplace()
			local coins = productId()
			register(Receipts.product(coins, function(_player, _receipt, data)
				data.coins += 100
			end))

			local app = newApp(market, Receipts.fromData(PlayerData), { PlayerData })
			local alice = fakePlayer("Alice")
			app:_addPlayer(alice)

			local decision, receipt = market:purchase(alice, coins)
			check.equal(decision, "PurchaseGranted")
			check.equal(PlayerData:get(alice).coins, 100)

			-- Roblox delivers the same receipt again: recorded with the data, so no second grant.
			check.equal(market:deliver(receipt), "PurchaseGranted")
			check.equal(PlayerData:get(alice).coins, 100)
			check.equal(backend:peek("ReceiptsFromData", tostring(alice.UserId)).data.coins, 100)
			return nil
		end)

		test.case("prompts go to the marketplace", function()
			local market = Receipts.fakeMarketplace()
			newApp(market, Receipts.memoryStore())
			local alice = fakePlayer("Alice")
			Receipts.promptProduct(alice, 1)
			Receipts.promptGamePass(alice, 2)
			check.equal(market.prompts[1].kind, "product")
			check.equal(market.prompts[2].kind, "gamePass")
			check.equal(market.prompts[2].id, 2)
			return nil
		end)

		test.case("works with loopback players", function()
			local net = Hydrogen.loopback()
			table.insert(loopbacks, net)
			local market = Receipts.fakeMarketplace()
			local store = Receipts.memoryStore()
			local coins = productId()
			local balances: { [Player]: number } = {}

			local Shop = Hydrogen.define("Shop", function(use)
				local Purchases = use(Receipts)
				register(Purchases.product(coins, function(player)
					balances[player] = (balances[player] or 0) + 100
				end))
				return {}
			end)

			local alice = net:join("Alice")
			newApp(market, store, { Shop })

			check.equal(market:purchase(alice, coins), "PurchaseGranted")
			check.equal(balances[alice], 100)

			net:leave(alice)
			task.wait()
			check.equal(market:purchase(alice, coins), "NotProcessedYet")
			return nil
		end)
	end)
end
