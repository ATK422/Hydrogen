require("./Graph")()
require("./Definition")()
require("./App")()

local frktest = require("@pkg/frktest")
local console_reporter = frktest.reporters.console_reporter
local process = require("@lune/process")

console_reporter.init()

if not frktest.run() then
	process.exit(1)
end
