--!strict

-- Forgets a player's guard state (cooldowns, cached roles) when they leave. It starts following
-- leaves the first time state is written for a player, so a game that never uses Guards pays nothing.
-- Under a loopback it follows the fake clients, and attaches again to each new loopback.

local Runtime = require("../Network/Runtime")

local Leave = {}

local forgetters: { (player: Player) -> () } = {}
-- The loopback whose clients are followed, and whether Players.PlayerRemoving is connected.
local attached: any = nil
local connected = false

local function left(player: Player)
	for _, forget in forgetters do
		forget(player)
	end
end

local function noop(_player: Player) end

-- Registers what to clear for a player who left. Called once per internal module.
function Leave.on(forget: (player: Player) -> ())
	table.insert(forgetters, forget)
end

-- Call before writing state for a player, so that state is cleared when they leave.
function Leave.track()
	local loopback = Runtime.Loopback :: any
	if loopback then
		if attached ~= loopback then
			attached = loopback
			loopback:watch(noop, left)
		end
		return
	end

	-- No loopback: the real Players service. A loopback that closed already removed its players.
	if not connected then
		connected = true
		pcall(function()
			game:GetService("Players").PlayerRemoving:Connect(left)
		end)
	end
end

-- Whether the player left (or is leaving), so no new state should be kept for them.
function Leave.gone(player: Player): boolean
	return Runtime:isDeparted(player)
end

return Leave
