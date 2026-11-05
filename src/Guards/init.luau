--!strict

-- Server-side game rules for incoming network traffic: cooldowns, roles and permissions, range
-- checks and custom predicates. Each guard is a middleware: attach it with :Use, :UseRequest or
-- Hydrogen.useMiddleware. A rejected event is dropped; a rejected function request errors back
-- to the client with the reason. Cooldowns and roles can also be used directly from game code.

local Clock = require("./Clock")
local Cooldown = require("@self/Cooldown")
local Guard = require("@self/Guard")
local Log = require("./Log")
local Ping = require("@self/Ping")
local Range = require("@self/Range")
local Roles = require("@self/Roles")

export type Guard = Guard.Guard
export type GuardOptions = Guard.GuardOptions
export type RejectHook = Guard.RejectHook
export type Cooldown = Cooldown.Cooldown
export type CooldownOptions = Cooldown.CooldownOptions
export type Resolver = Roles.Resolver
export type RoleSource = Roles.RoleSource
export type Predicate = (player: Player, ...any) -> (boolean, string?)

export type RangeOptions = GuardOptions & {
	-- Which argument holds the target. Defaults to 1.
	arg: number?,
	-- Picks the target from the arguments instead of arg, e.g. a part inside a table.
	target: ((player: Player, ...any) -> any)?,
	-- Extra studs allowed for latency. Defaults to Guards.configure's slack (4).
	slack: number?,
}

export type TimestampOptions = GuardOptions & {
	-- Which argument holds the client's Clock.serverNow() stamp. Defaults to 1.
	arg: number?,
	-- Picks the stamp from the arguments instead of arg, e.g. a field of a table.
	timestamp: ((player: Player, ...any) -> any)?,
	-- Seconds a stamp may be older than the player's ping. Defaults to 0.2.
	tolerance: number?,
	-- Pings above this count as this, so a lagging (or lag-switching) client can't widen the
	-- window further. Defaults to Guards.configure's maxPing (1 second).
	maxPing: number?,
	-- Seconds a stamp may be ahead of the server's clock, for the client's estimate of it. Defaults to 0.05.
	future: number?,
}

export type ConfigureOptions = {
	-- Where a player's character is, for range checks. Defaults to the HumanoidRootPart, or the
	-- character's PrimaryPart. Return nil when there's no character.
	position: ((player: Player) -> Vector3?)?,
	-- Default slack for range checks, in studs.
	slack: number?,
	-- A player's latency in seconds, for timestamp checks. Defaults to Player:GetNetworkPing().
	ping: ((player: Player) -> number?)?,
	-- Default cap on the ping timestamp checks allow for, in seconds.
	maxPing: number?,
}

local Guards = {}

local function checkOptions(options: any, caller: string)
	if options ~= nil and type(options) ~= "table" then
		error(`[HYDROGEN] {caller} options must be a table, got {typeof(options)}`, 3)
	end
end

-- Cooldowns.

-- A per-player cooldown. Use it as a guard (cooldown:guard()) or from game code (ready, use, remaining).
function Guards.cooldown(seconds: number, options: CooldownOptions?): Cooldown
	checkOptions(options, "Guards.cooldown")
	return Cooldown.new(seconds, options)
end

-- Roles and permissions.

-- Defines a role: a player has it when any source says so. Returns a function that removes it.
Guards.defineRole = Roles.define
-- Defines a permission held by players with any of the roles. Returns a function that removes it.
Guards.definePermission = Roles.definePermission
-- Whether the player has the role. Yields the first time per player and role, then cached.
Guards.hasRole = Roles.has
-- Whether the player has the permission (any of its roles).
Guards.can = Roles.can
-- Every defined role the player has, sorted. Yields like hasRole.
Guards.rolesOf = Roles.of
-- Forgets cached role answers for one player, or for everyone.
Guards.invalidate = Roles.invalidate

Guards.userIds = Roles.userIds
Guards.groupRank = Roles.groupRank
Guards.gamePass = Roles.gamePass

-- Drops messages from players without the role.
function Guards.role(name: string, options: GuardOptions?): Guard
	if type(name) ~= "string" then
		error(`[HYDROGEN] Guards.role expects a role name, got {typeof(name)}`, 2)
	end
	checkOptions(options, "Guards.role")
	return Guard.build({
		check = function(player: Player): (string?, Guard.Spec?)
			if Roles.has(player, name) then
				return nil, nil
			end
			return `missing role "{name}"`, nil
		end,
		options = options,
	})
end

-- Drops messages from players without the permission.
function Guards.permission(name: string, options: GuardOptions?): Guard
	if type(name) ~= "string" then
		error(`[HYDROGEN] Guards.permission expects a permission name, got {typeof(name)}`, 2)
	end
	checkOptions(options, "Guards.permission")
	return Guard.build({
		check = function(player: Player): (string?, Guard.Spec?)
			if Roles.can(player, name) then
				return nil, nil
			end
			return `missing permission "{name}"`, nil
		end,
		options = options,
	})
end

-- Range checks.

-- Drops messages whose target is more than studs (plus slack) from the sender's character.
function Guards.range(studs: number, options: RangeOptions?): Guard
	if type(studs) ~= "number" or not (studs >= 0) then
		error(`[HYDROGEN] Guards.range expects a non-negative number of studs, got {tostring(studs)}`, 2)
	end
	checkOptions(options, "Guards.range")
	local arg = (options and options.arg) or 1
	local pick = options and options.target
	local slack = options and options.slack
	if type(arg) ~= "number" or arg < 1 or arg % 1 ~= 0 then
		error(`[HYDROGEN] Guards.range arg must be an argument position (1, 2, ...), got {tostring(arg)}`, 2)
	end
	if slack ~= nil and (type(slack) ~= "number" or not (slack >= 0)) then
		error(`[HYDROGEN] Guards.range slack must be a non-negative number of studs, got {tostring(slack)}`, 2)
	end

	return Guard.build({
		check = function(player: Player, context: Guard.Context, ...: any): (string?, Guard.Spec?)
			local target
			if pick then
				local ok, result = xpcall(pick, debug.traceback, player, ...)
				if not ok then
					Log.warn(`[HYDROGEN] Guards.range target function failed on {context.name}: {result}`)
					return "invalid target", nil
				end
				target = result
			else
				target = select(arg, ...)
			end

			local distance, problem = Range.distance(player, target)
			if not distance then
				return problem :: string, nil
			end
			local limit = studs + (slack or Range.slack)
			if distance <= limit then
				return nil, nil
			end
			return `target out of range ({string.format("%.1f", distance)} studs, at most {studs})`, nil
		end,
		options = options,
	})
end

-- Whether the target is within studs (plus slack) of the player's character. False without a
-- character or with a target that isn't a position, part, model, attachment or player.
function Guards.inRange(player: Player, target: any, studs: number, slack: number?): boolean
	local distance = Range.distance(player, target)
	return distance ~= nil and distance <= studs + (slack or Range.slack)
end

-- Studs from the player's character to the target, or nil and why not ("no character", "invalid target").
function Guards.distance(player: Player, target: any): (number?, string?)
	return Range.distance(player, target)
end

-- Timestamp checks.

local function seconds(value: number): string
	return string.format("%.2f", value)
end

local function nonNegative(value: any): boolean
	return type(value) == "number" and value >= 0 and value < math.huge
end

-- Drops messages whose Clock.serverNow() stamp is from the future, or older than the sender's
-- ping (at most maxPing) plus tolerance, so a client can't backdate an action.
function Guards.timestamp(options: TimestampOptions?): Guard
	checkOptions(options, "Guards.timestamp")
	local arg = (options and options.arg) or 1
	local pick = options and options.timestamp
	local tolerance = if options and options.tolerance ~= nil then options.tolerance else 0.2
	local maxPing = options and options.maxPing
	local future = if options and options.future ~= nil then options.future else 0.05
	if type(arg) ~= "number" or arg < 1 or arg % 1 ~= 0 then
		error(`[HYDROGEN] Guards.timestamp arg must be an argument position (1, 2, ...), got {tostring(arg)}`, 2)
	end
	if pick ~= nil and type(pick) ~= "function" then
		error(`[HYDROGEN] Guards.timestamp timestamp must be a function (player, ...args) -> number, got {typeof(pick)}`, 2)
	end
	if not nonNegative(tolerance) then
		error(`[HYDROGEN] Guards.timestamp tolerance must be a non-negative number of seconds, got {tostring(tolerance)}`, 2)
	end
	if maxPing ~= nil and not nonNegative(maxPing) then
		error(`[HYDROGEN] Guards.timestamp maxPing must be a non-negative number of seconds, got {tostring(maxPing)}`, 2)
	end
	if not nonNegative(future) then
		error(`[HYDROGEN] Guards.timestamp future must be a non-negative number of seconds, got {tostring(future)}`, 2)
	end

	return Guard.build({
		check = function(player: Player, context: Guard.Context, ...: any): (string?, Guard.Spec?)
			local stamp
			if pick then
				local ok, result = xpcall(pick, debug.traceback, player, ...)
				if not ok then
					Log.warn(`[HYDROGEN] Guards.timestamp timestamp function failed on {context.name}: {result}`)
					return "invalid timestamp", nil
				end
				stamp = result
			else
				stamp = select(arg, ...)
			end
			-- NaN fails both comparisons; so do infinities, through the bounds.
			if type(stamp) ~= "number" or not (stamp > -math.huge and stamp < math.huge) then
				return "invalid timestamp", nil
			end

			local age = Clock.serverNow() - stamp
			if age < -future then
				return `timestamp from the future ({seconds(-age)}s ahead)`, nil
			end
			local limit = math.min(Ping.of(player), maxPing or Ping.maxPing) + tolerance
			if age > limit then
				return `timestamp too old ({seconds(age)}s, at most {seconds(limit)}s)`, nil
			end
			return nil, nil
		end,
		options = options,
	})
end

-- The player's network latency in seconds (Player:GetNetworkPing(), or Guards.configure's ping),
-- 0 when unknown.
function Guards.ping(player: Player): number
	return Ping.of(player)
end

-- Custom predicates.

-- A guard from a function: return true to let the message through, or false and a reason.
-- It gets the raw, unvalidated arguments. An error counts as a rejection and is warned.
function Guards.check(predicate: Predicate, options: GuardOptions?): Guard
	if type(predicate) ~= "function" then
		error(`[HYDROGEN] Guards.check expects a function, got {typeof(predicate)}`, 2)
	end
	checkOptions(options, "Guards.check")
	return Guard.build({
		check = function(player: Player, context: Guard.Context, ...: any): (string?, Guard.Spec?)
			local ok, passed, reason = xpcall(predicate, debug.traceback, player, ...)
			if not ok then
				Log.warn(`[HYDROGEN] Guards.check predicate failed on {context.name}; rejecting: {passed}`)
				return "not allowed", nil
			end
			if passed == true then
				return nil, nil
			end
			return if type(reason) == "string" then reason else "not allowed", nil
		end,
		options = options,
	})
end

-- Combinators.

-- Passes when every guard passes, checked in order. Cooldowns are only used once all of them
-- pass, so a failed role check doesn't cost a charge.
function Guards.all(...: Guard): Guard
	if select("#", ...) == 0 then
		error(`[HYDROGEN] Guards.all needs at least one guard`, 2)
	end
	local children: { Guard.Spec } = {}
	local uses: { Guard.Usable } = {}
	local seen: { [any]: boolean } = {}
	for index = 1, select("#", ...) do
		local child = Guard.spec((select(index, ...)), "Guards.all", index)
		table.insert(children, child)
		for _, usable in child.uses or {} do
			if not seen[usable] then
				seen[usable] = true
				table.insert(uses, usable)
			end
		end
	end

	local count = #children
	return Guard.build({
		check = function(player: Player, context: Guard.Context, ...: any): (string?, Guard.Spec?)
			for index = 1, count do
				local reason, failed = Guard.check(children[index], player, context, ...)
				if reason then
					return reason, failed
				end
			end
			return nil, nil
		end,
		uses = if #uses > 0 then uses else nil,
	})
end

-- Passes when any guard passes, tried in order; only that guard's cooldowns are used. When all
-- fail, the last one's reason is sent (and its onReject runs).
function Guards.any(...: Guard): Guard
	local children: { Guard.Spec } = {}
	for index = 1, select("#", ...) do
		table.insert(children, Guard.spec((select(index, ...)), "Guards.any", index))
	end
	if #children == 0 then
		error(`[HYDROGEN] Guards.any needs at least one guard`, 2)
	end

	local count = #children
	return Guard.build({
		check = function(player: Player, context: Guard.Context, ...: any): (string?, Guard.Spec?)
			local lastReason, lastFailed
			for index = 1, count do
				local reason, failed = Guard.evaluate(children[index], player, context, ...)
				if reason == nil then
					return nil, nil
				end
				lastReason, lastFailed = reason, failed
			end
			return lastReason, lastFailed
		end,
	})
end

-- Hooks and configuration.

-- Runs for every message any guard rejects, after that guard's own onReject. Returns a function that removes it.
Guards.onReject = Guard.onReject

-- Whether a value is a guard made by Hydrogen.Guards.
Guards.isGuard = Guard.isGuard

-- Changes how range checks find characters and how much slack they allow by default, and where
-- timestamp checks read a player's ping.
function Guards.configure(options: ConfigureOptions)
	if type(options) ~= "table" then
		error(`[HYDROGEN] Guards.configure expects a table, got {typeof(options)}`, 2)
	end
	if options.position ~= nil and type(options.position) ~= "function" then
		error(`[HYDROGEN] Guards.configure position must be a function (player) -> Vector3?, got {typeof(options.position)}`, 2)
	end
	if options.slack ~= nil and (type(options.slack) ~= "number" or not (options.slack >= 0)) then
		error(`[HYDROGEN] Guards.configure slack must be a non-negative number of studs, got {tostring(options.slack)}`, 2)
	end
	if options.ping ~= nil and type(options.ping) ~= "function" then
		error(`[HYDROGEN] Guards.configure ping must be a function (player) -> number?, got {typeof(options.ping)}`, 2)
	end
	if options.maxPing ~= nil and not nonNegative(options.maxPing) then
		error(`[HYDROGEN] Guards.configure maxPing must be a non-negative number of seconds, got {tostring(options.maxPing)}`, 2)
	end
	-- A key that's present replaces the setting; position = nil can't be told apart, so reset() restores defaults.
	if options.position then
		Range.position = options.position
	end
	if options.slack then
		Range.slack = options.slack
	end
	if options.ping then
		Ping.source = options.ping
	end
	if options.maxPing then
		Ping.maxPing = options.maxPing
	end
end

-- Puts configure's settings back to the defaults (for tests).
function Guards.resetConfiguration()
	Range.position = nil
	Range.slack = 4
	Ping.source = nil
	Ping.maxPing = 1
end

return Guards
