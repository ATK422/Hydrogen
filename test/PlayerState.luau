--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")

local Data = Hydrogen.Data
local PlayerState = Hydrogen.PlayerState

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

-- Replication goes out at the end of the frame.
local function flushed()
	task.wait()
	task.wait()
end

local function newProfile(backend: Hydrogen.DataBackend)
	return Data.player("PlayerData", {
		template = { coins = 0, level = 1, items = {} :: { string }, secret = "hidden" },
		schema = Hydrogen.gt.table({
			coins = Hydrogen.gt.number({ range = "[0, inf]" }),
			level = Hydrogen.gt.number(),
			items = Hydrogen.gt.array(Hydrogen.gt.string()),
			secret = Hydrogen.gt.string(),
		}),
		backend = backend,
	})
end

return function()
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

	test.suite("PlayerState", function()
		test.case("saved fields write through to Data, runtime fields stay in memory", function()
			local backend = Data.memory()
			local PlayerData = newProfile(backend)
			local Session = PlayerState.new("StateBasics", {
				data = PlayerData,
				runtime = { inCombat = false, streak = 0 },
			})

			local seen: number? = nil
			local Combat = Hydrogen.define("StateCombat", function(use)
				local Sessions = use(Session)
				return {
					playerAdded = function(_, player: Player)
						-- Loaded before any system that uses the state sees the player.
						seen = Sessions:get(player).coins
					end,
				}
			end)

			local net = openLoopback()
			local alice = net:join("Alice")
			local app = newApp()
			app:addSystems({ Combat, Session, PlayerData })
			app:start()
			check.is_true(waitUntil(function()
				return seen ~= nil
			end))
			check.equal(seen, 0)

			local state = Session:get(alice)
			state.coins += 5
			check.equal(state.coins, 5)
			check.equal(PlayerData:get(alice).coins, 5)

			-- Checked against the store's schema at the assignment.
			check.should_error(function()
				state.coins = -1
				return nil
			end)
			check.equal(state.coins, 5)

			state.inCombat = true
			state.streak += 1
			check.equal(state.inCombat, true)
			check.equal(state.streak, 1)
			check.equal((PlayerData:get(alice) :: any).inCombat, nil)

			check.should_error(function()
				(state :: any).typo = 1
				return nil
			end)

			-- Nested values are frozen; update edits a copy.
			check.should_error(function()
				table.insert(state.items, "sword")
				return nil
			end)
			Session:update(alice, "items", function(items)
				table.insert(items, "sword")
				return nil
			end)
			Session:update(alice, "streak", function(streak)
				return streak + 10
			end)
			check.equal(state.items[1], "sword")
			check.equal(PlayerData:get(alice).items[1], "sword")
			check.equal(state.streak, 11)

			local fields = {}
			for field in state do
				table.insert(fields, field)
			end
			check.equal(#fields, 6)

			net:leave(alice)
			check.is_true(waitUntil(function()
				return Session:find(alice) == nil and not PlayerData:isLoaded(alice)
			end))
			local record = backend:peek("PlayerData", tostring(alice.UserId))
			check.equal(record.data.coins, 5)
			check.equal(record.data.items[1], "sword")
			check.equal(record.data.streak, nil)
			return nil
		end)

		test.case("changes made through Data reach the state and its listeners", function()
			local backend = Data.memory()
			local PlayerData = newProfile(backend)
			local Session = PlayerState.new("StateFromData", { data = PlayerData })

			local changes = {}
			Session:changed("coins", function(player, value, old)
				table.insert(changes, `{player.Name}:{old}->{value}`)
			end)

			local net = openLoopback()
			local alice = net:join("Alice")
			local app = newApp()
			app:addSystems({ Session, PlayerData })
			app:start()
			check.is_true(waitUntil(function()
				return Session:find(alice) ~= nil
			end))

			-- What a receipt handler does.
			check.equal(PlayerData:updateOnce(alice, "receipt-1", function(data)
				data.coins += 100
				return nil
			end), "applied")
			check.equal(Session:get(alice).coins, 100)

			Session:get(alice).coins = 150
			check.equal(#changes, 2)
			check.equal(changes[1], "Alice:0->100")
			check.equal(changes[2], "Alice:100->150")

			check.should_error(function()
				Session:changed("nope", function() end)
				return nil
			end)
			return nil
		end)

		test.case("replicates owner fields to the owner and everyone fields to every client", function()
			local backend = Data.memory()
			local PlayerData = newProfile(backend)
			local Session = PlayerState.new("StateReplicated", {
				data = PlayerData,
				runtime = { inCombat = false, aim = 0 },
				replicate = { coins = "owner", level = "everyone", inCombat = "everyone" },
			})

			local net = openLoopback()
			local alice = net:join("Alice")
			local bob = net:join("Bob")
			local app = newApp()
			app:addSystems({ Session, PlayerData })
			app:start()
			check.is_true(waitUntil(function()
				return Session:find(alice) ~= nil and Session:find(bob) ~= nil
			end))
			flushed()

			local own = Session:replica(alice, alice) :: any
			check.equal(own.coins, 0)
			check.equal(own.level, 1)
			check.equal(own.inCombat, false)
			check.equal(own.secret, nil)
			check.equal(own.aim, nil)

			local seenByBob = Session:replica(bob, alice) :: any
			check.equal(seenByBob.coins, nil)
			check.equal(seenByBob.level, 1)

			local state = Session:get(alice)
			state.coins = 9
			state.level = 2
			state.inCombat = true
			state.aim = 45
			state.secret = "still hidden"
			flushed()

			own = Session:replica(alice, alice) :: any
			check.equal(own.coins, 9)
			check.equal(own.level, 2)
			check.equal(own.inCombat, true)
			check.equal(own.aim, nil)
			check.equal(own.secret, nil)
			seenByBob = Session:replica(bob, alice) :: any
			check.equal(seenByBob.coins, nil)
			check.equal(seenByBob.level, 2)
			check.equal(seenByBob.inCombat, true)

			-- A late joiner gets everyone's public fields.
			local carol = net:join("Carol")
			check.is_true(waitUntil(function()
				return Session:find(carol) ~= nil
			end))
			flushed()
			local seenByCarol = Session:replica(carol, alice) :: any
			check.equal(seenByCarol.level, 2)
			check.equal(seenByCarol.coins, nil)
			check.equal((Session:replica(carol, carol) :: any).coins, 0)

			net:leave(alice)
			check.is_true(waitUntil(function()
				return Session:replica(bob, alice) == nil
			end))
			check.equal(Session:replica(carol, alice), nil)
			return nil
		end)

		test.case("runtime-only state needs no Data store", function()
			local Round = PlayerState.new("StateRuntimeOnly", {
				runtime = { kills = 0 },
				replicate = { kills = "everyone" },
			})

			local net = openLoopback()
			local alice = net:join("Alice")
			local app = newApp()
			app:addSystem(Round)
			app:start()
			check.is_true(waitUntil(function()
				return Round:find(alice) ~= nil
			end))
			Round:get(alice).kills += 1
			flushed()
			check.equal((Round:replica(alice, alice) :: any).kills, 1)
			return nil
		end)

		test.case("declarations are checked when the state is defined", function()
			local PlayerData = newProfile(Data.memory())
			check.should_error(function()
				PlayerState.new("StateBadAudience", { data = PlayerData, replicate = { coins = "all" :: any } })
				return nil
			end)
			check.should_error(function()
				PlayerState.new("StateUnknownField", { data = PlayerData, replicate = { gems = "owner" } })
				return nil
			end)
			check.should_error(function()
				PlayerState.new("StateOverlap", { data = PlayerData, runtime = { coins = 0 } })
				return nil
			end)
			check.should_error(function()
				PlayerState.new("StateNotAStore", { data = {} :: any })
				return nil
			end)
			return nil
		end)

		return nil
	end)
	return nil
end
