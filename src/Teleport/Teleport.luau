--!strict

-- Moves players to another place or server without losing or duplicating their data. Before
-- TeleportAsync it saves and releases every Hydrogen.Data player store the player is in, so
-- the destination's load finds no lock. Failed teleports are retried with backoff; players
-- who never leave get their data back (or, if that fails, onLoadFailed: a kick by default).

local RunService = game:GetService("RunService")

local Definition = require("../Definition")
local Network = require("../Network")
local HandOff = require("../Data/HandOff")
local Json = require("../Messaging/Json")
local Time = require("../Clock")
local Log = require("../Log")
local Types = require("./Types")
local FakeService = require("./FakeService")
local RobloxService = require("./RobloxService")

type Backend = Types.Backend
type Request = Types.Request
type Result = Types.Result
type Failure = Types.Failure
type FailReason = Types.FailReason
type SendOptions = Types.SendOptions
type Config = Types.Config

local DEFAULT_ATTEMPTS = 3
local DEFAULT_TIMEOUT = 30
-- Roblox's guidance: wait longer after Flooded (too many teleports from this server).
local FLOOD_DELAY = 15
local RESERVE_ATTEMPTS = 3
-- Worth trying again; the other reasons won't change by waiting.
local RETRYABLE: { [string]: boolean } = { Failure = true, Flooded = true, Error = true }

-- A player's current attempt: filled in by the failure callback.
type Attempt = {
	failure: { reason: string, message: string }?,
}

local options = {
	service = nil :: Backend?,
	attempts = DEFAULT_ATTEMPTS,
	timeout = DEFAULT_TIMEOUT,
}

-- Bumped by stop (shutdown): sends started before it stop retrying and waiting.
local generation = 0
-- Players a send is working on; a second send for them answers Busy.
local busy: { [Player]: true } = {}
-- Players whose attempt waits for an outcome.
local waiting: { [Player]: Attempt } = {}
local handOffListeners: { (player: Player) -> () } = {}

local robloxService: Backend? = nil
local defaultFake: Backend? = nil
local listening: Backend? = nil
local stopListening: (() -> ())? = nil

local function currentService(): Backend
	if options.service then
		return options.service
	elseif RunService:IsServer() and not Network.activeLoopback() then
		robloxService = robloxService or RobloxService.new()
		return robloxService :: Backend
	end
	-- Lune and loopback tests without a configured fake.
	defaultFake = defaultFake or FakeService.new()
	return defaultFake :: Backend
end

local function onFailed(player: Player, reason: string, message: string)
	local attempt = waiting[player]
	if attempt and not attempt.failure then
		attempt.failure = { reason = reason, message = message }
	end
end

local function listen(service: Backend)
	if listening == service then
		return
	end
	if stopListening then
		stopListening()
	end
	listening = service
	stopListening = service:onFailed(onFailed)
end

local function serverOnly(what: string)
	if RunService:IsClient() and not Network.activeLoopback() then
		error(`[HYDROGEN] {what} is server-only; fire a clientEvent and teleport from a server system`, 3)
	end
end

local function isPlayer(value: any): boolean
	return typeof(value) == "Instance" or (type(value) == "table" and type(value.UserId) == "number")
end

local function toList(players: any, what: string): { Player }
	if isPlayer(players) then
		return { players }
	end
	if type(players) ~= "table" or #players == 0 then
		error(`[HYDROGEN] {what} needs a player or a list of players, got {typeof(players)}`, 3)
	end
	for index, player in players do
		if not isPlayer(player) then
			error(`[HYDROGEN] {what}: players[{index}] is a {typeof(player)}, not a Player`, 3)
		end
	end
	return players
end

local function checkOptions(sendOptions: SendOptions, what: string)
	if type(sendOptions) ~= "table" then
		error(`[HYDROGEN] {what} options must be a table`, 3)
	end
	local targets = (if sendOptions.serverId ~= nil then 1 else 0)
		+ (if sendOptions.reservedCode ~= nil then 1 else 0)
		+ (if sendOptions.reserveServer then 1 else 0)
	if targets > 1 then
		error(`[HYDROGEN] {what}: pass only one of serverId, reservedCode and reserveServer`, 3)
	end
	if sendOptions.attempts ~= nil and (type(sendOptions.attempts) ~= "number" or sendOptions.attempts < 1) then
		error(`[HYDROGEN] {what}: attempts must be a number, at least 1`, 3)
	end
	if sendOptions.timeout ~= nil and (type(sendOptions.timeout) ~= "number" or sendOptions.timeout <= 0) then
		error(`[HYDROGEN] {what}: timeout must be a positive number of seconds`, 3)
	end
	if sendOptions.data ~= nil then
		local problem = Json.check(sendOptions.data)
		if problem then
			error(`[HYDROGEN] {what}: teleport data can't be sent: {(string.gsub(problem, "^the value", "data"))}`, 3)
		end
	end
end

-- Runs fn for every item in its own thread and waits for all of them.
local function together<T>(items: { T }, fn: (T) -> ())
	local remaining = #items
	if remaining == 0 then
		return
	end
	local caller = coroutine.running()
	local parked = false
	for _, item in items do
		task.spawn(function()
			local ok, err = xpcall(fn, debug.traceback, item)
			if not ok then
				Log.warn(`[HYDROGEN] Teleport failed internally: {err}`)
			end
			remaining -= 1
			if remaining == 0 and parked then
				task.spawn(caller)
			end
		end)
	end
	if remaining > 0 then
		parked = true
		coroutine.yield()
	end
end

local function runHandOffListeners(player: Player)
	for _, listener in table.clone(handOffListeners) do
		local ok, err = xpcall(listener, debug.traceback, player)
		if not ok then
			Log.warn(`[HYDROGEN] Teleport.onHandOff callback failed for {player.Name}: {err}`)
		end
	end
end

-- Waits seconds, or less if the server starts shutting down.
local function pause(seconds: number, stopped: () -> boolean)
	local deadline = Time.now() + seconds
	while not stopped() and Time.now() < deadline do
		Time.wait(math.min(deadline - Time.now(), 1))
	end
end

local function run(list: { Player }, placeId: number, sendOptions: SendOptions, data: any): Result
	local result: Result = { ok = false, teleported = {}, failed = {}, attempts = 0, reservedCode = nil }
	local started = generation
	local function stopped(): boolean
		return generation ~= started
	end
	local function fail(player: Player, reason: FailReason, message: string)
		table.insert(result.failed, { player = player, reason = reason, message = message })
	end

	local service = currentService()
	listen(service)

	local claimed: { Player } = {}
	local seen: { [Player]: true } = {}
	for _, player in list do
		if seen[player] then
			continue
		end
		seen[player] = true
		if busy[player] then
			fail(player, "Busy", "another Teleport.send for this player is still running")
		elseif player.Parent == nil then
			fail(player, "Left", "left the game before the teleport started")
		else
			busy[player] = true
			table.insert(claimed, player)
		end
	end

	-- Data each player handed off, until they leave or get it back.
	local held: { [Player]: HandOff.Held } = {}

	local function body()
		-- 1. Last changes, then save and release their data. Nothing is sent before every
		-- release landed, so the destination's load can't meet this server's lock.
		together(claimed, function(player: Player)
			runHandOffListeners(player)
			local released, err = HandOff.release(player)
			if released then
				held[player] = released
			else
				fail(player, "DataNotSaved", `their data couldn't be saved and released, so they weren't sent: {err}`)
			end
		end)

		local pending: { Player } = {}
		for _, player in claimed do
			if held[player] then
				if player.Parent == nil then
					fail(player, "Left", "left the game before the teleport started")
				else
					table.insert(pending, player)
				end
			end
		end

		-- 2. Teleport, retrying the players whose failure is worth retrying.
		local attempts = sendOptions.attempts or options.attempts
		local timeout = sendOptions.timeout or options.timeout
		-- Where retries go: once Roblox reserved a server for the party, retries join it.
		local target = {
			serverId = sendOptions.serverId,
			reservedCode = sendOptions.reservedCode,
			reserveServer = sendOptions.reserveServer,
		}
		local stuck: { Failure } = {}
		local attempt = 0
		while #pending > 0 do
			attempt += 1
			result.attempts = attempt

			local states: { [Player]: Attempt } = {}
			for _, player in pending do
				local state: Attempt = { failure = nil }
				states[player] = state
				waiting[player] = state
			end

			local request: Request = {
				placeId = placeId,
				players = table.clone(pending),
				serverId = target.serverId,
				reservedCode = target.reservedCode,
				reserveServer = target.reserveServer,
				data = data,
			}
			local accepted, response = pcall(service.teleport, service, request)
			local left: { [Player]: true } = {}
			if not accepted then
				local message = tostring(response)
				local reason = "Error"
				if service == robloxService and RunService:IsStudio() then
					-- Not worth retrying: Studio can't teleport.
					reason = "Unauthorized"
					message ..= " (teleports don't work in Studio play tests; test in a live server, or Teleport.configure({ service = Teleport.fakeService() }))"
				end
				for _, player in pending do
					local state = states[player]
					state.failure = state.failure or { reason = reason, message = message }
				end
			else
				local info = response :: Types.Accepted?
				if info and info.reservedCode and target.reserveServer then
					result.reservedCode = info.reservedCode
					target.reservedCode = info.reservedCode
					target.reserveServer = nil
				end
				local deadline = Time.now() + timeout
				while true do
					local undecided = false
					for _, player in pending do
						local state = states[player]
						if state.failure == nil and not left[player] then
							if player.Parent == nil then
								left[player] = true
							else
								undecided = true
							end
						end
					end
					if not undecided then
						break
					end
					local reason: FailReason? = if stopped() then "ShuttingDown" elseif Time.now() >= deadline then "TimedOut" else nil
					if reason then
						for _, player in pending do
							local state = states[player]
							if state.failure == nil and not left[player] then
								state.failure = {
									reason = reason,
									message = if reason == "TimedOut"
										then `Roblox accepted the teleport, but the player was still here after {timeout}s`
										else "the server is shutting down",
								}
							end
						end
						break
					end
					Time.wait()
				end
			end

			local retry: { Player } = {}
			local flooded = false
			for _, player in pending do
				if waiting[player] == states[player] then
					waiting[player] = nil
				end
				local failure = states[player].failure
				if left[player] or failure == nil then
					table.insert(result.teleported, player)
					held[player] = nil
				elseif RETRYABLE[failure.reason] and attempt < attempts and not stopped() then
					table.insert(retry, player)
					flooded = flooded or failure.reason == "Flooded"
				else
					table.insert(stuck, { player = player, reason = failure.reason :: any, message = failure.message })
				end
			end

			pending = retry
			if #pending > 0 then
				pause(if flooded then FLOOD_DELAY else math.min(2 ^ (attempt - 1), 8), stopped)
				local still = {}
				for _, player in pending do
					if player.Parent == nil then
						fail(player, "Left", "left the game between teleport attempts")
						held[player] = nil
					elseif stopped() then
						table.insert(stuck, { player = player, reason = "ShuttingDown", message = "the server started shutting down before the next attempt" })
					else
						table.insert(still, player)
					end
				end
				pending = still
			end
		end

		-- 3. Players who stayed get their data back.
		together(stuck, function(failure: Failure)
			local player = failure.player
			local released = held[player]
			held[player] = nil
			if released and player.Parent ~= nil then
				local ok, err = HandOff.reclaim(released)
				if not ok then
					failure.message ..= `; their data couldn't be taken back: {err}`
				end
			end
		end)
		for _, failure in stuck do
			table.insert(result.failed, failure)
		end
	end

	local ok, err = xpcall(body, debug.traceback)
	for _, player in claimed do
		busy[player] = nil
		waiting[player] = nil
	end
	if not ok then
		-- Never leave a player here without their data because of a bug.
		for player, released in held do
			if player.Parent ~= nil then
				HandOff.reclaim(released)
			end
		end
		error(err, 0)
	end

	result.ok = #result.failed == 0
	local reported = {}
	for _, failure in result.failed do
		if failure.reason ~= "Left" then
			table.insert(reported, `{failure.player.Name} ({failure.reason}: {failure.message})`)
		end
	end
	if #reported > 0 then
		Log.warn(`[HYDROGEN] Teleport to place {placeId} failed for {table.concat(reported, ", ")}`)
	end
	return result
end

local Teleport = {}

-- Sets the service (a fake in tests) and the default attempts and timeout. Call it before
-- teleporting anyone: from your main script, or a system's init.
function Teleport.configure(config: Config)
	if type(config) ~= "table" then
		error(`[HYDROGEN] Teleport.configure expects a table`, 2)
	end
	local service = config.service
	if service ~= nil then
		for _, method in { "teleport", "onFailed", "joinData", "reserve" } do
			if type((service :: any)[method]) ~= "function" then
				error(`[HYDROGEN] Teleport.configure: service is missing {method}`, 2)
			end
		end
	end
	if config.attempts ~= nil and (type(config.attempts) ~= "number" or config.attempts < 1) then
		error(`[HYDROGEN] Teleport.configure: attempts must be a number, at least 1`, 2)
	end
	if config.timeout ~= nil and (type(config.timeout) ~= "number" or config.timeout <= 0) then
		error(`[HYDROGEN] Teleport.configure: timeout must be a positive number of seconds`, 2)
	end
	options.service = service
	options.attempts = config.attempts or DEFAULT_ATTEMPTS
	options.timeout = config.timeout or DEFAULT_TIMEOUT
end

--[=[
	Teleports one player or a party to a place: saves and releases their Hydrogen.Data, calls
	TeleportAsync, retries with backoff, and takes the data back for anyone who stays. Yields
	until every player has left or failed. Server-only.

	local result = Hydrogen.Teleport.send(party, DUNGEON_PLACE, { reserveServer = true })
]=]
function Teleport.send(players: Player | { Player }, placeId: number, sendOptions: SendOptions?): Result
	serverOnly("Teleport.send")
	local list = toList(players, "Teleport.send")
	if type(placeId) ~= "number" then
		error(`[HYDROGEN] Teleport.send needs a place id (number), got {typeof(placeId)}`, 2)
	end
	local settings = sendOptions or {}
	checkOptions(settings, "Teleport.send")
	return run(list, placeId, settings, settings.data)
end

-- Runs callback(player) right before a player's data is saved and released for a teleport:
-- the last moment a change still reaches the destination (session playtime, last position).
-- It may change Data; it shouldn't yield for long. Returns a function that removes it.
function Teleport.onHandOff(callback: (player: Player) -> ()): () -> ()
	if type(callback) ~= "function" then
		error(`[HYDROGEN] Teleport.onHandOff expects a function, got {typeof(callback)}`, 2)
	end
	table.insert(handOffListeners, callback)
	return function()
		local index = table.find(handOffListeners, callback)
		if index then
			table.remove(handOffListeners, index)
		end
	end
end

-- What the player arrived with: player:GetJoinData() (TeleportData, SourcePlaceId, Members, ...).
-- Untrusted: teleport data passes through the client.
function Teleport.joinData(player: Player): { [string]: any }?
	serverOnly("Teleport.joinData")
	return currentService():joinData(player)
end

-- A new reserved server's access code, for Teleport.send(..., { reservedCode = code }).
-- Yields; retries a few times, then errors. Server-only.
function Teleport.reserve(placeId: number): string
	serverOnly("Teleport.reserve")
	if type(placeId) ~= "number" then
		error(`[HYDROGEN] Teleport.reserve needs a place id (number), got {typeof(placeId)}`, 2)
	end
	local service = currentService()
	local lastError: any = nil
	for attempt = 1, RESERVE_ATTEMPTS do
		local ok, code = pcall(service.reserve, service, placeId)
		if ok then
			return code
		end
		lastError = code
		if attempt < RESERVE_ATTEMPTS then
			pause(2 ^ (attempt - 1), function()
				return false
			end)
		end
	end
	error(`[HYDROGEN] Teleport.reserve couldn't reserve a server for place {placeId} after {RESERVE_ATTEMPTS} attempts: {lastError}`, 2)
end

--[=[
	Typed teleport data with a name. Define it in a module both places require:

	local DungeonTicket = Hydrogen.Teleport.ticket("Dungeon", gt.table({ dungeon = gt.string() }))
	DungeonTicket:send(party, DUNGEON_PLACE, { dungeon = "Crypt" })   -- sending server
	local ticket = DungeonTicket:read(player)                          -- destination server
]=]
function Teleport.ticket<T>(name: string, schema: T): Types.Ticket<T>
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] Teleport.ticket needs a name`, 2)
	end
	if type(schema) ~= "table" or type((schema :: any).matches) ~= "function" then
		error(`[HYDROGEN] Teleport.ticket {name} needs a GreenTea schema (Hydrogen.gt), got {typeof(schema)}`, 2)
	end
	local check = schema :: any

	local ticket = { name = name }

	function ticket.send(_self: any, players: Player | { Player }, placeId: number, value: T, sendOptions: SendOptions?): Result
		serverOnly("Ticket:send")
		local list = toList(players, `Ticket {name}:send`)
		if type(placeId) ~= "number" then
			error(`[HYDROGEN] Ticket {name}:send needs a place id (number), got {typeof(placeId)}`, 2)
		end
		local ok, cause = check:matches(value)
		if not ok then
			error(`[HYDROGEN] Ticket {name}:send: the value doesn't match the ticket's schema: {cause}`, 2)
		end
		local settings = sendOptions or {}
		if settings.data ~= nil then
			error(`[HYDROGEN] Ticket {name}:send sets the teleport data itself; don't pass data`, 2)
		end
		checkOptions(settings, `Ticket {name}:send`)
		local data = { ticket = name, value = value }
		local problem = Json.check(data)
		if problem then
			error(`[HYDROGEN] Ticket {name}:send: the value can't be sent: {(string.gsub(problem, "^the value", "value"))}`, 2)
		end
		return run(list, placeId, settings, data)
	end

	function ticket.read(_self: any, player: Player): T?
		serverOnly("Ticket:read")
		local joinData = currentService():joinData(player)
		local data = if type(joinData) == "table" then joinData.TeleportData else nil
		if type(data) ~= "table" or data.ticket ~= name then
			return nil
		end
		local ok, cause = check:matches(data.value)
		if not ok then
			Log.warn(`[HYDROGEN] Teleport ticket {name} for {player.Name} doesn't match its schema, so it was ignored: {cause}`)
			return nil
		end
		return data.value
	end

	return table.freeze(ticket) :: any
end

-- Stands in for TeleportService in tests; see FakeService.
Teleport.fakeService = FakeService.new

-- On shutdown: sends in progress stop retrying, and their waits end early.
function Teleport:stop()
	generation += 1
end

return Definition.define("Hydrogen.Teleport", function()
	return Teleport
end)
