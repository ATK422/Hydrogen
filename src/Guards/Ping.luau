--!strict

-- Each player's network latency, for timestamp checks. Roblox measures it (Player:GetNetworkPing);
-- tests and games with their own measurement replace it with Guards.configure({ ping = ... }).

local Log = require("../Log")

local Ping = {
	-- Replaces the default lookup. Set with Guards.configure({ ping = ... }).
	source = nil :: ((player: Player) -> number?)?,
	-- Default cap for timestamp checks, in seconds. Set with Guards.configure({ maxPing = ... }).
	maxPing = 1,
}

local function networkPing(player: Player): number?
	-- Protected: a loopback's fake players have no GetNetworkPing.
	local ok, result = pcall(function()
		return (player :: any):GetNetworkPing()
	end)
	return if ok and type(result) == "number" then result else nil
end

-- The player's latency in seconds. 0 when it's unknown, so an unknown ping never widens a window.
function Ping.of(player: Player): number
	local value: any
	local source = Ping.source
	if source then
		local ok, result = xpcall(source, debug.traceback, player)
		if not ok then
			Log.warn(`[HYDROGEN] Guards ping function failed; treating the ping as 0: {result}`)
			return 0
		end
		value = result
	else
		value = networkPing(player)
	end
	if type(value) ~= "number" or not (value >= 0) or value == math.huge then
		return 0
	end
	return value
end

return Ping
