--!strict

local HydrogenLog = require("../Log")

-- Where Receipts sends warnings: Hydrogen's log, so the test harness captures them. Called
-- through this table, so tests can also replace it.
local Log = {
	warn = function(message: string)
		HydrogenLog.warn(message)
	end,
}

return Log
