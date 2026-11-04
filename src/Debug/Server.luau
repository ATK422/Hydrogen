--!strict

-- The server's side of the overlay: who may see server data, and the read-only view it sends.

local RunService = game:GetService("RunService")

local Format = require("./Format")
local Stats = require("./Stats")
local Log = require("../Log")
local Runtime = require("../Network/Runtime")
local StateStore = require("../State/Store")

export type Row = { name: string, value: string }

export type BootSystem = { name: string, init: number, start: number }

-- Milliseconds, as App.new({ debug = true }) reports them.
export type BootReport = {
	total: number,
	network: number,
	systems: { BootSystem },
}

export type Warning = {
	text: string,
	-- Clock.time() when it was printed.
	at: number,
}

export type PlayerView = {
	userId: number,
	name: string,
	-- Every per-player Hydrogen.State for this player.
	state: { Row },
	-- Each inspected Data store or PlayerState that has data for this player, by its name.
	data: { { name: string, fields: { Row } } },
}

export type View = {
	stats: { [string]: Stats.NetStat },
	warnings: { Warning },
	boot: BootReport?,
	-- Every global Hydrogen.State.
	state: { Row },
	players: { { userId: number, name: string } },
	player: PlayerView?,
}

-- Anything with a name and find(player), such as Hydrogen.Data.player stores and PlayerStates.
export type Inspectable = {
	name: string,
	find: (self: any, player: Player) -> any,
}

local Server = {}

local function isCreator(player: Player): boolean
	local ok, result = pcall(function()
		return game.CreatorType == Enum.CreatorType.User and game.CreatorId == player.UserId
	end)
	return ok and result == true
end

-- Studio, the owner of a game owned by a user, or a UserId in users.
function Server.defaultAuthorize(player: Player, users: { number }): boolean
	if RunService:IsStudio() then
		return true
	end
	return table.find(users, player.UserId) ~= nil or isCreator(player)
end

-- A check that errors denies, so a broken authorize never opens server data.
function Server.authorized(player: Player, authorize: (Player) -> boolean): boolean
	local ok, result = pcall(authorize, player)
	if not ok then
		Log.warn(`[HYDROGEN] Debug authorize failed for {player.Name}, so they were denied: {result}`)
		return false
	end
	return result == true
end

local function stateRows(player: Player?): { Row }
	local rows = {}
	for _, state in StateStore.states do
		if state.perPlayer ~= (player ~= nil) then
			continue
		end
		local item = state :: any
		local ok, result = pcall(function()
			if item.all then
				return if player then item:all(player) else item:all()
			end
			return if player then item:get(player) else item:get()
		end)
		table.insert(rows, { name = state.name, value = if ok then Format.value(result) else `<error: {result}>` })
	end
	table.sort(rows, function(a, b)
		return a.name < b.name
	end)
	return rows
end

local function findPlayer(userId: number): Player?
	for _, player in Runtime:getPlayers() do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end

local function playerView(player: Player, inspect: { Inspectable }): PlayerView
	local data = {}
	for _, item in inspect do
		local ok, found = pcall(item.find, item, player)
		if not ok then
			table.insert(data, { name = item.name, fields = { { name = "error", value = tostring(found) } } })
		elseif found ~= nil then
			table.insert(data, { name = item.name, fields = Format.fields(found) })
		end
	end
	return {
		userId = player.UserId,
		name = player.Name,
		state = stateRows(player),
		data = data,
	}
end

function Server.view(userId: number?, inspect: { Inspectable }, warnings: { Warning }, boot: BootReport?): View
	local players = {}
	for _, player in Runtime:getPlayers() do
		table.insert(players, { userId = player.UserId, name = player.Name })
	end
	table.sort(players, function(a, b)
		return a.name < b.name
	end)

	local target = if userId then findPlayer(userId) else nil
	return {
		stats = Stats.snapshot(),
		warnings = table.clone(warnings),
		boot = boot,
		state = stateRows(nil),
		players = players,
		player = if target then playerView(target, inspect) else nil,
	}
end

return Server
