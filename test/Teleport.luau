--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")

local Data = Hydrogen.Data
local Teleport = Hydrogen.Teleport
local gt = Hydrogen.gt

type Profile = { coins: number }

local TEMPLATE: Profile = { coins = 0 }
local PLACE = 4242

local stores = 0

-- A fresh player store over its own memory backend, so tests can't see each other's records.
local function newStore(options: { [string]: any }?): (Hydrogen.Defined<Hydrogen.PlayerStore<Profile>>, Hydrogen.MemoryBackend, string)
	stores += 1
	local name = `TeleportProfile{stores}`
	local backend = Data.memory()
	local settings: any = { template = TEMPLATE, backend = backend }
	for key, value in options or {} do
		settings[key] = value
	end
	return Data.player(name, settings), backend, name
end

-- Another server over the same backend, which can try to load the player's record.
local function otherServer(name: string, backend: Hydrogen.DataBackend): Hydrogen.KeyStore<Profile>
	return Data.store(name, { template = TEMPLATE, backend = backend }) :: any
end

local function addCoins(store: any, player: Player, amount: number): boolean
	return store:update(player, function(data: Profile)
		data.coins += amount
		return nil
	end)
end

local function contains(text: string, part: string): boolean
	return string.find(text, part, 1, true) ~= nil
end

return function()
	test.suite("Teleport", function()
		test.case("hands off: saves, releases the lock, then teleports; another server loads at once", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				check.equal(PlayerData:isLoaded(alice), true)
				addCoins(PlayerData, alice, 50)

				fake:hold(true)
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)

				-- Roblox accepted the teleport; the player hasn't left yet.
				check.equal(#fake.requests, 1)
				check.equal(fake.requests[1].placeId, PLACE)
				check.equal(fake.requests[1].players[1], alice)
				check.equal(result, nil)

				local key = tostring(alice.UserId)
				local record = backend:peek(name, key)
				check.equal(record.lock, nil)
				check.equal(record.data.coins, 50)

				-- Still readable here, but no longer held.
				check.equal(PlayerData:isLoaded(alice), false)
				check.equal(PlayerData:get(alice).coins, 50)

				-- The destination's load finds no lock.
				local destination = otherServer(name, backend)
				local ok = destination:load(key)
				check.equal(ok, true)
				check.equal(destination:get(key).coins, 50)

				fake:complete(alice)
				t:advance(0)
				local done = result :: Hydrogen.TeleportResult
				check.equal(done.ok, true)
				check.equal(done.teleported[1], alice)
				check.equal(#done.failed, 0)
				check.equal(done.attempts, 1)
				destination:unload(key)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("retries a failed teleport with backoff, keeping the data released", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				fake:failNext(1, "Failure")
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)

				check.equal(#fake.requests, 1)
				check.equal(result, nil)
				check.equal(backend:peek(name, tostring(alice.UserId)).lock, nil)

				t:advance(0.5)
				check.equal(#fake.requests, 1)
				t:advance(0.5)
				check.equal(#fake.requests, 2)

				local done = result :: Hydrogen.TeleportResult
				check.equal(done.ok, true)
				check.equal(done.attempts, 2)
				check.equal(done.teleported[1], alice)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("retries TeleportAsync errors", function()
			local PlayerData = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				fake:errorNext(1, "HTTP 429 (Too Many Requests)")
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)
				t:advance(1)
				local done = result :: Hydrogen.TeleportResult
				check.equal(done.ok, true)
				check.equal(done.attempts, 2)
			end)
			return nil
		end)

		test.case("after the last failed attempt the data is taken back and writable, with changes made meanwhile", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				addCoins(PlayerData, alice, 10)
				fake:failNext(3, "Flooded", "too many teleports")
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)

				-- A change while the data is handed off stays in memory.
				check.equal(addCoins(PlayerData, alice, 7), true)
				check.equal(PlayerData:get(alice).coins, 17)
				check.equal(backend:peek(name, tostring(alice.UserId)).data.coins, 10)

				t:advance(15) -- Flooded waits 15 s
				check.equal(#fake.requests, 2)
				t:advance(15)
				check.equal(#fake.requests, 3)

				local done = result :: Hydrogen.TeleportResult
				check.equal(done.ok, false)
				check.equal(done.attempts, 3)
				check.equal(#done.failed, 1)
				check.equal(done.failed[1].player, alice)
				check.equal(done.failed[1].reason, "Flooded")
				t:expectWarning("Teleport to place 4242 failed for Alice (Flooded")

				-- Taken back: held again, the change made meanwhile kept and saved.
				check.equal(PlayerData:isLoaded(alice), true)
				check.equal(PlayerData:get(alice).coins, 17)
				local record = backend:peek(name, tostring(alice.UserId))
				check.equal(record.data.coins, 17)
				check.equal(record.lock ~= nil, true)

				check.equal(addCoins(PlayerData, alice, 1), true)
				local saved = PlayerData:save(alice)
				check.equal(saved, true)
				check.equal(backend:peek(name, tostring(alice.UserId)).data.coins, 18)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("doesn't retry reasons waiting can't fix", function()
			local PlayerData = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				fake:failNext(1, "GameFull")
				local result = Teleport.send(alice, PLACE)
				check.equal(result.ok, false)
				check.equal(result.attempts, 1)
				check.equal(result.failed[1].reason, "GameFull")
				check.equal(PlayerData:isLoaded(alice), true)
				t:expectWarning("GameFull")
			end)
			return nil
		end)

		test.case("a player who leaves between attempts keeps their released data and isn't retried", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				addCoins(PlayerData, alice, 3)
				fake:failNext(1)
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)
				t:leave(alice)
				t:advance(1)

				local done = result :: Hydrogen.TeleportResult
				check.equal(done.ok, false)
				check.equal(done.failed[1].reason, "Left")
				check.equal(#fake.requests, 1)
				local record = backend:peek(name, tostring(alice.UserId))
				check.equal(record.lock, nil)
				check.equal(record.data.coins, 3)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("a player who leaves while their data is being saved isn't sent", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				addCoins(PlayerData, alice, 4)
				backend.latency = 1
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)
				t:leave(alice)
				t:advance(1)
				t:advance(1)

				local done = result :: Hydrogen.TeleportResult
				check.equal(done.failed[1].reason, "Left")
				check.equal(#fake.requests, 0)
				local record = backend:peek(name, tostring(alice.UserId))
				check.equal(record.lock, nil)
				check.equal(record.data.coins, 4)
			end)
			return nil
		end)

		test.case("a second send for a player already teleporting answers Busy", function()
			local PlayerData = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				fake:hold(true)
				local first: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					first = Teleport.send(alice, PLACE)
				end)
				local second = Teleport.send(alice, PLACE + 1)
				check.equal(second.ok, false)
				check.equal(second.failed[1].reason, "Busy")
				check.equal(second.attempts, 0)
				check.equal(#fake.requests, 1)
				t:expectWarning("(Busy:")

				fake:complete(alice)
				t:advance(0)
				check.equal((first :: Hydrogen.TeleportResult).ok, true)
			end)
			return nil
		end)

		test.case("an accepted teleport that never happens times out and takes the data back", function()
			local PlayerData = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				fake:hold(true)
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE, { timeout = 10 })
				end)
				t:advance(9)
				check.equal(result, nil)
				t:advance(1)
				local done = result :: Hydrogen.TeleportResult
				check.equal(done.failed[1].reason, "TimedOut")
				check.equal(done.attempts, 1)
				check.equal(PlayerData:isLoaded(alice), true)
				t:expectWarning("TimedOut")
			end)
			return nil
		end)

		test.case("shutdown during the backoff stops retrying and leaves the data released", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				addCoins(PlayerData, alice, 9)
				fake:failNext(1)
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)
				t.app:stop()
				t:advance(1)

				local done = result :: Hydrogen.TeleportResult
				check.equal(done.failed[1].reason, "ShuttingDown")
				check.equal(#fake.requests, 1)
				local record = backend:peek(name, tostring(alice.UserId))
				check.equal(record.lock, nil)
				check.equal(record.data.coins, 9)
				check.equal(alice.Parent ~= nil, true) -- not kicked
				t:expectWarning("ShuttingDown")
			end)
			return nil
		end)

		test.case("a party retries only the members who failed, into the same reserved server", function()
			local PlayerData = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				fake:failNext(1) -- the first member named: Alice
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send({ alice, bob }, PLACE, { reserveServer = true })
				end)
				check.equal(bob.Parent, nil)
				t:advance(1)

				local done = result :: Hydrogen.TeleportResult
				check.equal(done.ok, true)
				check.equal(#done.teleported, 2)
				check.equal(done.reservedCode, "fake-reserved-1")
				local retry = fake.requests[2]
				check.equal(#retry.players, 1)
				check.equal(retry.players[1], alice)
				check.equal(retry.reserveServer, nil)
				check.equal(retry.reservedCode, "fake-reserved-1")
			end)
			return nil
		end)

		test.case("a player whose data can't be saved isn't sent, and keeps playing on it", function()
			local PlayerData, backend, name = newStore({ retries = 1 })
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				addCoins(PlayerData, alice, 2)
				backend:fail(1, "update", "DataStore outage")
				local result = Teleport.send(alice, PLACE)
				check.equal(result.failed[1].reason, "DataNotSaved")
				check.equal(#fake.requests, 0)
				check.equal(PlayerData:isLoaded(alice), true)
				t:expectWarning("DataNotSaved")

				addCoins(PlayerData, alice, 1)
				check.equal(PlayerData:save(alice), true)
				local record = backend:peek(name, tostring(alice.UserId))
				check.equal(record.data.coins, 3)
				check.equal(record.lock ~= nil, true)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("a release that landed but reported an error doesn't cost the player their data", function()
			local inner = Data.memory()
			local errorsAfterWrite = 0
			local backend: Hydrogen.DataBackend = {
				update = function(_self: any, store: string, key: string, transform: any): any
					local value = inner:update(store, key, transform)
					if errorsAfterWrite > 0 then
						errorsAfterWrite -= 1
						error("DataStore request timed out", 0)
					end
					return value
				end,
				read = function(_self: any, store: string, key: string): any
					return inner:read(store, key)
				end,
				write = function(_self: any, store: string, key: string, value: any)
					inner:write(store, key, value)
				end,
				budget = function(_self: any, kind: any): number
					return inner:budget(kind)
				end,
			}
			stores += 1
			local name = `TeleportProfile{stores}`
			local PlayerData = Data.player(name, { template = TEMPLATE, backend = backend, retries = 1 })
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				addCoins(PlayerData, alice, 5)
				errorsAfterWrite = 1
				local result = Teleport.send(alice, PLACE)
				check.equal(result.failed[1].reason, "DataNotSaved")
				check.equal(inner:peek(name, tostring(alice.UserId)).lock, nil) -- it did land
				t:expectWarning("DataNotSaved")

				-- The next save takes the unlocked record back instead of treating it as lost.
				addCoins(PlayerData, alice, 1)
				check.equal(PlayerData:save(alice), true)
				check.equal(alice.Parent ~= nil, true)
				local record = inner:peek(name, tostring(alice.UserId))
				check.equal(record.data.coins, 6)
				check.equal(record.lock ~= nil, true)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("after a release that may have landed, a record someone else changed is never overwritten", function()
			local inner = Data.memory()
			local errorsAfterWrite = 0
			local backend: Hydrogen.DataBackend = {
				update = function(_self: any, store: string, key: string, transform: any): any
					local value = inner:update(store, key, transform)
					if errorsAfterWrite > 0 then
						errorsAfterWrite -= 1
						error("DataStore request timed out", 0)
					end
					return value
				end,
				read = function(_self: any, store: string, key: string): any
					return inner:read(store, key)
				end,
				write = function(_self: any, store: string, key: string, value: any)
					inner:write(store, key, value)
				end,
				budget = function(_self: any, kind: any): number
					return inner:budget(kind)
				end,
			}
			stores += 1
			local name = `TeleportProfile{stores}`
			local PlayerData = Data.player(name, { template = TEMPLATE, backend = backend, retries = 1 })
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				addCoins(PlayerData, alice, 5)
				errorsAfterWrite = 1
				check.equal(Teleport.send(alice, PLACE).failed[1].reason, "DataNotSaved")
				t:expectWarning("DataNotSaved")

				-- Another server loads the unlocked record, changes it and releases it.
				local key = tostring(alice.UserId)
				local other = otherServer(name, backend)
				check.equal(other:load(key), true)
				other:update(key, function(data: Profile)
					data.coins = 500
					return nil
				end)
				other:unload(key)

				check.equal(PlayerData:save(alice), false)
				check.equal(inner:peek(name, key).data.coins, 500)
				t:expectWarning("another server took the lock")
			end)
			return nil
		end)

		test.case("a release retried after it landed isn't a lost lock", function()
			local inner = Data.memory()
			local errorsAfterWrite = 0
			local backend: Hydrogen.DataBackend = {
				update = function(_self: any, store: string, key: string, transform: any): any
					local value = inner:update(store, key, transform)
					if errorsAfterWrite > 0 then
						errorsAfterWrite -= 1
						error("DataStore request timed out", 0)
					end
					return value
				end,
				read = function(_self: any, store: string, key: string): any
					return inner:read(store, key)
				end,
				write = function(_self: any, store: string, key: string, value: any)
					inner:write(store, key, value)
				end,
				budget = function(_self: any, kind: any): number
					return inner:budget(kind)
				end,
			}
			stores += 1
			local name = `TeleportProfile{stores}`
			local PlayerData = Data.player(name, { template = TEMPLATE, backend = backend, retries = 2 })
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				errorsAfterWrite = 1
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)
				t:advance(1) -- Data's retry backoff
				check.equal((result :: Hydrogen.TeleportResult).ok, true)
				t:expectWarning("request failed (attempt 1 of 2)")
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("changes after a successful hand-off are reported as not saved", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				fake:hold(true)
				task.spawn(function()
					Teleport.send(alice, PLACE)
				end)
				addCoins(PlayerData, alice, 100)
				fake:complete(alice)
				t:advance(0)
				check.equal(backend:peek(name, tostring(alice.UserId)).data.coins, 0)
				t:expectWarning("made after their data was handed off for a teleport weren't saved")
			end)
			return nil
		end)

		test.case("onHandOff runs before the release, so its changes reach the destination", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })
			local seen: { Player } = {}
			local remove = Teleport.onHandOff(function(player: Player)
				table.insert(seen, player)
				addCoins(PlayerData, player, 25)
			end)

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(_t, alice)
				local result = Teleport.send(alice, PLACE)
				check.equal(result.ok, true)
				check.equal(seen[1], alice)
				check.equal(backend:peek(name, tostring(alice.UserId)).data.coins, 25)
			end)
			remove()
			return nil
		end)

		test.case("reclaim lets saved data that changed meanwhile win over changes made here", function()
			local PlayerData, backend, name = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				local seen: { number } = {}
				PlayerData:changed(function(_player: Player, data: Profile)
					table.insert(seen, data.coins)
				end)
				fake:hold(true)
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)
				addCoins(PlayerData, alice, 5) -- in memory only

				-- Something else writes the released record meanwhile.
				local key = tostring(alice.UserId)
				local other = otherServer(name, backend)
				check.equal(other:load(key), true)
				other:update(key, function(data: Profile)
					data.coins = 999
					return nil
				end)
				other:unload(key)

				fake:fail(alice, "Unauthorized")
				t:advance(0)
				local done = result :: Hydrogen.TeleportResult
				check.equal(done.failed[1].reason, "Unauthorized")
				check.equal(PlayerData:isLoaded(alice), true)
				check.equal(PlayerData:get(alice).coins, 999)
				check.equal(seen[#seen], 999)
				t:expectWarning("saved data changed while their teleport was in progress")
				t:expectWarning("Unauthorized")
			end)
			return nil
		end)

		test.case("if the data can't be taken back, the store's onLoadFailed runs", function()
			local messages: { string } = {}
			local PlayerData, backend, name = newStore({
				loadTimeout = 2,
				onLoadFailed = function(_player: Player, message: string)
					table.insert(messages, message)
				end,
			})
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				fake:hold(true)
				local result: Hydrogen.TeleportResult? = nil
				task.spawn(function()
					result = Teleport.send(alice, PLACE)
				end)
				-- Another server takes the released record and keeps it.
				local key = tostring(alice.UserId)
				local other = otherServer(name, backend)
				check.equal(other:load(key), true)

				fake:fail(alice, "GameFull")
				t:advance(0)
				t:advance(1)
				t:advance(1)
				local done = result :: Hydrogen.TeleportResult
				check.equal(done.failed[1].reason, "GameFull")
				check.equal(contains(done.failed[1].message, "their data couldn't be taken back"), true)
				check.equal(#messages, 1)
				check.equal(contains(messages[1], "couldn't take Alice's data back after a failed teleport"), true)
				check.equal(PlayerData:isLoaded(alice), false)
				other:unload(key)
				t:expectWarning("GameFull")
			end)
			return nil
		end)

		test.case("tickets carry typed data, readable on arrival through the schema", function()
			local PlayerData = newStore()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })
			local DungeonTicket = Teleport.ticket("Dungeon", gt.table({ dungeon = gt.string(), difficulty = gt.number() }))
			local OtherTicket = Teleport.ticket("Other", gt.table({ dungeon = gt.string() }))

			Hydrogen.test({ systems = { PlayerData, Teleport }, players = { "Alice" } }, function(t, alice)
				local result = DungeonTicket:send(alice, PLACE, { dungeon = "Crypt", difficulty = 2 })
				check.equal(result.ok, true)
				local data = fake.requests[1].data
				check.equal(data.ticket, "Dungeon")
				check.equal(data.value.dungeon, "Crypt")

				-- Play the destination server.
				local bob = t:join("Bob")
				fake:arrive(bob)
				local ticket = DungeonTicket:read(bob)
				check.equal(ticket ~= nil, true)
				check.equal((ticket :: any).dungeon, "Crypt")
				check.equal((ticket :: any).difficulty, 2)
				check.equal(OtherTicket:read(bob), nil)
				check.equal((Teleport.joinData(bob) :: any).Members[1], alice.UserId)

				-- A tampered value fails the schema: ignored with a warning.
				fake:setJoinData(bob, { TeleportData = { ticket = "Dungeon", value = { dungeon = 5, difficulty = 1 } } })
				check.equal(DungeonTicket:read(bob), nil)
				t:expectWarning("Teleport ticket Dungeon for Bob doesn't match its schema")

				-- No join data at all.
				local carol = t:join("Carol")
				check.equal(DungeonTicket:read(carol), nil)
			end)
			return nil
		end)

		test.case("argument errors say how to fix the call", function()
			local Ticket = Teleport.ticket("Checked", gt.table({ level = gt.number() }))
			Hydrogen.test({ systems = { Teleport }, players = { "Alice" } }, function(_t, alice)
				local function message(fn: () -> ()): string
					local ok, err = pcall(fn)
					check.equal(ok, false)
					return tostring(err)
				end
				check.equal(contains(message(function()
					Teleport.send({}, PLACE)
				end), "needs a player or a list of players"), true)
				check.equal(contains(message(function()
					Teleport.send(alice, "place" :: any)
				end), "needs a place id"), true)
				check.equal(contains(message(function()
					Teleport.send(alice, PLACE, { serverId = "a", reserveServer = true })
				end), "pass only one of serverId, reservedCode and reserveServer"), true)
				check.equal(contains(message(function()
					Teleport.send(alice, PLACE, { data = { at = Vector3.new(1, 2, 3) } })
				end), "is a Vector3"), true)
				check.equal(contains(message(function()
					Ticket:send(alice, PLACE, { level = "high" } :: any)
				end), "doesn't match the ticket's schema"), true)
				check.equal(contains(message(function()
					Teleport.ticket("Bad", "schema" :: any)
				end), "needs a GreenTea schema"), true)
			end)
			return nil
		end)

		test.case("reserve hands out an access code, retrying failures", function()
			local fake = Teleport.fakeService()
			Teleport.configure({ service = fake })
			Hydrogen.test({ systems = { Teleport } }, function(t)
				fake:errorNext(1)
				local code: string? = nil
				task.spawn(function()
					code = Teleport.reserve(PLACE)
				end)
				t:advance(1)
				check.equal(code, "fake-reserved-1")
			end)
			return nil
		end)
	end)
end
