--!strict

-- Every time source Receipts uses. Always called through this table, so a fake clock can
-- replace the fields in tests.
local Clock = {
	clock = os.clock,
	delay = task.delay,
	cancel = task.cancel,
	wait = task.wait,
}

return Clock
