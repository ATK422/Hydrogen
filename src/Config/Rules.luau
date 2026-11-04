--!strict

-- Feature flag rules and segments: checked and compiled once (when declared, overridden or
-- fetched), then evaluated per player with table lookups and one hash. Evaluation never yields:
-- group ranks are looked up ahead of time and passed in.

-- Who a flag is on for. With no targeting fields it is on for everyone (unless enabled = false).
-- With targeting fields it is on for a player who matches any of them.
export type FlagRule = {
	-- false turns the flag off for everyone, whatever else the rule says. Defaults to true.
	enabled: boolean?,
	-- Share of players, 0 to 100, picked by a hash of the flag's name and the UserId. The same
	-- players stay in as the share grows, on every server.
	percent: number?,
	-- These UserIds.
	users: { number }?,
	-- Members of any of these groups.
	groups: { number }?,
	-- Players in any of these segments (named in the config's segments table).
	segments: { string }?,
	-- A custom check, run on the server. It must not yield.
	when: ((player: Player) -> boolean)?,
}

-- A named group of players that flags can target. A function, or a table matched like a rule's
-- targeting: a player in users, ranked at least minRank (default 1, a member) in any of groups,
-- or passing when.
export type Segment = ((player: Player) -> boolean) | {
	users: { number }?,
	groups: { number }?,
	minRank: number?,
	when: ((player: Player) -> boolean)?,
}

export type Compiled = {
	enabled: boolean,
	everyone: boolean,
	-- Basis points: 0 to 10000.
	percent: number?,
	users: { [number]: boolean }?,
	groups: { number }?,
	minRank: number,
	segments: { string }?,
	when: ((player: Player) -> boolean)?,
}

-- What evaluation needs from the config.
export type Context = {
	-- Rank in a group, or 0 when not a member or not looked up yet.
	rank: (player: Player, groupId: number) -> number,
	segment: (player: Player, name: string) -> boolean,
	-- Runs a custom check safely; false when it errors or yields.
	check: (fn: (player: Player) -> boolean, player: Player, what: string) -> boolean,
}

local Rules = {}

local RULE_FIELDS = { enabled = true, percent = true, users = true, groups = true, segments = true, when = true }
local SEGMENT_FIELDS = { users = true, groups = true, minRank = true, when = true }

local function isArrayOf(value: any, kind: string): boolean
	if type(value) ~= "table" then
		return false
	end
	local count = 0
	for key, item in value do
		count += 1
		if type(key) ~= "number" or type(item) ~= kind then
			return false
		end
	end
	return count == #value
end

local function userSet(users: { number }): { [number]: boolean }
	local set = {}
	for _, userId in users do
		set[userId] = true
	end
	return set
end

-- Checks the targeting fields rules and segments share. Returns an error message or nil.
local function checkTargets(value: { [string]: any }, allowFunctions: boolean): string?
	if value.users ~= nil and not isArrayOf(value.users, "number") then
		return "users must be an array of UserIds"
	end
	if value.groups ~= nil and not isArrayOf(value.groups, "number") then
		return "groups must be an array of group ids"
	end
	if value.when ~= nil then
		if type(value.when) ~= "function" then
			return "when must be a function (player) -> boolean"
		elseif not allowFunctions then
			return "when can't come from a live source; declare it in code"
		end
	end
	return nil
end

-- A rule from code (allowFunctions) or from a live source or environment table. Accepts a
-- boolean as shorthand for { enabled = boolean }. Returns the compiled rule, or nil and why not.
function Rules.compile(value: any, segments: { [string]: any }, allowFunctions: boolean): (Compiled?, string?)
	if type(value) == "boolean" then
		return table.freeze({ enabled = value, everyone = true, minRank = 1 }) :: any, nil
	end
	if type(value) ~= "table" then
		return nil, `a flag must be a boolean or a rule table, got {typeof(value)}`
	end
	for key in value do
		if not RULE_FIELDS[key] then
			return nil, `unknown rule field {tostring(key)} (expected enabled, percent, users, groups, segments or when)`
		end
	end
	if value.enabled ~= nil and type(value.enabled) ~= "boolean" then
		return nil, "enabled must be a boolean"
	end
	local percent = value.percent
	if percent ~= nil and (type(percent) ~= "number" or percent ~= percent or percent < 0 or percent > 100) then
		return nil, `percent must be a number from 0 to 100, got {tostring(percent)}`
	end
	local problem = checkTargets(value, allowFunctions)
	if problem then
		return nil, problem
	end
	if value.segments ~= nil then
		if not isArrayOf(value.segments, "string") then
			return nil, "segments must be an array of segment names"
		end
		for _, name in value.segments do
			if segments[name] == nil then
				return nil, `segment {name} isn't declared in this config's segments`
			end
		end
	end

	local everyone = percent == nil and value.users == nil and value.groups == nil and value.segments == nil and value.when == nil
	return table.freeze({
		enabled = value.enabled ~= false,
		everyone = everyone,
		percent = if percent then math.floor(percent * 100 + 0.5) else nil,
		users = if value.users then userSet(value.users) else nil,
		groups = if value.groups then table.clone(value.groups) else nil,
		minRank = 1,
		segments = if value.segments then table.clone(value.segments) else nil,
		when = value.when,
	}) :: any, nil
end

function Rules.compileSegment(value: any): (Compiled?, string?)
	if type(value) == "function" then
		return table.freeze({ enabled = true, everyone = false, minRank = 1, when = value }) :: any, nil
	end
	if type(value) ~= "table" then
		return nil, `a segment must be a function or a table, got {typeof(value)}`
	end
	for key in value do
		if not SEGMENT_FIELDS[key] then
			return nil, `unknown segment field {tostring(key)} (expected users, groups, minRank or when)`
		end
	end
	local problem = checkTargets(value, true)
	if problem then
		return nil, problem
	end
	local minRank = value.minRank
	if minRank ~= nil and (type(minRank) ~= "number" or minRank < 1 or minRank > 255) then
		return nil, `minRank must be a rank from 1 to 255, got {tostring(minRank)}`
	end
	if minRank ~= nil and value.groups == nil then
		return nil, "minRank needs groups"
	end
	return table.freeze({
		enabled = true,
		everyone = false,
		users = if value.users then userSet(value.users) else nil,
		groups = if value.groups then table.clone(value.groups) else nil,
		minRank = minRank or 1,
		when = value.when,
	}) :: any, nil
end

-- FNV-1a over the flag's name and the UserId, in 0..9999. The FNV prime is 2^24 + 403, so the
-- multiply is split to stay exact in a double.
function Rules.bucket(name: string, userId: number): number
	local text = `{name}/{userId}`
	local hash = 2166136261
	for index = 1, #text do
		hash = bit32.bxor(hash, string.byte(text, index))
		hash = (bit32.lshift(hash, 24) + hash * 403) % 4294967296
	end
	return hash % 10000
end

local function inGroups(rule: Compiled, player: Player, context: Context): boolean
	local groups = rule.groups
	if not groups then
		return false
	end
	for _, groupId in groups do
		if context.rank(player, groupId) >= rule.minRank then
			return true
		end
	end
	return false
end

function Rules.matchesSegment(segment: Compiled, player: Player, name: string, context: Context): boolean
	local users = segment.users
	if users and users[player.UserId] then
		return true
	end
	if inGroups(segment, player, context) then
		return true
	end
	local when = segment.when
	return when ~= nil and context.check(when, player, `segment {name}`)
end

-- Whether flag `name` with this rule is on for the player.
function Rules.evaluate(rule: Compiled, name: string, player: Player, context: Context): boolean
	if not rule.enabled then
		return false
	end
	if rule.everyone then
		return true
	end
	local users = rule.users
	if users and users[player.UserId] then
		return true
	end
	local percent = rule.percent
	if percent and Rules.bucket(name, player.UserId) < percent then
		return true
	end
	if inGroups(rule, player, context) then
		return true
	end
	local segments = rule.segments
	if segments then
		for _, segment in segments do
			if context.segment(player, segment) then
				return true
			end
		end
	end
	local when = rule.when
	return when ~= nil and context.check(when, player, `flag {name}`)
end

-- Group ids a rule or segment looks at, added to into.
function Rules.groupsOf(rule: Compiled, into: { [number]: boolean })
	if rule.groups then
		for _, groupId in rule.groups do
			into[groupId] = true
		end
	end
end

return Rules
