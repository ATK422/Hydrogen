--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local App = require("../src/App")
local Definition = require("../src/Definition")

return function()
	test.suite("App", function()
		test.case("start runs init on every system before start", function()
			local events = {}

			local logger = Definition.define(function()
				return {
					name = "logger",
					init = function()
						table.insert(events, "logger:init")
					end,
					start = function()
						table.insert(events, "logger:start")
					end,
				}
			end)

			local player = Definition.define(function(use)
				use(logger)
				return {
					name = "player",
					init = function()
						table.insert(events, "player:init")
					end,
					start = function()
						table.insert(events, "player:start")
					end,
				}
			end)

			local app = App.new()
			app:addSystem(player)
			app:addSystem(logger)
			app:start()

			check.equal(events[1], "logger:init")
			check.equal(events[2], "player:init")
			check.equal(events[3], "logger:start")
			check.equal(events[4], "player:start")
			return nil
		end)

		test.case("systems without lifecycle hooks can still start", function()
			local system = Definition.define(function()
				return {
					name = "plain",
				}
			end)

			local app = App.new()
			app:addSystem(system)
			check.should_not_error(function()
				app:start()
				return nil
			end)
			return nil
		end)

		test.case("addSystem after start immediately inits and starts", function()
			local events = {}
			local app = App.new()
			app:start()

			local late = Definition.define(function()
				return {
					name = "late",
					init = function()
						table.insert(events, "late:init")
					end,
					start = function()
						table.insert(events, "late:start")
					end,
				}
			end)

			app:addSystem(late)

			check.equal(events[1], "late:init")
			check.equal(events[2], "late:start")
			return nil
		end)

		test.case("new apps do not share systems", function()
			local system = Definition.define(function()
				return {
					name = "shared-check",
				}
			end)

			local first = App.new()
			first:addSystem(system)

			local second = App.new()
			check.equal(#second._systems, 0)
			return nil
		end)

		test.case("boot errors name the system and hook", function()
			local broken = Definition.define("Battles", function()
				return {
					start = function()
						error("boom")
					end,
				}
			end)

			local app = App.new()
			app:addSystem(broken)

			local ok, err = pcall(function()
				app:start()
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "System Battles failed in start", 1, true))
			check.not_nil(string.find(tostring(err), "boom", 1, true))
			return nil
		end)

		test.case("debug prints boot timings per system", function()
			local system = Definition.define("Timed", function()
				return {
					init = function() end,
				}
			end)

			local printed = {}
			local app = App.new({
				debug = true,
				output = function(message)
					table.insert(printed, message)
				end,
			})
			app:addSystem(system)
			app:start()

			check.equal(#printed, 1)
			check.not_nil(string.find(printed[1], "Booted 1 systems", 1, true))
			check.not_nil(string.find(printed[1], "Timed: init", 1, true))
			return nil
		end)

		test.case("player hooks run in dependency order, removing in reverse", function()
			local events = {}

			local data = Definition.define(function()
				return {
					playerAdded = function(_, player)
						table.insert(events, `data:added:{player.Name}`)
					end,
					playerRemoving = function(_, player)
						table.insert(events, `data:removing:{player.Name}`)
					end,
				}
			end)

			local lobby = Definition.define(function(use)
				use(data)
				return {
					playerAdded = function(_, player)
						table.insert(events, `lobby:added:{player.Name}`)
					end,
					playerRemoving = function(_, player)
						table.insert(events, `lobby:removing:{player.Name}`)
					end,
				}
			end)

			local app = App.new()
			app:addSystems({ lobby, data })
			app:start()

			local player = { Name = "P" } :: any
			app:_addPlayer(player)
			app:_addPlayer(player)
			app:_removePlayer(player)
			app:_removePlayer(player)

			check.equal(#events, 4)
			check.equal(events[1], "data:added:P")
			check.equal(events[2], "lobby:added:P")
			check.equal(events[3], "lobby:removing:P")
			check.equal(events[4], "data:removing:P")
			return nil
		end)

		test.case("stop removes remaining players, then stops in reverse order", function()
			local events = {}

			local data = Definition.define(function()
				return {
					playerRemoving = function(_, player)
						table.insert(events, `data:removing:{player.Name}`)
					end,
					stop = function()
						table.insert(events, "data:stop")
					end,
				}
			end)

			local lobby = Definition.define(function(use)
				use(data)
				return {
					stop = function()
						table.insert(events, "lobby:stop")
					end,
				}
			end)

			local app = App.new()
			app:addSystems({ lobby, data })
			app:start()

			app:_addPlayer({ Name = "P" } :: any)
			app:stop()
			app:stop()
			app:_addPlayer({ Name = "Late" } :: any)

			check.equal(#events, 3)
			check.equal(events[1], "data:removing:P")
			check.equal(events[2], "lobby:stop")
			check.equal(events[3], "data:stop")
			return nil
		end)

		test.case("playerRemoving waits for a yielding playerAdded to finish", function()
			local events = {}

			local data = Definition.define(function()
				return {
					playerAdded = function()
						task.wait()
						table.insert(events, "loaded")
					end,
					playerRemoving = function()
						table.insert(events, "saved")
					end,
				}
			end)

			local app = App.new()
			app:addSystem(data)
			app:start()

			local player = { Name = "P" } :: any
			task.spawn(app._addPlayer, app, player)
			app:_removePlayer(player)

			check.equal(events[1], "loaded")
			check.equal(events[2], "saved")
			return nil
		end)

		test.case("a failing hook doesn't stop the other systems' hooks", function()
			local saved = false

			local data = Definition.define(function()
				return {
					playerRemoving = function()
						saved = true
					end,
				}
			end)

			local broken = Definition.define(function(use)
				use(data)
				return {
					playerRemoving = function()
						error("boom")
					end,
				}
			end)

			local app = App.new()
			app:addSystems({ broken, data })
			app:start()

			local player = { Name = "P" } :: any
			app:_addPlayer(player)
			check.should_not_error(function()
				app:_removePlayer(player)
				return nil
			end)
			check.equal(saved, true)
			return nil
		end)

		test.case("systems added after start get playerAdded for current players", function()
			local added = {}
			local app = App.new()
			app:start()

			local player = { Name = "P" } :: any
			app:_addPlayer(player)

			app:addSystem(Definition.define(function()
				return {
					playerAdded = function(_, who)
						table.insert(added, who)
					end,
				}
			end))

			check.equal(added[1], player)
			return nil
		end)

		test.case("addSystemsFolders accepts a ModuleScript and any Instance", function()
			local system = Definition.define(function()
				return {}
			end)

			local module = Instance.new("ModuleScript")
			_G.instanceModules[module] = system

			local app = App.new()
			app:addSystemsFolders(module)

			check.equal(app._systems[1], system)
			return nil
		end)
		return nil
	end)
	return nil
end
