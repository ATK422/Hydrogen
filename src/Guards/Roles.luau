--!strict

-- Roles and permissions. A role is a list of resolvers, and a player has the role when any of
-- them says so. Answers are cached per player for the session: the first check may yield
-- (a group rank, a game pass), later ones are a table lookup. Players who left are forgotten.

local Log = require("../Log")
local Receipts = require("../Receipts")
local Leave = require("./Leave")

-- true: has the role. false: doesn't. nil: doesn't for now, but don't cache it (ask next time).
export type Resolver = (player: Player) -> boolean?
-- A resolver, or the name of another role the player can have instead.
export type RoleSource = Resolver | string

type Role = {
	name: string,
	sources: { RoleSource },
}

type Flight = {
	thread: thread,
	waiting: { thread },
}

local Roles = {}

local roles: { [string]: Role } = {}
local permissions: { [string]: { string } } = {}

-- Player -> role -> answer. Weak as well as cleared on leave.
local cache: { [Player]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any
-- Player -> role -> the resolution in progress, which other checks wait for instead of repeating it.
local flights: { [Player]: { [string]: Flight } } = setmetatable({}, { __mode = "k" }) :: any
-- Bumped by every invalidation, so a resolution that started before one isn't cached after it.
local epoch = 0

Leave.on(function(player: Player)
	cache[player] = nil
end)

local function describe(player: Player): string
	local ok, name = pcall(function()
		return player.Name
	end)
	return if ok then tostring(name) else "a player"
end

local resolve: (player: Player, name: string) -> (boolean, boolean)

-- Runs a role's sources in order; the first yes wins. Returns (has, stable): unstable answers
-- (a resolver said nil or errored) are given but not cached.
local function run(role: Role, player: Player): (boolean, boolean)
	local stable = true
	for _, source in role.sources do
		if type(source) == "string" then
			local has, sure = resolve(player, source)
			if has then
				return true, sure
			end
			stable = stable and sure
			continue
		end

		local ok, result = xpcall(source, debug.traceback, player)
		if not ok then
			Log.warn(`[HYDROGEN] Role "{role.name}" resolver failed for {describe(player)}; treating it as not having the role: {result}`)
			stable = false
		elseif result == nil then
			stable = false
		elseif result then
			return true, true
		end
	end
	return false, stable
end

resolve = function(player: Player, name: string): (boolean, boolean)
	local known = cache[player]
	local answer = known and known[name]
	if answer ~= nil then
		return answer, true
	end

	local role = roles[name]
	if not role then
		error(`[HYDROGEN] Unknown role "{name}"; define it with Guards.defineRole("{name}", ...)`, 0)
	end

	local running = coroutine.running()
	local inFlight = flights[player]
	local flight = inFlight and inFlight[name]
	if flight then
		if flight.thread == running then
			error(`[HYDROGEN] Role "{name}" includes itself through other roles; remove the cycle`, 0)
		end
		table.insert(flight.waiting, running)
		local has, sure = coroutine.yield()
		return has == true, sure == true
	end

	if not inFlight then
		inFlight = {}
		flights[player] = inFlight
	end
	local mine: Flight = { thread = running, waiting = {} }
	inFlight[name] = mine

	local started = epoch
	local ok, has, sure = pcall(run, role, player)
	inFlight[name] = nil
	if next(inFlight) == nil and flights[player] == inFlight then
		flights[player] = nil
	end

	if not ok then
		for _, thread in mine.waiting do
			task.spawn(thread, false, false)
		end
		error(has, 0)
	end

	-- A player who left mid-check, or an invalidation that came in meanwhile, means the answer is stale.
	if sure and started == epoch and not Leave.gone(player) and roles[name] == role then
		Leave.track()
		local entry = cache[player]
		if not entry then
			entry = {}
			cache[player] = entry
		end
		entry[name] = has
	end

	for _, thread in mine.waiting do
		task.spawn(thread, has, sure)
	end
	return has, sure
end

local function checkName(kind: string, name: any, level: number)
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] {kind} name must be a non-empty string, got {typeof(name)}`, level + 1)
	end
end

-- Forgets cached answers for one player, or for everyone.
function Roles.invalidate(player: Player?)
	epoch += 1
	if player == nil then
		table.clear(cache)
	else
		cache[player] = nil
	end
end

function Roles.define(name: string, ...: RoleSource): () -> ()
	checkName("Role", name, 2)
	if roles[name] then
		error(`[HYDROGEN] Role "{name}" is already defined; define each role once at module top level, or call the function defineRole returned to remove it first`, 2)
	end

	local sources = { ... }
	if #sources == 0 then
		error(`[HYDROGEN] Role "{name}" needs at least one resolver (Guards.userIds, Guards.groupRank, Guards.gamePass, a function or another role's name)`, 2)
	end
	for index, source in sources do
		if type(source) ~= "function" and type(source) ~= "string" then
			error(`[HYDROGEN] Role "{name}" resolver {index} must be a function or a role name, got {typeof(source)}`, 2)
		end
	end

	local role: Role = { name = name, sources = sources }
	roles[name] = role
	-- Roles that include this one may answer differently now.
	Roles.invalidate()

	return function()
		if roles[name] == role then
			roles[name] = nil
			Roles.invalidate()
		end
	end
end

function Roles.definePermission(name: string, granted: { string }): () -> ()
	checkName("Permission", name, 2)
	if permissions[name] then
		error(`[HYDROGEN] Permission "{name}" is already defined; define each permission once, or call the function definePermission returned to remove it first`, 2)
	end
	if type(granted) ~= "table" or #granted == 0 then
		error(`[HYDROGEN] Permission "{name}" needs a list of role names, e.g. \{ "admin", "mod" }`, 2)
	end
	for index, role in granted do
		if type(role) ~= "string" then
			error(`[HYDROGEN] Permission "{name}" entry {index} must be a role name, got {typeof(role)}`, 2)
		end
	end

	local list = table.clone(granted)
	permissions[name] = list
	return function()
		if permissions[name] == list then
			permissions[name] = nil
		end
	end
end

function Roles.has(player: Player, name: string): boolean
	local has = resolve(player, name)
	return has
end

function Roles.can(player: Player, permission: string): boolean
	local granted = permissions[permission]
	if not granted then
		error(`[HYDROGEN] Unknown permission "{permission}"; define it with Guards.definePermission("{permission}", \{ ...roles })`, 0)
	end
	for _, role in granted do
		if resolve(player, role) then
			return true
		end
	end
	return false
end

-- Every defined role the player has, sorted by name.
function Roles.of(player: Player): { string }
	local names = {}
	for name in roles do
		table.insert(names, name)
	end
	table.sort(names)

	local held = {}
	for _, name in names do
		if roles[name] and resolve(player, name) then
			table.insert(held, name)
		end
	end
	return held
end

function Roles.exists(name: string): boolean
	return roles[name] ~= nil
end

function Roles.permissionExists(name: string): boolean
	return permissions[name] ~= nil
end

-- Resolvers.

function Roles.userIds(ids: { number }): Resolver
	if type(ids) ~= "table" then
		error(`[HYDROGEN] Guards.userIds expects a list of UserIds, got {typeof(ids)}`, 2)
	end
	local set: { [number]: boolean } = {}
	for index, id in ids do
		if type(id) ~= "number" then
			error(`[HYDROGEN] Guards.userIds entry {index} must be a UserId (number), got {typeof(id)}`, 2)
		end
		set[id] = true
	end
	return function(player: Player): boolean?
		return set[player.UserId] == true
	end
end

-- Players whose rank in the group is at least minRank (1-255; 255 is the owner).
function Roles.groupRank(groupId: number, minRank: number): Resolver
	if type(groupId) ~= "number" then
		error(`[HYDROGEN] Guards.groupRank expects a group id (number), got {typeof(groupId)}`, 2)
	end
	if type(minRank) ~= "number" or minRank < 1 or minRank > 255 then
		error(`[HYDROGEN] Guards.groupRank minRank must be a number from 1 to 255, got {tostring(minRank)}`, 2)
	end
	return function(player: Player): boolean?
		local ok, rank = pcall(function()
			return (player :: any):GetRankInGroup(groupId)
		end)
		if not ok or type(rank) ~= "number" then
			-- Roblox couldn't be reached: not this time, and ask again next time.
			Log.warn(`[HYDROGEN] Couldn't get {describe(player)}'s rank in group {groupId}: {rank}`)
			return nil
		end
		return rank >= minRank
	end
end

-- Owners of the game pass, through Hydrogen.Receipts. A "no" isn't cached here, because Receipts
-- already caches it and updates it when the pass is bought in game.
function Roles.gamePass(passId: number): Resolver
	if type(passId) ~= "number" then
		error(`[HYDROGEN] Guards.gamePass expects a game pass id (number), got {typeof(passId)}`, 2)
	end
	return function(player: Player): boolean?
		if Receipts.owns(player, passId) then
			return true
		end
		return nil
	end
end

return Roles
