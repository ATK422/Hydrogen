--!strict

-- Hydrogen.State end to end through Hydrogen.loopback: the server writes, each fake client reads
-- its own replica inside loopback:as.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Middleware = require("../src/Network/Middleware")
local Runtime = require("../src/Network/Runtime")

local gt = Hydrogen.gt
local State = Hydrogen.State

type Money = { cents: number }

local MoneyClass = {}
MoneyClass.__index = MoneyClass

local function money(cents: number): Money
	return setmetatable({ cents = cents }, MoneyClass) :: any
end

-- Defined when the suite starts: the Network suite clears every registered name before then.
local defs: {
	Round: Hydrogen.StateValue<string>,
	Timer: Hydrogen.StateValue<number>,
	Coins: Hydrogen.PlayerValue<number>,
	Level: Hydrogen.PlayerValue<number>,
	Scores: Hydrogen.StateMap<string, number>,
	Inventory: Hydrogen.PlayerMap<string, number>,
	Feed: Hydrogen.StateList<string>,
	Quests: Hydrogen.PlayerList<string>,
	Packed: Hydrogen.StateMap<string, number>,
	Wallet: Hydrogen.StateValue<Money>,
	Team: Hydrogen.PlayerValue<string?>,
} = nil :: any

local function define()
	if defs then
		return
	end
	defs = {
		Round = State.value("Round", gt.string(), "Lobby"),
		Timer = State.value("Timer", gt.number(), 0),
		Coins = State.playerValue("Coins", gt.number(), 0),
		Level = State.playerValue("Level", gt.number(), 1, { visibleTo = "everyone" }),
		Scores = State.map("Scores", gt.string(), gt.number()),
		Inventory = State.playerMap("Inventory", gt.string(), gt.number()),
		Feed = State.list("Feed", gt.string()),
		Quests = State.playerList("Quests", gt.string(), { visibleTo = "everyone" }),
		Team = State.playerValue("Team", gt.optional(gt.string()), nil, { visibleTo = "everyone" }),
		Packed = State.map("Packed", gt.string(), gt.number({ integer = true, range = "[0, 255]" }), { encode = true }),
		Wallet = State.value("Wallet", gt.any(), money(0), {
			serializer = {
				schema = gt.number(),
				serialize = function(value: Money)
					return value.cents
				end,
				deserialize = function(cents: number)
					return money(cents)
				end,
			},
		}),
	}
end

-- Counts what a state sends, and records what each client receives.
local function watch(state: any)
	local record = { sent = 0, received = {} :: { [Player]: { { any } } } }
	state.event:Use(function(context: Hydrogen.MiddlewareContext, ...: any)
		if context.direction == "outgoing" then
			record.sent += 1
		else
			local loopback = Runtime.Loopback :: any
			local client = loopback and loopback:client()
			if client then
				record.received[client] = record.received[client] or {}
				table.insert(record.received[client], table.pack(...))
			end
		end
		return ...
	end)
	return record
end

return function()
	local apps: { Hydrogen.App } = {}
	local loopbacks: { Hydrogen.Loopback } = {}

	local function newApp(): Hydrogen.App
		local app = Hydrogen.App.new()
		table.insert(apps, app)
		return app
	end

	-- A started loopback with the given clients joined.
	local function start(...: string): (Hydrogen.Loopback, { Player })
		local loopback = Hydrogen.loopback()
		table.insert(loopbacks, loopback)
		local players = {}
		for _, name in { ... } do
			table.insert(players, loopback:join(name))
		end
		newApp():start()
		return loopback, players
	end

	test.on_suite_enter(function(suite)
		if suite.name ~= "State" then
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
		define()
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
		State.reset()
	end)

	test.suite("State", function()
		test.case("a global value replicates and observers see it now and on change", function()
			local net, players = start("Alice")
			local alice = players[1]
			local Round = defs.Round

			local seen = {}
			net:as(alice, function()
				Round:observe(function(value, previous)
					table.insert(seen, { value, previous })
				end)
			end)
			check.equal(seen[1][1], "Lobby")
			check.equal(seen[1][2], nil)

			Round:set("Playing")
			-- The server reads its own value at once; the client gets it at the end of the frame.
			check.equal(Round:get(), "Playing")
			check.equal(net:as(alice, Round.get, Round), "Lobby")

			State.flush()
			check.equal(net:as(alice, Round.get, Round), "Playing")
			check.equal(seen[2][1], "Playing")
			check.equal(seen[2][2], "Lobby")
			return nil
		end)

		test.case("many writes in one frame go out as one message", function()
			local net, players = start("Alice", "Bob")
			local Timer = defs.Timer
			local record = watch(Timer)

			for second = 1, 100 do
				Timer:set(second)
			end
			Timer:update(function(current)
				return current + 1
			end)
			check.equal(record.sent, 0)

			-- No explicit flush: the end of the frame sends it.
			task.wait()
			check.equal(record.sent, 1)
			check.equal(#record.received[players[1]], 1)
			check.equal(net:as(players[1], Timer.get, Timer), 101)
			check.equal(net:as(players[2], Timer.get, Timer), 101)

			-- Writing the same value again sends nothing.
			Timer:set(101)
			State.flush()
			check.equal(record.sent, 1)
			return nil
		end)

		test.case("a late joiner gets a snapshot of everything written so far", function()
			local net, players = start("Alice")
			local alice = players[1]
			local Round, Scores, Feed, Level = defs.Round, defs.Scores, defs.Feed, defs.Level

			Round:set("Playing")
			Scores:set("red", 3)
			Scores:set("blue", 5)
			Feed:push("Alice joined")
			Feed:push("Round started")
			Level:set(alice, 7)
			State.flush()

			local bob = net:join("Bob")
			net:as(bob, function()
				check.equal(Round:get(), "Playing")
				check.equal(Scores:get("red"), 3)
				check.equal(Scores:get("blue"), 5)
				check.equal(Scores:size(), 2)
				check.equal(Feed:size(), 2)
				check.equal(Feed:get(2), "Round started")
				check.equal(Level:get(alice), 7)
			end)

			-- Later changes reach the new client as diffs on top of its snapshot.
			Feed:insert(1, "Server up")
			State.flush()
			check.equal(net:as(bob, Feed.get, Feed, 1), "Server up")
			check.equal(net:as(bob, Feed.size, Feed), 3)
			return nil
		end)

		test.case("state written before the network starts is there when client systems start", function()
			local net = Hydrogen.loopback()
			table.insert(loopbacks, net)
			local alice = net:join("Alice")
			defs.Round:set("Intermission")
			defs.Coins:set(alice, 25)
			State.flush()

			local atStart: { any } = {}
			local Client = Hydrogen.define("StateClientProbe", function()
				return {
					start = function()
						net:as(alice, function()
							atStart.round = defs.Round:get()
							atStart.coins = defs.Coins:get(alice)
						end)
					end,
				}
			end)

			local app = newApp()
			app:addSystem(Client)
			app:start()
			-- Delivered by the ready handshake, before any system's start.
			check.equal(atStart.round, "Intermission")
			check.equal(atStart.coins, 25)
			return nil
		end)

		test.case("per-player state reaches only the owner unless visible to everyone", function()
			local net, players = start("Alice", "Bob")
			local alice, bob = players[1], players[2]
			local Coins, Level = defs.Coins, defs.Level
			local coinsRecord = watch(Coins)

			Coins:set(alice, 50)
			Coins:set(bob, 10)
			Level:set(alice, 4)
			State.flush()

			-- One message per player cell, each to its owner.
			check.equal(coinsRecord.sent, 2)
			check.equal(#coinsRecord.received[alice], 1)
			check.equal(#coinsRecord.received[bob], 1)

			net:as(alice, function()
				check.equal(Coins:get(alice), 50)
				check.equal(Coins:get(bob), 0)
				check.equal(Level:get(alice), 4)
			end)
			net:as(bob, function()
				check.equal(Coins:get(bob), 10)
				check.equal(Coins:get(alice), 0)
				check.equal(Level:get(alice), 4)
			end)
			check.equal(Coins:get(alice), 50)

			local carol = net:join("Carol")
			net:as(carol, function()
				check.equal(Coins:get(alice), 0)
				check.equal(Level:get(alice), 4)
			end)
			return nil
		end)

		test.case("a player leaving is dropped from other clients but stays readable on the server", function()
			local net, players = start("Alice", "Bob")
			local alice, bob = players[1], players[2]
			local Level, Inventory = defs.Level, defs.Inventory
			local levelRecord = watch(Level)

			Level:set(alice, 9)
			Inventory:set(alice, "sword", 1)
			State.flush()
			check.equal(net:as(bob, Level.get, Level, alice), 9)

			-- A change still pending when the player leaves is not sent afterwards.
			Level:set(alice, 10)
			local sent = levelRecord.sent
			net:leave(alice)
			State.flush()
			check.equal(levelRecord.sent, sent)
			check.equal(net:as(bob, Level.get, Level, alice), 1)

			-- Later playerRemoving hooks (a save) still read the last values.
			check.equal(Level:get(alice), 10)
			check.equal(Inventory:get(alice, "sword"), 1)

			-- Writes after leaving apply on the server and are not sent.
			Level:set(alice, 11)
			State.flush()
			check.equal(levelRecord.sent, sent)
			check.equal(Level:get(alice), 11)

			-- A player who joins later doesn't get the departed player's state.
			local carol = net:join("Carol")
			check.equal(net:as(carol, Level.get, Level, alice), 1)
			check.equal(net:as(carol, Level.get, Level, bob), 1)
			return nil
		end)

		test.case("map changes are sent as key diffs", function()
			local net, players = start("Alice")
			local alice = players[1]
			local Scores = defs.Scores
			local record = watch(Scores)

			Scores:replace({ red = 1, blue = 2, green = 3 })
			State.flush()

			Scores:set("red", 10)
			Scores:remove("green")
			Scores:set("blue", 2) -- unchanged
			State.flush()

			local diff = record.received[alice][2]
			-- (reset, keys, values, removed)
			check.equal(diff[1], false)
			check.equal(#diff[2], 1)
			check.equal(diff[2][1], "red")
			check.equal(diff[3][1], 10)
			check.equal(#diff[4], 1)
			check.equal(diff[4][1], "green")

			-- replace sends only what differs.
			Scores:replace({ red = 10, blue = 20, yellow = 4 })
			State.flush()
			local replaced = record.received[alice][3]
			check.equal(replaced[1], false)
			check.equal(#replaced[2], 2)
			check.equal(#replaced[4], 0)

			net:as(alice, function()
				check.equal(Scores:get("blue"), 20)
				check.equal(Scores:get("yellow"), 4)
				check.equal(Scores:get("green"), nil)
				check.equal(Scores:size(), 3)
			end)

			-- clear is one small reset message.
			Scores:clear()
			State.flush()
			local cleared = record.received[alice][4]
			check.equal(cleared[1], true)
			check.equal(#cleared[2], 0)
			check.equal(net:as(alice, Scores.size, Scores), 0)
			return nil
		end)

		test.case("map observers on the client see keys change", function()
			local net, players = start("Alice")
			local alice = players[1]
			local Inventory = defs.Inventory

			local swords: { any } = {}
			local changes: { { any } } = {}
			local snapshots: { { [string]: number } } = {}
			net:as(alice, function()
				Inventory:observeKey(alice, "sword", function(count)
					table.insert(swords, count or "none")
				end)
				Inventory:onChange(alice, function(key, value, previous)
					table.insert(changes, { key, value, previous })
				end)
				Inventory:observe(alice, function(entries)
					table.insert(snapshots, entries)
				end)
			end)
			check.equal(swords[1], "none")
			check.equal(#snapshots, 1)

			Inventory:set(alice, "sword", 1)
			Inventory:set(alice, "shield", 1)
			Inventory:update(alice, "sword", function(count)
				return (count or 0) + 1
			end)
			State.flush()

			check.equal(swords[2], 2)
			check.equal(#swords, 2)
			check.equal(#changes, 2)
			check.equal(#snapshots, 2)
			check.equal(snapshots[2].shield, 1)

			Inventory:remove(alice, "sword")
			State.flush()
			check.equal(swords[3], "none")
			check.equal(changes[3][1], "sword")
			check.equal(changes[3][2], nil)
			check.equal(changes[3][3], 2)
			return nil
		end)

		test.case("list changes are sent as operations, or as the whole list when shorter", function()
			local net, players = start("Alice", "Bob")
			local alice, bob = players[1], players[2]
			local Feed, Quests = defs.Feed, defs.Quests
			local record = watch(Feed)

			Feed:replace({ "a", "b", "c", "d", "e", "f", "g", "h", "i", "j" })
			State.flush()

			Feed:push("k")
			Feed:insert(1, "start")
			check.equal(Feed:remove(3), "b")
			Feed:set(2, "A")
			State.flush()

			local diff = record.received[alice][2]
			-- (reset, ops, values): four (op, index) pairs and three values.
			check.equal(diff[1], false)
			check.equal(#diff[2], 8)
			check.equal(#diff[3], 3)

			local expected = Feed:all()
			net:as(alice, function()
				local items = Feed:all()
				check.equal(#items, #expected)
				for index, item in expected do
					check.equal(items[index], item)
				end
			end)

			-- More changes than items: the whole list is smaller.
			Feed:replace({ "x" })
			State.flush()
			for _ = 1, 20 do
				Feed:push("y")
				Feed:remove(1)
			end
			State.flush()
			local burst = record.received[alice][#record.received[alice]]
			check.equal(burst[1], true)
			check.equal(net:as(alice, Feed.size, Feed), 1)
			check.equal(net:as(alice, Feed.get, Feed, 1), "y")

			-- Per-player lists, visible to everyone.
			Quests:push(alice, "Find the key")
			Quests:push(alice, "Open the door")
			State.flush()
			check.equal(net:as(bob, Quests.get, Quests, alice, 2), "Open the door")
			check.equal(net:as(bob, Quests.size, Quests, bob), 0)
			return nil
		end)

		test.case("a player subscribing mid-frame doesn't get list operations twice", function()
			local net, players = start("Alice")
			local Feed = defs.Feed
			Feed:push("one")
			-- Not flushed yet: Bob's snapshot already contains "one".
			local bob = net:join("Bob")
			Feed:push("two")
			State.flush()

			check.equal(net:as(bob, Feed.size, Feed), 2)
			check.equal(net:as(players[1], Feed.size, Feed), 2)
			return nil
		end)

		test.case("an optional value can be set back to nil", function()
			local net, players = start("Alice", "Bob")
			local alice, bob = players[1], players[2]
			local Team = defs.Team

			Team:set(alice, "Red")
			State.flush()
			check.equal(net:as(bob, Team.get, Team, alice), "Red")

			Team:set(alice, nil)
			State.flush()
			check.equal(net:as(bob, Team.get, Team, alice), nil)
			check.equal(Team:get(alice), nil)
			return nil
		end)

		test.case("observeAll sees every player's value, existing ones first", function()
			local net, players = start("Alice", "Bob")
			local alice, bob = players[1], players[2]
			local Level, Coins = defs.Level, defs.Coins

			Level:set(alice, 3)
			Coins:set(alice, 40)
			Coins:set(bob, 7)
			State.flush()

			local server: { { any } } = {}
			Level:observeAll(function(player, value, previous)
				table.insert(server, { player, value, previous })
			end)
			check.equal(#server, 1)
			check.equal(server[1][1], alice)
			check.equal(server[1][2], 3)

			local onBob: { { any } } = {}
			local bobCoins: { { any } } = {}
			net:as(bob, function()
				Level:observeAll(function(player, value, previous)
					table.insert(onBob, { player, value, previous })
				end)
				Coins:observeAll(function(player, value)
					table.insert(bobCoins, { player, value })
				end)
			end)
			check.equal(#onBob, 1)
			check.equal(onBob[1][1], alice)
			-- Owner-only state: Bob's client only ever has his own.
			check.equal(#bobCoins, 1)
			check.equal(bobCoins[1][1], bob)
			check.equal(bobCoins[1][2], 7)

			Level:set(bob, 5)
			Level:set(alice, 4)
			check.equal(#server, 3)
			check.equal(#onBob, 1)
			State.flush()
			check.equal(#onBob, 3)
			check.equal(onBob[2][1], bob)
			check.equal(onBob[2][2], 5)
			check.equal(onBob[3][1], alice)
			check.equal(onBob[3][2], 4)
			check.equal(onBob[3][3], 3)

			Coins:set(alice, 41)
			State.flush()
			check.equal(#bobCoins, 1)
			return nil
		end)

		test.case("computed state follows the copy it is read from", function()
			local net, players = start("Alice")
			local alice = players[1]
			local Round, Timer = defs.Round, defs.Timer

			local label = State.computed(function()
				return `{Round:get()} {Timer:get()}`
			end)
			local doubled = State.computed(function()
				return label:get() .. "!"
			end)

			local server: { string } = {}
			local client: { string } = {}
			doubled:observe(function(value)
				table.insert(server, value)
			end)
			net:as(alice, function()
				doubled:observe(function(value)
					table.insert(client, value)
				end)
			end)
			check.equal(server[1], "Lobby 0!")
			check.equal(client[1], "Lobby 0!")

			Round:set("Playing")
			Timer:set(30)
			-- The server's computed state changes at once, the client's when its replica does.
			check.equal(server[#server], "Playing 30!")
			check.equal(#client, 1)
			check.equal(label:get(), "Playing 30")

			State.flush()
			check.equal(client[#client], "Playing 30!")
			check.equal(net:as(alice, label.get, label), "Playing 30")
			return nil
		end)

		test.case("a failing or yielding observer doesn't stop the others", function()
			start("Alice")
			local Round = defs.Round
			local after = {}
			local resumed = false

			Round:observe(function(value)
				if value == "Broken" then
					error("observer exploded")
				end
			end)
			Round:observe(function(value)
				if value == "Broken" then
					task.wait()
					resumed = true
				end
			end)
			Round:observe(function(value)
				table.insert(after, value)
			end)

			Round:set("Broken")
			check.equal(after[2], "Broken")
			check.equal(Round:get(), "Broken")
			check.equal(resumed, false)
			task.wait()
			task.wait()
			check.equal(resumed, true)
			return nil
		end)

		test.case("serializers and encoding round-trip through the wire", function()
			local net, players = start("Alice")
			local alice = players[1]
			local Wallet, Packed = defs.Wallet, defs.Packed

			Wallet:set(money(1250))
			Packed:set("hp", 200)
			Packed:set("mp", 40)
			State.flush()

			net:as(alice, function()
				local wallet = Wallet:get()
				check.equal(wallet.cents, 1250)
				check.equal(getmetatable(wallet :: any), MoneyClass)
				check.equal(Packed:get("hp"), 200)
				check.equal(Packed:get("mp"), 40)
			end)
			return nil
		end)

		test.case("bad writes error at the caller", function()
			start("Alice")
			local Round, Coins, Feed, Scores = defs.Round, defs.Coins, defs.Feed, defs.Scores

			check.should_error(function()
				Round:set(5 :: any)
				return nil
			end)
			check.should_error(function()
				Coins:set(10 :: any, nil :: any)
				return nil
			end)
			check.should_error(function()
				Feed:insert(5, "too far")
				return nil
			end)
			check.should_error(function()
				Feed:remove(1)
				return nil
			end)
			check.should_error(function()
				Scores:set(1 :: any, 2)
				return nil
			end)
			check.should_error(function()
				Round:update(function()
					return nil :: any
				end)
				return nil
			end)
			check.equal(Round:get(), "Lobby")

			local ok, err = pcall(function()
				Round:set(5 :: any)
			end)
			check.equal(ok, false)
			-- Raised at the caller's line in this file, not inside Hydrogen.
			check.not_nil(string.find(tostring(err), "test.State:%d"))
			check.not_nil(string.find(tostring(err), "%[HYDROGEN%] State Round"))
			return nil
		end)

		test.case("definitions are checked", function()
			check.should_error(function()
				State.value("Round", gt.string(), "again")
				return nil
			end)
			check.should_error(function()
				State.value("BadInitial", gt.string(), 5 :: any)
				return nil
			end)
			check.should_error(function()
				State.value("Visible", gt.string(), "", { visibleTo = "everyone" } :: any)
				return nil
			end)

			start("Alice")
			check.should_error(function()
				State.value("TooLate", gt.string(), "")
				return nil
			end)
			return nil
		end)

		test.case("without a network, state is a plain store", function()
			local Round, Coins = defs.Round, defs.Coins
			local fake = { Name = "Offline", UserId = 1 } :: any
			local seen = {}
			Round:observe(function(value)
				table.insert(seen, value)
			end)
			Round:set("Solo")
			Coins:set(fake, 3)
			State.flush()
			check.equal(Round:get(), "Solo")
			check.equal(Coins:get(fake), 3)
			check.equal(seen[2], "Solo")
			return nil
		end)

		test.case("reset puts every state back to its initial value", function()
			local net, players = start("Alice")
			defs.Round:set("Playing")
			defs.Scores:set("red", 1)
			State.flush()
			State.reset()
			check.equal(defs.Round:get(), "Lobby")
			check.equal(defs.Scores:size(), 0)
			check.equal(net:as(players[1], defs.Round.get, defs.Round), "Lobby")
			return nil
		end)

		test.case("a test that ends before its frame flushed doesn't stop later tests replicating", function()
			-- The write schedules a flush on the harness's fake clock, which is restored before it runs.
			Hydrogen.test({ players = 1 }, function()
				defs.Round:set("Playing")
			end)
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				defs.Round:set("Results")
				t:advance(0)
				check.equal(t:as(alice, defs.Round.get, defs.Round), "Results")
			end)
			return nil
		end)

		return nil
	end)
	return nil
end
