--!strict

-- Why a player wasn't teleported. The first seven are Roblox's Enum.TeleportResult names, from
-- TeleportInitFailed; the rest are Hydrogen's.
export type FailReason =
	"Failure"
	| "Flooded"
	| "GameFull"
	| "GameNotFound"
	| "GameEnded"
	| "Unauthorized"
	| "IsTeleporting"
	-- TeleportAsync itself errored.
	| "Error"
	-- Roblox accepted the teleport, but the player neither left nor failed within `timeout`.
	| "TimedOut"
	-- Another Teleport.send for this player was still running.
	| "Busy"
	-- The player left the game before the teleport started, or between attempts.
	| "Left"
	-- Their Data couldn't be saved and released, so they weren't sent.
	| "DataNotSaved"
	-- The server started shutting down while they waited.
	| "ShuttingDown"

export type Failure = {
	player: Player,
	reason: FailReason,
	-- What went wrong, for logs.
	message: string,
}

export type Result = {
	-- Every player left for the destination.
	ok: boolean,
	-- Players who left this server after Roblox accepted their teleport.
	teleported: { Player },
	-- Everyone else, still here (with their data taken back) unless they left.
	failed: { Failure },
	-- TeleportAsync calls made.
	attempts: number,
	-- With reserveServer: the new reserved server's access code, to send more players there.
	reservedCode: string?,
}

export type SendOptions = {
	-- Teleport data, readable on arrival with Teleport.joinData. Tickets set it for you.
	data: any?,
	-- Join this server: its game.JobId.
	serverId: string?,
	-- Join this reserved server: a code from Teleport.reserve or an earlier result's reservedCode.
	reservedCode: string?,
	-- Put the players in a new reserved server together.
	reserveServer: boolean?,
	-- TeleportAsync attempts in all. Default 3 (Teleport.configure changes the default).
	attempts: number?,
	-- Seconds to wait, after Roblox accepts a teleport, for each player to leave. Default 30.
	timeout: number?,
}

-- One TeleportAsync call, as Hydrogen asks a TeleportBackend to make it.
export type Request = {
	placeId: number,
	players: { Player },
	serverId: string?,
	reservedCode: string?,
	reserveServer: boolean?,
	data: any?,
}

-- What a backend reports for an accepted request.
export type Accepted = {
	reservedCode: string?,
}

-- The parts of TeleportService (and Player:GetJoinData) Teleport uses, so a fake can stand in.
export type Backend = {
	-- TeleportAsync with TeleportOptions built from the request. Yields; errors when Roblox refuses.
	teleport: (self: any, request: Request) -> Accepted?,
	-- TeleportInitFailed, with the Enum.TeleportResult as its Name. Returns a disconnect function.
	onFailed: (self: any, callback: (player: Player, reason: string, message: string) -> ()) -> () -> (),
	-- player:GetJoinData().
	joinData: (self: any, player: Player) -> { [string]: any }?,
	-- TeleportService:ReserveServer(placeId): the access code. Yields.
	reserve: (self: any, placeId: number) -> string,
}

export type Config = {
	-- Stands in for TeleportService, e.g. Teleport.fakeService() in tests.
	service: Backend?,
	-- Default TeleportAsync attempts per send. Default 3.
	attempts: number?,
	-- Default seconds to wait for players to leave after an accepted teleport. Default 30.
	timeout: number?,
}

-- Typed teleport data with a name: send it from one server, read it on arrival in another.
export type Ticket<T> = {
	read name: string,
	-- Teleport.send with this ticket's value as the teleport data. Yields.
	send: (self: Ticket<T>, players: Player | { Player }, placeId: number, value: T, options: SendOptions?) -> Result,
	-- The value a player arrived with, checked against the schema; nil if they arrived without
	-- this ticket or it doesn't match. Untrusted: teleport data passes through the client.
	read: (self: Ticket<T>, player: Player) -> T?,
}

export type Connection = {
	Disconnect: (self: any) -> (),
}

return {}
