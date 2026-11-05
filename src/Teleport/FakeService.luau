--!strict

local Types = require("./Types")
local Tables = require("../Data/Tables")

type Request = Types.Request
type Accepted = Types.Accepted

-- Stands in for TeleportService in tests, and plays Roblox's part: by default an accepted
-- teleport makes each player leave at once (player:Kick(), which loopback players treat as
-- leaving). Scripted failures fire the failure callback instead, as TeleportInitFailed would.
export type FakeTeleportService = Types.Backend & {
	-- Every teleport request, oldest first.
	requests: { Request },
	-- Access codes handed out by reserve and by reserveServer requests, oldest first.
	reserved: { string },
	-- The next `count` players a request names fail with TeleportInitFailed (reason default
	-- "Failure") instead of leaving.
	failNext: (self: FakeTeleportService, count: number, reason: Types.FailReason?, message: string?) -> (),
	-- The next `count` teleport calls error, as TeleportAsync does when throttled or offline.
	errorNext: (self: FakeTeleportService, count: number, message: string?) -> (),
	-- While held, accepted teleports neither complete nor fail until complete or fail is called.
	hold: (self: FakeTeleportService, held: boolean) -> (),
	-- Finishes a held teleport: the player leaves.
	complete: (self: FakeTeleportService, player: Player) -> (),
	-- Fails a held teleport now, as TeleportInitFailed would.
	fail: (self: FakeTeleportService, player: Player, reason: Types.FailReason?, message: string?) -> (),
	-- Players whose teleport is held, oldest first.
	holding: (self: FakeTeleportService) -> { Player },
	-- Sets what joinData returns for a player (player:GetJoinData()).
	setJoinData: (self: FakeTeleportService, player: Player, joinData: { [string]: any }?) -> (),
	-- Sets a player's join data to what a request would deliver: TeleportData, SourcePlaceId and
	-- Members. Default: the last request. Use it to play the destination server.
	arrive: (self: FakeTeleportService, player: Player, request: Request?) -> (),
}

local function leave(player: Player)
	local kick = (player :: any).Kick
	if type(kick) == "function" then
		kick(player, "Teleported")
	else
		(player :: any).Parent = nil
	end
end

local function new(): FakeTeleportService
	local listeners: { (Player, string, string) -> () } = {}
	local failures: { { reason: string, message: string } } = {}
	local errors: { string } = {}
	local held = false
	local heldPlayers: { Player } = {}
	local joinData: { [Player]: { [string]: any } } = setmetatable({}, { __mode = "k" }) :: any
	local codes = 0

	local fake = {
		requests = {} :: { Request },
		reserved = {} :: { string },
	}

	local function fire(player: Player, reason: string, message: string)
		for _, listener in table.clone(listeners) do
			listener(player, reason, message)
		end
	end

	local function newCode(): string
		codes += 1
		local code = `fake-reserved-{codes}`
		table.insert(fake.reserved, code)
		return code
	end

	function fake.teleport(self: any, request: Request): Accepted?
		local copy = table.clone(request)
		copy.players = table.clone(request.players)
		copy.data = Tables.copy(request.data)
		table.insert(self.requests, copy)

		local message = table.remove(errors, 1)
		if message then
			error(message, 0)
		end

		local code = if request.reserveServer then newCode() else request.reservedCode
		for _, player in table.clone(request.players) do
			local failure = table.remove(failures, 1)
			if failure then
				fire(player, failure.reason, failure.message)
			elseif held then
				table.insert(heldPlayers, player)
			else
				leave(player)
			end
		end
		return { reservedCode = code }
	end

	function fake.onFailed(_self: any, callback: (Player, string, string) -> ()): () -> ()
		table.insert(listeners, callback)
		return function()
			local index = table.find(listeners, callback)
			if index then
				table.remove(listeners, index)
			end
		end
	end

	function fake.joinData(_self: any, player: Player): { [string]: any }?
		return joinData[player]
	end

	function fake.reserve(_self: any, _placeId: number): string
		local message = table.remove(errors, 1)
		if message then
			error(message, 0)
		end
		return newCode()
	end

	function fake.failNext(_self: any, count: number, reason: Types.FailReason?, message: string?)
		for _ = 1, count do
			local why = reason or "Failure"
			table.insert(failures, { reason = why, message = message or `fake teleport failure ({why})` })
		end
	end

	function fake.errorNext(_self: any, count: number, message: string?)
		for _ = 1, count do
			table.insert(errors, message or "fake TeleportAsync error")
		end
	end

	function fake.hold(_self: any, value: boolean)
		held = value
	end

	function fake.complete(_self: any, player: Player)
		local index = table.find(heldPlayers, player)
		if not index then
			error(`[HYDROGEN] fakeService: {player.Name} has no held teleport to complete`, 2)
		end
		table.remove(heldPlayers, index)
		leave(player)
	end

	function fake.fail(_self: any, player: Player, reason: Types.FailReason?, message: string?)
		local index = table.find(heldPlayers, player)
		if not index then
			error(`[HYDROGEN] fakeService: {player.Name} has no held teleport to fail`, 2)
		end
		table.remove(heldPlayers, index)
		local why = reason or "Failure"
		fire(player, why, message or `fake teleport failure ({why})`)
	end

	function fake.holding(_self: any): { Player }
		return table.clone(heldPlayers)
	end

	function fake.setJoinData(_self: any, player: Player, data: { [string]: any }?)
		joinData[player] = data
	end

	function fake.arrive(self: any, player: Player, request: Request?)
		local from = request or self.requests[#self.requests]
		if not from then
			error("[HYDROGEN] fakeService:arrive needs a request; teleport someone first, or pass one", 2)
		end
		local members = {}
		for _, member in from.players do
			table.insert(members, member.UserId)
		end
		joinData[player] = {
			SourcePlaceId = 0,
			SourceGameId = 0,
			Members = members,
			-- Teleport data is serialized on the way, so the destination gets a copy.
			TeleportData = Tables.copy(from.data),
		}
	end

	return fake :: any
end

return {
	new = new,
}
