--!strict

local Time = require("../Clock")

-- Every time source Data uses, in one place. Each forwards to Hydrogen.Clock at call time, so
-- the test harness's fake clock reaches Data; a test can also replace these fields directly.
local Clock = {
	-- Wall-clock seconds, comparable across servers. Session locks are stamped with it.
	now = function(): number
		return Time.time()
	end,
	wait = function(seconds: number)
		Time.wait(seconds)
	end,
}

return Clock
