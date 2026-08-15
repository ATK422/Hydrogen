--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Graph = require("../src/Graph")

return function()
	test.suite("Graph", function()
		test.case("sorts dependencies before dependents", function()
			local graph = Graph.new()
			local a = { id = "a" }
			local b = { id = "b" }
			local c = { id = "c" }

			graph:add(a)
			graph:add(b)
			graph:add(c)
			graph:link(c, b)
			graph:link(b, a)

			local ordered = graph:sort({ c, b, a })
			check.equal(ordered[1], a)
			check.equal(ordered[2], b)
			check.equal(ordered[3], c)
		end)

		test.case("keeps independent nodes in input order", function()
			local graph = Graph.new()
			local a = { id = "a" }
			local b = { id = "b" }

			graph:add(a)
			graph:add(b)

			local ordered = graph:sort({ a, b })
			check.equal(ordered[1], a)
			check.equal(ordered[2], b)
		end)

		test.case("does not duplicate links", function()
			local graph = Graph.new()
			local a = { id = "a" }
			local b = { id = "b" }

			graph:link(b, a)
			graph:link(b, a)

			local ordered = graph:sort({ b, a })
			check.equal(#ordered, 2)
			check.equal(ordered[1], a)
			check.equal(ordered[2], b)
		end)

		test.case("errors on cyclic dependencies", function()
			local graph = Graph.new()
			local a = { id = "a" }
			local b = { id = "b" }

			graph:link(a, b)
			graph:link(b, a)

			check.should_error(function()
				graph:sort({ a, b })
			end)
		end)

		test.case("only sorts nodes included in the request", function()
			local graph = Graph.new()
			local a = { id = "a" }
			local b = { id = "b" }
			local extra = { id = "extra" }

			graph:add(extra)
			graph:link(b, a)

			local ordered = graph:sort({ b, a })
			check.equal(#ordered, 2)
			check.equal(ordered[1], a)
			check.equal(ordered[2], b)
		end)
	end)
end
