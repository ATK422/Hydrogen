--!strict

local RunService = game:GetService("RunService")

-- State's only time source, kept in one place so a fake clock can replace it in tests.
local Schedule = {}

-- Runs callback once at the end of this frame. Heartbeat is the last step of a frame, so every
-- write made anywhere in the frame goes out together. Headless (no Heartbeat), it runs deferred.
function Schedule.nextFrame(callback: () -> ())
	local heartbeat = (RunService :: any).Heartbeat
	if heartbeat then
		heartbeat:Once(callback)
	else
		task.defer(callback)
	end
end

return Schedule
