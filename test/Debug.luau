--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Log = require("../src/Log")
local Middleware = require("../src/Network/Middleware")
local Runtime = require("../src/Network/Runtime")

local Debug = Hydrogen.Debug
local gt = Hydrogen.gt

local function near(actual: number, expected: number)
	check.is_true(math.abs(actual - expected) < 1e-6)
end

return function()
	test.on_test_leave(function()
		Debug._reset()
		Debug._resetSettings()
	end)

	test.suite("Debug stats", function()
		test.case("nothing is installed until stats are enabled, and disable removes it all", function()
			local Ping = Hydrogen.clientEvent("dbg-Off", gt.number())

			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local global = #Middleware.global
				local observer = Runtime.Observer

				t:as(alice, function()
					Ping:Fire(1)
				end)
				check.equal(Debug.statsEnabled(), false)
				check.equal(next(Debug.stats()), nil)
				check.equal(#Middleware.global, global)
				check.equal(Runtime.Observer, observer)

				Debug.enableStats()
				check.equal(#Middleware.global, global + 1)
				check.is_true(Runtime.Observer ~= observer)

				Debug.disableStats()
				check.equal(#Middleware.global, global)
				check.equal(Runtime.Observer, observer)

				-- Nothing counted while off.
				t:as(alice, function()
					Ping:Fire(2)
				end)
				check.equal(next(Debug.stats()), nil)
			end)
			return nil
		end)

		test.case("counts messages in and out per object, with per-second rates", function()
			local Ping = Hydrogen.clientEvent("dbg-Ping", gt.number())
			local News = Hydrogen.serverEvent("dbg-News", gt.string())

			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice)
				Debug.enableStats()
				t:as(alice, function()
					for index = 1, 3 do
						Ping:Fire(index)
					end
				end)
				News:FireAll("hi")

				local stats = Debug.stats()
				local ping = stats["dbg-Ping"]
				-- One VM is the client and the server, so both directions show.
				check.equal(ping.kind, "ClientEvent")
				check.equal(ping.outTotal, 3)
				check.equal(ping.inTotal, 3)
				check.equal(ping.dropped, 0)
				-- Rates cover the last full second.
				check.equal(ping.outPerSecond, 0)

				-- A server event counts once per player it is sent to.
				check.equal(stats["dbg-News"].outTotal, 2)
				check.equal(stats["dbg-News"].inTotal, 2)

				t:advance(1)
				ping = Debug.stats()["dbg-Ping"]
				check.equal(ping.outPerSecond, 3)
				check.equal(ping.inPerSecond, 3)
				check.equal(ping.outBytesPerSecond, 3 * 18)

				-- A quiet second later the rate is back to zero; totals stay.
				t:advance(1)
				ping = Debug.stats()["dbg-Ping"]
				check.equal(ping.outPerSecond, 0)
				check.equal(ping.outTotal, 3)

				Debug.resetStats()
				check.equal(next(Debug.stats()), nil)
			end)
			return nil
		end)

		test.case("estimates payload bytes cheaply", function()
			-- 9 for Hydrogen's id, then 9 per number, length + 4 per string, 2 per boolean or nil,
			-- 4 per table plus its keys and values.
			check.equal(Debug.estimateBytes(), 9)
			check.equal(Debug.estimateBytes(1), 18)
			check.equal(Debug.estimateBytes("abc"), 16)
			check.equal(Debug.estimateBytes(true, nil), 13)
			check.equal(Debug.estimateBytes({ 1, 2 }), 9 + 4 + 2 * 18)
			check.equal(Debug.estimateBytes({ coins = 5 }), 9 + 4 + 9 + 9)
			check.equal(Debug.estimateBytes(Vector3.new(1, 2, 3)), 9 + 13)

			-- Past 256 values, each value counts as a number, so huge payloads stay cheap to estimate.
			local big = table.create(10000, 1)
			check.equal(Debug.estimateBytes(big), 9 + 4 + 10000 * 18)
			local strings = table.create(1000, "abcdefgh")
			check.is_true(Debug.estimateBytes(strings) < 9 + 4 + 1000 * (9 + 12))

			local Note = Hydrogen.clientEvent("dbg-Note", gt.string())
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				Debug.enableStats()
				t:as(alice, function()
					Note:Fire("hello")
				end)
				local note = Debug.stats()["dbg-Note"]
				check.equal(note.outBytes, 9 + 9)
				check.equal(note.inBytes, 9 + 9)
			end)
			return nil
		end)

		test.case("counts rate-limited and invalid messages as dropped", function()
			local Tap = Hydrogen.clientEvent("dbg-Tap", gt.number())
			Tap:Use(Hydrogen.rateLimit({ perSecond = 1, burst = 2 }))

			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local received = 0
				Tap:On(function()
					received += 1
				end)

				Debug.enableStats()
				t:as(alice, function()
					-- A payload the schema rejects, as an exploiter's client could send it.
					Runtime:fireServerEvent("dbg-Tap", "not a number")
					for index = 1, 5 do
						Tap:Fire(index)
					end
				end)
				t:expectWarning("Dropped invalid dbg-Tap")

				-- The invalid one used a token too: one valid message got through.
				check.equal(received, 1)
				local tap = Debug.stats()["dbg-Tap"]
				check.equal(tap.inTotal, 6)
				check.equal(tap.dropped, 5)
			end)
			return nil
		end)

		test.case("sees drops by global middleware added after stats started", function()
			local Spam = Hydrogen.clientEvent("dbg-Spam", gt.number())

			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				Debug.enableStats()
				-- Added after stats, so it would run first on incoming messages; stats move behind it.
				Hydrogen.useMiddleware(Hydrogen.rateLimit({ perSecond = 1, burst = 1 }))

				t:as(alice, function()
					for index = 1, 4 do
						Spam:Fire(index)
					end
				end)

				local spam = Debug.stats()["dbg-Spam"]
				check.equal(spam.inTotal, 4)
				check.equal(spam.dropped, 3)
			end)
			return nil
		end)

		test.case("times function round trips and handlers", function()
			local Price = Hydrogen.clientFunction("dbg-Price", gt.args(gt.string()), gt.returns(gt.number()))

			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				Price:On(function(_player, _item)
					Hydrogen.Clock.wait(0.25)
					return 10
				end)
				Debug.enableStats()

				local price: number? = nil
				task.spawn(function()
					price = t:as(alice, function()
						return Price:Fire("sword")
					end)
				end)
				check.equal(price, nil)
				t:advance(0.25)
				check.equal(price, 10)

				local stat = Debug.stats()["dbg-Price"]
				local latency = stat.latency :: Hydrogen.NetLatency
				local handler = stat.handler :: Hydrogen.NetLatency
				check.equal(latency.count, 1)
				near(latency.average, 0.25)
				near(latency.max, 0.25)
				check.equal(handler.count, 1)
				near(handler.last, 0.25)
				-- Request and response, each seen leaving and arriving.
				check.equal(stat.outTotal, 2)
				check.equal(stat.inTotal, 2)
				check.equal(stat.dropped, 0)
			end)
			return nil
		end)

		test.case("a closed test harness turns stats off and gives its observer back", function()
			Hydrogen.test(function()
				Debug.enableStats()
			end)
			check.equal(Debug.statsEnabled(), false)
			check.equal(Runtime.Observer, nil)
			return nil
		end)
	end)

	test.suite("Debug overlay data", function()
		test.case("only authorized players get server data", function()
			Hydrogen.test({ systems = { Debug }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				Debug.configure({ users = { alice.UserId } })

				local view = t:as(alice, Debug.fetch)
				check.not_nil(view)
				check.equal(#view.players, 2)
				check.equal(t:as(bob, Debug.fetch), nil)
				check.equal(Debug.isAuthorized(alice), true)
				check.equal(Debug.isAuthorized(bob), false)

				-- authorize replaces the default check, users list included.
				Debug.configure({
					authorize = function(player: Player): boolean
						return player.Name == "Bob"
					end,
				})
				check.equal(t:as(alice, Debug.fetch), nil)
				check.not_nil(t:as(bob, Debug.fetch))
			end)
			return nil
		end)

		test.case("an authorize that errors denies and warns", function()
			Hydrogen.test({ systems = { Debug }, players = { "Alice" } }, function(t, alice)
				Debug.configure({
					authorize = function(_player: Player): boolean
						error("roles not loaded")
					end,
				})
				check.equal(t:as(alice, Debug.fetch), nil)
				t:expectWarning("Debug authorize failed for Alice, so they were denied")
			end)
			return nil
		end)

		test.case("an unauthorized request doesn't turn stats on; an authorized one leases them", function()
			Hydrogen.test({ systems = { Debug }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				Debug.configure({ users = { alice.UserId } })

				t:as(bob, Debug.fetch)
				check.equal(Debug.statsEnabled(), false)

				t:as(alice, Debug.fetch)
				check.equal(Debug.statsEnabled(), true)
				-- The second request already shows the first one's traffic.
				local view = t:as(alice, Debug.fetch) :: Hydrogen.DebugView
				check.not_nil(view.stats["Hydrogen/Debug"])

				-- Ten quiet seconds after the last request, stats stop by themselves.
				t:advance(9)
				check.equal(Debug.statsEnabled(), true)
				t:advance(2)
				check.equal(Debug.statsEnabled(), false)

				-- enableStats outlasts any lease.
				Debug.enableStats()
				t:as(alice, Debug.fetch)
				t:advance(30)
				check.equal(Debug.statsEnabled(), true)
			end)
			return nil
		end)

		test.case("the view shows state, inspected data and warnings, read-only", function()
			local Round = Hydrogen.State.value("dbg-Round", gt.string(), "Lobby")
			local Coins = Hydrogen.State.playerValue("dbg-Coins", gt.number(), 0)
			local PlayerData = Hydrogen.Data.player("dbg-Data", {
				template = { gems = 3, items = { "sword" } },
				backend = Hydrogen.Data.memory(),
			})

			Hydrogen.test({ systems = { Debug, PlayerData }, players = { "Alice" } }, function(t, alice)
				Debug.configure({ users = { alice.UserId }, inspect = { PlayerData } })
				Round:set("Playing")
				Coins:set(alice, 25)

				local view = t:as(alice, Debug.fetch, alice.UserId) :: Hydrogen.DebugView
				local function row(rows: { Hydrogen.DebugRow }, name: string): string?
					for _, entry in rows do
						if entry.name == name then
							return entry.value
						end
					end
					return nil
				end

				check.equal(row(view.state, "dbg-Round"), '"Playing"')
				local player = view.player :: Hydrogen.DebugPlayerView
				check.equal(player.name, "Alice")
				check.equal(row(player.state, "dbg-Coins"), "25")
				check.equal(player.data[1].name, "dbg-Data")
				check.equal(row(player.data[1].fields, "gems"), "3")
				check.equal(row(player.data[1].fields, "items"), '{"sword"}')

				-- Unknown players get no player view.
				view = t:as(alice, Debug.fetch, 123456789) :: Hydrogen.DebugView
				check.equal(view.player, nil)

				-- Warnings reach the overlay and still reach the test.
				Log.warn("[HYDROGEN] something odd")
				t:expectWarning("something odd")
				view = t:as(alice, Debug.fetch) :: Hydrogen.DebugView
				check.equal(view.warnings[#view.warnings].text, "[HYDROGEN] something odd")
				check.equal(Debug.warnings()[#Debug.warnings()].text, "[HYDROGEN] something odd")
			end)
			return nil
		end)

		test.case("boot timings come from App's debug output", function()
			Hydrogen.test({
				systems = { Debug },
				app = { debug = true, output = Debug.bootOutput },
			}, function()
				local report = Debug.boot() :: Hydrogen.BootReport
				check.not_nil(report)
				check.equal(#report.systems, 1)
				check.equal(report.systems[1].name, "Hydrogen.Debug")
				check.is_true(report.total >= 0)
			end)
			return nil
		end)

		test.case("configure rejects bad options with a fix", function()
			local ok, err = pcall(Debug.configure, { users = { "Alice" } } :: any)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "users must be a list of UserIds", 1, true))

			ok, err = pcall(Debug.configure, { inspect = { {} } } :: any)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "anything with find(player)", 1, true))

			ok, err = pcall(Debug.configure, { refresh = 0 })
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "refresh must be a positive number", 1, true))

			ok, err = pcall(Debug.configure, { key = "F3" } :: any)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "key must be an Enum.KeyCode", 1, true))
			return nil
		end)
	end)
end
