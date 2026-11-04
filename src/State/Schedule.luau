--!strict

local Clock = require("../Clock")

-- State's only time source, kept in one place so it follows Hydrogen.Clock.
local Schedule = {}

-- Runs callback once at the end of this frame. Heartbeat is the last step of a frame, so every
-- write made anywhere in the frame goes out together. Under a fake clock the next advance is the
-- next frame. Headless without one (Lune's Heartbeat never fires), it runs deferred.
function Schedule.nextFrame(callback: () -> ())
	local heartbeat = (game:GetService("RunService") :: any).Heartbeat
	if Clock.active() or (heartbeat and heartbeat.Once) then
		local disconnect: (() -> ())? = nil
		disconnect = Clock.heartbeat(function()
			if disconnect then
				disconnect()
				disconnect = nil
				callback()
			end
		end)
	else
		task.defer(callback)
	end
end

return Schedule
