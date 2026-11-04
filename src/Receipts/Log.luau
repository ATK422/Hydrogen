--!strict

-- Where Receipts sends warnings. Called through this table, so tests can capture them.
local Log = {
	warn = warn,
}

return Log
