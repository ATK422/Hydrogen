--!strict

-- Hydrogen.Config under Hydrogen.test: values and environments, flags and rollouts, what clients
-- may see, and live sources driven by the fake clock.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Middleware = require("../src/Network/Middleware")
local Runtime = require("../src/Network/Runtime")
local Rules = require("../src/Config/Rules")

local gt = Hydrogen.gt
local Config = Hydrogen.Config
local Clock = Hydrogen.Clock

local function isNil(value: any)
	check.equal(value, nil)
end

local function joined(list: { any }): string
	local parts = {}
	for _, item in list do
		table.insert(parts, tostring(item))
	end
	return table.concat(parts, ",")
end

local function errorOf(fn: () -> ()): string
	local ok, err = pcall(fn)
	check.is_false(ok)
	return tostring(err)
end

local function contains(text: string, part: string): boolean
	return string.find(text, part, 1, true) ~= nil
end

-- Every string anywhere in what a test saw delivered, to look for leaked secrets.
local function strings(value: any, into: { string })
	if type(value) == "string" then
		table.insert(into, value)
	elseif type(value) == "table" then
		for key, item in value do
			strings(key, into)
			strings(item, into)
		end
	end
end

local function fakeSnapshot()
	local listeners: { () -> () } = {}
	local snapshot = {
		Outdated = false,
		refreshes = 0,
		live = {} :: { [string]: any },
		values = {} :: { [string]: any },
		UpdateAvailable = {
			Connect = function(_: any, fn: () -> ())
				table.insert(listeners, fn)
				return {
					Disconnect = function()
						local index = table.find(listeners, fn)
						if index then
							table.remove(listeners, index)
						end
					end,
				}
			end,
		},
	}
	function snapshot.GetValue(self: any, name: string): any
		return self.values[name]
	end
	function snapshot.Refresh(self: any)
		self.refreshes += 1
		self.values = table.clone(self.live)
		self.Outdated = false
	end
	-- What publishing a new config version does: new values become available and listeners hear.
	function snapshot.publish(self: any, values: { [string]: any })
		self.live = values
		self.Outdated = true
		for _, listener in table.clone(listeners) do
			listener()
		end
	end
	function snapshot.listeners(_: any): number
		return #listeners
	end
	return snapshot
end

type Defs = {
	memory: Hydrogen.MemoryConfigSource,
	Game: any,
	Experience: any,
	snapshot: any,
	Stored: any,
	store: { value: any, gets: number },
	topic: { subscribed: string?, fire: (() -> ())? },
	Slow: any,
	slowSource: { release: (() -> ())?, values: { [string]: any } },
}

local defs: Defs = nil :: any

local function define()
	if defs then
		return
	end
	local memory = Config.memory()
	local snapshot = fakeSnapshot()
	local store = { value = nil :: any, gets = 0 }
	local topic = { subscribed = nil :: string?, fire = nil :: (() -> ())? }
	local slowSource = { release = nil :: (() -> ())?, values = {} :: { [string]: any } }

	defs = {
		memory = memory,
		snapshot = snapshot,
		store = store,
		topic = topic,
		slowSource = slowSource,
		Game = Config.define("Game", {
			values = {
				RoundLength = Config.value(gt.number(), 180),
				ApiKey = Config.value(gt.string(), "dev-key"),
				MaxPlayers = Config.shared(gt.number({ integer = true }), 12),
				Motd = Config.shared(gt.string(), "hello"),
				Rewards = Config.shared(gt.array(gt.number()), { 1, 2 }),
			},
			segments = {
				Staff = { groups = { 777 }, minRank = 200 },
				Testers = { users = { -2 } },
				Carols = function(player: Player): boolean
					return player.Name == "Carol"
				end,
			},
			flags = {
				NewShop = Config.flag({ percent = 50 }),
				Holiday = Config.flag(false),
				Beta = Config.flag({ segments = { "Testers", "Staff" } }),
				ForCarol = Config.flag({ segments = { "Carols" } }),
				Members = Config.flag({ groups = { 888 } }),
			},
			environments = {
				studio = { RoundLength = 20, Holiday = true },
				private = { RoundLength = 60 },
				reserved = { MaxPlayers = 4 },
				places = { [111] = { Motd = "place 111" } },
			},
			source = memory,
			refresh = 30,
		}),
		Experience = Config.define("Experience", {
			values = {
				BossHealth = Config.value(gt.number(), 100),
			},
			flags = {
				Raids = Config.flag(false),
			},
			source = Config.experienceConfigs({
				service = {
					GetConfigAsync = function(_: any)
						return snapshot
					end,
				},
			}),
		}),
		Stored = Config.define("Stored", {
			values = {
				Spawns = Config.value(gt.number(), 1),
			},
			source = Config.dataStore("Config", {
				store = {
					GetAsync = function(_: any, key: string): any
						store.gets += 1
						check.equal(key, "config")
						return store.value
					end,
				},
				topic = "ConfigChanged",
				messaging = {
					SubscribeAsync = function(_: any, name: string, callback: (any) -> ())
						topic.subscribed = name
						topic.fire = function()
							callback({ Data = "" })
						end
						return {
							Disconnect = function()
								topic.subscribed = nil
							end,
						}
					end,
				},
			}),
		}),
		Slow = Config.define("Slow", {
			values = {
				Speed = Config.value(gt.number(), 16),
			},
			source = {
				name = "slow",
				fetch = function(_: any, _names: { string }): { [string]: any }?
					Clock.wait(10)
					return slowSource.values
				end,
			},
		}),
	}
end

return function()
	test.on_suite_enter(function(suite)
		if suite.name ~= "Config" then
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

	-- Runs after every suite's tests; only this suite defines the configs.
	test.on_test_leave(function()
		if not defs then
			return
		end
		defs.memory:replace({})
		defs.memory:fail(nil)
		defs.snapshot.live = {}
		defs.snapshot.values = {}
		defs.store.value = nil
		defs.slowSource.values = {}
		Config.reset()
	end)

	test.suite("Config", function()
		test.case("values are plain table lookups with the declared defaults", function()
			local Game = defs.Game
			check.equal(Game.values.RoundLength, 180)
			check.equal(Game.values.MaxPlayers, 12)
			check.equal(Game.values.Rewards[2], 2)
			check.is_true(table.isfrozen(Game.values.Rewards))
			check.is_true(contains(errorOf(function()
				local _ = Game.values.RoundLenght
			end), "has no value named RoundLenght"))
			check.is_true(contains(errorOf(function()
				Game.values.Extra = 1
			end), "values are read-only"))
			check.is_true(contains(errorOf(function()
				local _ = Game.values.Holiday
			end), "Holiday is a flag"))
			check.is_true(contains(errorOf(function()
				local _ = Game.flags.Nope
			end), "has no flag named Nope"))
			return nil
		end)

		test.case("environments override values and flags, places on top of kinds", function()
			local Game = defs.Game
			local seen: { { any } } = {}
			Game:observe("RoundLength", function(value: number, previous: number?)
				table.insert(seen, { value, previous :: any })
			end)

			Config.useEnvironment({ kind = "studio" })
			check.equal(Config.environment().kind, "studio")
			check.equal(Game.values.RoundLength, 20)
			Config.useEnvironment({ kind = "private" })
			check.equal(Game.values.RoundLength, 60)
			Config.useEnvironment({ kind = "reserved" })
			check.equal(Game.values.RoundLength, 180)
			check.equal(Game.values.MaxPlayers, 4)
			Config.useEnvironment({ kind = "live", placeId = 111 })
			check.equal(Game.values.Motd, "place 111")
			check.equal(Game.values.MaxPlayers, 12)
			Config.useEnvironment(nil)
			check.equal(Game.values.Motd, "hello")

			check.equal(seen[1][1], 180)
			check.equal(seen[2][1], 20)
			check.equal(seen[3][1], 60)
			check.equal(seen[3][2], 20)
			check.equal(seen[4][1], 180)
			check.equal(#seen, 4)

			check.is_true(contains(errorOf(function()
				Config.useEnvironment({ kind = "staging" :: any })
			end), "kind must be"))
			return nil
		end)

		test.case("an environment turns a flag on for everyone", function()
			Config.useEnvironment({ kind = "studio" })
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice" } }, function(t, alice)
				check.is_true(defs.Game.flags.Holiday:enabled(alice))
			end)
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice" } }, function(t, alice)
				-- The harness put the real environment back when the last test closed.
				check.is_false(defs.Game.flags.Holiday:enabled(alice))
			end)
			return nil
		end)

		test.case("misconfiguration fails loudly when it is declared", function()
			check.is_true(contains(errorOf(function()
				Config.value(gt.number(), "ten" :: any)
			end), "the default doesn't match the schema"))
			check.is_true(contains(errorOf(function()
				Config.value(nil :: any, 1)
			end), "expects a GreenTea schema"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad1", { values = { A = Config.value(gt.number(), 1) }, environments = { live = { B = 2 } } })
			end), "environments.live sets B, which isn't a declared value or flag"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad2", { values = { A = Config.value(gt.number(), 1) }, environments = { live = { A = "x" } } })
			end), "environments.live sets A, which doesn't match the schema"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad3", { environments = { staging = {} } :: any })
			end), "unknown environment staging"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad4", { flags = { F1 = Config.flag({ segments = { "Nobody" } }) } })
			end), "segment Nobody isn't declared"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad5", { flags = { F2 = Config.flag({ percent = 150 }) } })
			end), "percent must be a number from 0 to 100"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad6", { values = { X = 1 :: any } })
			end), "values.X must be Config.value"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad7", { values = { Same = Config.value(gt.number(), 1) }, flags = { Same = Config.flag(true) } })
			end), "is both a value and a flag"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad8", { flags = { NewShop = Config.flag(true) } })
			end), "flag names are global"))
			check.is_true(contains(errorOf(function()
				Config.define("Game", {})
			end), "Config Game is already defined"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad9", { refresh = 0 })
			end), "refresh must be a positive number"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad10", { valuez = {} } :: any)
			end), "unknown field valuez"))
			check.is_true(contains(errorOf(function()
				Config.define("Bad11", { segments = { S = { minRank = 5 } :: any } })
			end), "minRank needs groups"))
			-- None of the failed definitions registered anything.
			isNil(Config.findFlag("F1"))
			return nil
		end)

		test.case("percentage rollouts are deterministic and grow without reshuffling", function()
			local inAt10, inAt50 = 0, 0
			for userId = 1, 10000 do
				local bucket = Rules.bucket("NewShop", userId)
				check.equal(bucket, Rules.bucket("NewShop", userId))
				if bucket < 1000 then
					inAt10 += 1
					-- Everyone in at 10% is still in at 50%.
					check.is_true(bucket < 5000)
				end
				if bucket < 5000 then
					inAt50 += 1
				end
			end
			check.is_true(inAt10 > 900 and inAt10 < 1100)
			check.is_true(inAt50 > 4800 and inAt50 < 5200)
			-- Salted by the flag's name, so experiments don't all pick the same players.
			local differs = false
			for userId = 1, 100 do
				if (Rules.bucket("A", userId) < 5000) ~= (Rules.bucket("B", userId) < 5000) then
					differs = true
				end
			end
			check.is_true(differs)

			Hydrogen.test({ systems = { defs.Game }, players = 6 }, function(t, ...)
				for _, player in { ... } do
					local expected = Rules.bucket("NewShop", player.UserId) < 5000
					check.equal(defs.Game.flags.NewShop:enabled(player), expected)
					Config.reevaluate(player)
					check.equal(defs.Game.flags.NewShop:enabled(player), expected)
				end
			end)
			return nil
		end)

		test.case("segments match users, group ranks and custom checks", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice", "Bob", "Carol" }, start = false }, function(t, alice, bob, carol)
				-- Alice is staff: her rank lookup takes a second.
				(alice :: any).GetRankInGroup = function(_: any, groupId: number): number
					Clock.wait(1)
					return if groupId == 777 then 250 else 0
				end
				t:start()
				local Beta = defs.Game.flags.Beta
				check.is_false(Beta:enabled(alice))
				check.is_true(Beta:enabled(bob)) -- Testers: UserId -2
				check.is_true(defs.Game.flags.ForCarol:enabled(carol))
				check.is_false(defs.Game.flags.ForCarol:enabled(alice))

				local seen = {}
				Beta:observe(alice, function(enabled: boolean)
					table.insert(seen, enabled)
				end)
				t:advance(1)
				check.is_true(Beta:enabled(alice))
				check.equal(joined(seen), "false,true")
				-- Rank 250 in 777 isn't membership of 888.
				check.is_false(defs.Game.flags.Members:enabled(alice))
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("a player leaving during a group lookup is dropped quietly", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice" }, start = false }, function(t, alice)
				(alice :: any).GetRankInGroup = function(_: any, _groupId: number): number
					Clock.wait(3)
					return 255
				end
				t:start()
				t:leave(alice)
				t:advance(10)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("server-only values never reach clients", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice" } }, function(t, alice)
				defs.Game:override({ ApiKey = "secret-123", Motd = "welcome" })
				t:advance(0)

				local replica = t:as(alice, function()
					return defs.Game:replica()
				end)
				check.equal(replica.MaxPlayers, 12)
				check.equal(replica.Motd, "welcome")
				check.equal(replica.Rewards[1], 1)
				isNil(replica.ApiKey)
				isNil(replica.RoundLength)

				local everything = {}
				for _, delivery in t:deliveries() do
					strings(delivery.args, everything)
				end
				check.is_true(table.find(everything, "welcome") ~= nil)
				for _, text in everything do
					check.is_false(contains(text, "secret-123"))
					check.is_false(contains(text, "dev-key"))
					check.is_false(text == "ApiKey" or text == "RoundLength")
				end
			end)
			return nil
		end)

		test.case("clients see their own flags and hear when they change", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				local Beta = defs.Game.flags.Beta
				t:advance(0)
				check.is_false(t:as(alice, Beta.enabled, Beta, alice))
				check.is_true(t:as(bob, Beta.enabled, Beta, bob))
				-- A client only hears about its own flags.
				check.is_false(t:as(alice, Beta.enabled, Beta, bob))

				local seen = {}
				t:as(alice, function()
					Beta:observe(alice, function(enabled: boolean)
						table.insert(seen, enabled)
					end)
				end)
				defs.Game:override({ Beta = true })
				check.is_true(Beta:enabled(alice))
				t:advance(0)
				check.is_true(t:as(alice, Beta.enabled, Beta, alice))
				check.equal(joined(seen), "false,true")

				defs.Game:clearOverrides({ "Beta" })
				t:advance(0)
				check.is_false(t:as(alice, Beta.enabled, Beta, alice))
				-- By name, for libraries that gate on a flag the game declared.
				check.equal(Config.getFlag("Beta"), Beta)
				isNil(Config.findFlag("Nope"))
				check.is_true(contains(errorOf(function()
					Config.getFlag("Nope")
				end), "No feature flag named Nope"))
			end)
			return nil
		end)

		test.case("overrides are checked like declarations", function()
			local Game = defs.Game
			check.is_true(contains(errorOf(function()
				Game:override({ RoundLength = "long" })
			end), "override sets RoundLength, which doesn't match the schema"))
			check.is_true(contains(errorOf(function()
				Game:override({ Unknown = 1 })
			end), "isn't a declared value or flag"))
			check.is_true(contains(errorOf(function()
				Game:override({ Beta = { percent = -1 } })
			end), "percent must be"))
			Game:override({ RoundLength = 5 })
			check.equal(Game.values.RoundLength, 5)
			Game:clearOverrides()
			check.equal(Game.values.RoundLength, 180)
			return nil
		end)

		test.case("a live source update arrives on the next scheduled refresh", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice" } }, function(t, alice)
				local Game = defs.Game
				local seen = {}
				Game:observe("RoundLength", function(value: number)
					table.insert(seen, value)
				end)

				defs.memory:set("RoundLength", 90)
				defs.memory:set("MaxPlayers", 20)
				t:advance(29)
				check.equal(Game.values.RoundLength, 180)
				t:advance(1)
				check.equal(Game.values.RoundLength, 90)
				check.equal(Game.values.MaxPlayers, 20)
				check.equal(joined(seen), "180,90")

				t:advance(0)
				check.equal(t:as(alice, Game.replica, Game).MaxPlayers, 20)

				-- Removing it remotely falls back to the value from code.
				defs.memory:set("RoundLength", nil)
				t:advance(30)
				check.equal(Game.values.RoundLength, 180)

				-- A push applies at once, without waiting for the schedule.
				defs.memory:set("RoundLength", 45)
				defs.memory:push()
				check.equal(Game.values.RoundLength, 45)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("invalid live values are rejected and the last good ones kept", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice" } }, function(t, alice)
				local Game = defs.Game
				defs.memory:set("MaxPlayers", 20)
				t:advance(30)
				check.equal(Game.values.MaxPlayers, 20)

				defs.memory:set("MaxPlayers", "lots")
				defs.memory:set("Beta", { percent = 500 })
				defs.memory:set("Typo", true)
				t:advance(30)
				check.equal(Game.values.MaxPlayers, 20)
				t:expectWarning("rejected MaxPlayers from live source memory")
				t:expectWarning("keeping the last good value")
				t:expectWarning("rejected Beta from live source memory: it percent must be")
				t:expectWarning("sent Typo, which isn't a declared value or flag")

				-- The same bad values again don't warn again.
				local count = #t:warnings()
				t:advance(30)
				check.equal(#t:warnings(), count)

				-- A failing source keeps everything.
				defs.memory:fail("service unavailable")
				t:advance(30)
				check.equal(Game.values.MaxPlayers, 20)
				t:expectWarning("live source memory failed: service unavailable")
				defs.memory:fail(nil)
				defs.memory:replace({ MaxPlayers = 30 })
				t:advance(30)
				check.equal(Game.values.MaxPlayers, 30)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("live flag rules re-evaluate every player; functions can't come from a source", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				local Holiday = defs.Game.flags.Holiday
				local seen = {}
				Holiday:observe(alice, function(enabled: boolean)
					table.insert(seen, enabled)
				end)
				defs.memory:set("Holiday", { users = { alice.UserId } })
				t:advance(30)
				check.is_true(Holiday:enabled(alice))
				check.is_false(Holiday:enabled(bob))
				check.equal(joined(seen), "false,true")
				t:advance(0)
				check.is_true(t:as(alice, Holiday.enabled, Holiday, alice))

				defs.memory:set("Holiday", { when = function()
					return true
				end })
				t:advance(30)
				t:expectWarning("when can't come from a live source")
				check.is_true(Holiday:enabled(alice))
				check.is_false(Holiday:enabled(bob))
			end)
			return nil
		end)

		test.case("custom checks that error or yield count as false, with a warning", function()
			Hydrogen.test({ systems = { defs.Game }, players = { "Alice" } }, function(t, alice)
				local Holiday = defs.Game.flags.Holiday
				defs.Game:override({ Holiday = { when = function(_: Player): boolean
					error("no data")
				end } })
				check.is_false(Holiday:enabled(alice))
				t:expectWarning("flag Holiday's when failed for Alice")
				defs.Game:override({ Holiday = { when = function(_: Player): boolean
					Clock.wait(1)
					return true
				end } })
				check.is_false(Holiday:enabled(alice))
				t:expectWarning("flag Holiday's when yielded for Alice")

				local open = false
				defs.Game:override({ Holiday = { when = function(_: Player): boolean
					return open
				end } })
				open = true
				check.is_false(Holiday:enabled(alice))
				Config.reevaluate(alice)
				check.is_true(Holiday:enabled(alice))
			end)
			return nil
		end)

		test.case("observers that error don't stop the others", function()
			local Game = defs.Game
			local seen = 0
			Hydrogen.test(function(t)
				Game:observe("RoundLength", function()
					error("observer exploded")
				end)
				Game:observe("RoundLength", function()
					seen += 1
				end)
				Game:override({ RoundLength = 1 })
				check.equal(seen, 2)
				t:expectWarning("Observer of Config Game.RoundLength failed")
			end)
			return nil
		end)

		test.case("Experience Configs: pushed updates apply through Refresh", function()
			defs.snapshot.values = { BossHealth = 500 }
			Hydrogen.test({ systems = { defs.Experience }, players = { "Alice" } }, function(t, alice)
				local Experience = defs.Experience
				check.equal(Experience.values.BossHealth, 500)
				check.equal(defs.snapshot:listeners(), 1)

				defs.snapshot:publish({ BossHealth = 750, Raids = true })
				check.equal(defs.snapshot.refreshes, 1)
				check.equal(Experience.values.BossHealth, 750)
				check.is_true(Experience.flags.Raids:enabled(alice))

				defs.snapshot:publish({ BossHealth = "lots" })
				check.equal(Experience.values.BossHealth, 750)
				t:expectWarning("rejected BossHealth from live source ExperienceConfigs")
			end)
			-- Stopping the app disconnected it.
			check.equal(defs.snapshot:listeners(), 0)
			check.equal(defs.Experience.values.BossHealth, 100)
			return nil
		end)

		test.case("DataStore source: polled on schedule, fetched at once on a topic message", function()
			defs.store.value = { Spawns = 3 }
			Hydrogen.test({ systems = { defs.Stored } }, function(t)
				local Stored = defs.Stored
				check.equal(Stored.values.Spawns, 3)
				check.equal(defs.topic.subscribed, "ConfigChanged")
				defs.store.value = { Spawns = 4 }
				t:advance(59)
				check.equal(Stored.values.Spawns, 3)
				t:advance(1)
				check.equal(Stored.values.Spawns, 4)

				defs.store.value = { Spawns = 5 };
				(defs.topic.fire :: () -> ())()
				check.equal(Stored.values.Spawns, 5)

				defs.store.value = "oops"
				t:advance(60)
				check.equal(Stored.values.Spawns, 5)
				t:expectWarning("holds a string, not a table of values")
			end)
			isNil(defs.topic.subscribed)
			return nil
		end)

		test.case("a slow source doesn't hold the boot past its timeout; late values still apply", function()
			defs.slowSource.values = { Speed = 32 }
			local t = Hydrogen.harness({ systems = { defs.Slow }, start = false })
			local booted = false
			task.spawn(function()
				t:start()
				booted = true
			end)
			check.is_false(booted)
			t:advance(5)
			check.is_true(booted)
			check.equal(defs.Slow.values.Speed, 16)
			t:advance(5)
			check.equal(defs.Slow.values.Speed, 32)
			t:close()
			return nil
		end)

		test.case("stopping the app stops refreshing", function()
			local t = Hydrogen.harness({ systems = { defs.Game } })
			local before = defs.memory:fetches()
			t:advance(30)
			check.equal(defs.memory:fetches(), before + 1)
			t:close()
			check.is_false((defs.Game :: any).running)
			isNil((defs.Game :: any).timer)
			return nil
		end)

		test.case("reading flags from a config left out of the app warns", function()
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				check.is_false(defs.Game.flags.Beta:enabled(alice))
				defs.Game.flags.Beta:enabled(alice)
				t:expectWarning("Config Game isn't in the app")
				check.equal(#t:warnings(), 1)
			end)
			return nil
		end)

		test.case("a config is a system other systems can use", function()
			local order = {}
			local Shop = Hydrogen.define("ConfigShop", function(use)
				local Game = use(defs.Game)
				return {
					playerAdded = function(_: any, player: Player)
						table.insert(order, `{player.Name}:{Game.flags.Beta:enabled(player)}:{Game.values.RoundLength}`)
					end,
				}
			end)
			Hydrogen.test({ systems = { Shop, defs.Game }, players = { "Alice", "Bob" } }, function()
				check.equal(table.concat(order, " "), "Alice:false:180 Bob:true:180")
			end)
			return nil
		end)
	end)
end
