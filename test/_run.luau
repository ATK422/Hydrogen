local process = require("@lune/process")

-- The same runtime game developers use to run their tests under Lune: Roblox globals and a
-- Roblox-style require. Everything below loads through it.
local Lune = require("../src/Testing/Lune")
Lune.install()

local function require(path: string): any
	return Lune.require(path)
end

require("./Graph")()
require("./Definition")()
require("./App")()
require("./Network")()
require("./Testing")()
require("./Clock")()

local frktest = require("@pkg/frktest")
local console_reporter = frktest.reporters.console_reporter

console_reporter.init()

-- Exit explicitly: a test that yields the main thread and is resumed from a timer (the
-- server function timeout test) can otherwise keep Lune running after the last suite.
process.exit(if frktest.run() then 0 else 1)
