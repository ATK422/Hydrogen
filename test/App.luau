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
		return nil
	end)
	return nil
end
