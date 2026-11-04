--!strict

-- Every time source Data uses, in one place, so a test (or a fake clock) can swap them.
local Clock = {
	-- Wall-clock seconds, comparable across servers. Session locks are stamped with it.
	now = function(): number
		return os.time()
	end,
	wait = function(seconds: number)
		task.wait(seconds)
	end,
}

return Clock
