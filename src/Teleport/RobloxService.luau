--!strict

-- The real TeleportService behind the Backend shape Teleport uses. Created on first use.

local Types = require("./Types")

type Request = Types.Request
type Accepted = Types.Accepted

local function new(): Types.Backend
	local TeleportService = game:GetService("TeleportService")

	local backend = {}

	function backend.teleport(_self: any, request: Request): Accepted?
		local options = Instance.new("TeleportOptions")
		if request.serverId then
			options.ServerInstanceId = request.serverId
		end
		if request.reservedCode then
			options.ReservedServerAccessCode = request.reservedCode
		end
		if request.reserveServer then
			options.ShouldReserveServer = true
		end
		if request.data ~= nil then
			options:SetTeleportData(request.data)
		end
		local result = TeleportService:TeleportAsync(request.placeId, request.players, options)
		return {
			reservedCode = if request.reserveServer then result.ReservedServerAccessCode else request.reservedCode,
		}
	end

	function backend.onFailed(_self: any, callback: (Player, string, string) -> ()): () -> ()
		local connection = TeleportService.TeleportInitFailed:Connect(function(player: Player, result: Enum.TeleportResult, message: string)
			callback(player, result.Name, message)
		end)
		return function()
			connection:Disconnect()
		end
	end

	function backend.joinData(_self: any, player: Player): { [string]: any }?
		return player:GetJoinData()
	end

	function backend.reserve(_self: any, placeId: number): string
		local code = TeleportService:ReserveServer(placeId)
		return code
	end

	return backend :: any
end

return {
	new = new,
}
