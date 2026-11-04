--!strict

local Time = require("../Clock")

-- Every time source Receipts uses. Each forwards to Hydrogen.Clock at call time, so the test
-- harness's fake clock reaches Receipts; tests can also replace these fields directly.
local Clock = {
	clock = function(): number
		return Time.now()
	end,
	delay = function(seconds: number, callback: any, ...: any): thread
		return Time.delay(seconds, callback, ...)
	end,
	cancel = function(thread: thread)
		Time.cancel(thread)
	end,
	wait = function(seconds: number?): number
		return Time.wait(seconds)
	end,
}

return Clock
