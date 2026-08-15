--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Definition = require("../src/Definition")

return function()
	test.suite("Definition", function()
		test.case("define returns the constructed system", function()
			local system = Definition.define(function()
				return {
					name = "constructed",
				}
			end)

			check.equal(system.name, "constructed")
			check.not_nil(system.id)
		end)

		test.case("order places used systems first", function()
			local logger = Definition.define(function()
				return {
					name = "logger",
				}
			end)

			local player = Definition.define(function(use)
				use(logger)
				return {
					name = "player",
				}
			end)

			local ordered = Definition.order({ player, logger })
			check.equal(ordered[1], logger)
			check.equal(ordered[2], player)
		end)

		test.case("order follows a chain of used systems", function()
			local config = Definition.define(function()
				return {
					name = "config",
				}
			end)

			local logger = Definition.define(function(use)
				use(config)
				return {
					name = "logger",
				}
			end)

			local player = Definition.define(function(use)
				use(logger)
				return {
					name = "player",
				}
			end)

			local ordered = Definition.order({ player, logger, config })
			check.equal(ordered[1], config)
			check.equal(ordered[2], logger)
			check.equal(ordered[3], player)
		end)

		test.case("order can sort a subset of defined systems", function()
			local a = Definition.define(function()
				return {
					name = "a",
				}
			end)

			local b = Definition.define(function(use)
				use(a)
				return {
					name = "b",
				}
			end)

			local c = Definition.define(function()
				return {
					name = "c",
				}
			end)

			local ordered = Definition.order({ b, a })
			check.equal(#ordered, 2)
			check.equal(ordered[1], a)
			check.equal(ordered[2], b)
			check.equal(c.name, "c")
		end)
	end)
end
