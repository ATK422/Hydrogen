--!strict

-- Config.define: typed values with per-environment overrides, feature flags evaluated per player,
-- and optional live values from a remote source. A definition is a system: added to the app on
-- the server, it replicates shared values and each player's flags through Hydrogen.State,
-- evaluates flags on join and keeps the live source refreshed.
--
-- Each name resolves through layers, highest first: override (code), live source, place,
-- environment kind, then the declared default (values) or rule (flags).

local gt = require("../../roblox_packages/gt")
local Clock = require("../Clock")
local Definition = require("../Definition")
local Log = require("../Log")
local Runtime = require("../Network/Runtime")
local State = require("../State")
local Environment = require("./Environment")
local Rules = require("./Rules")
local Sources = require("./Sources")

type Source = Sources.Source
type Compiled = Rules.Compiled

export type FlagRule = Rules.FlagRule
export type Segment = Rules.Segment

-- Values or flag rules for one environment, by name.
export type Overrides = { [string]: any }

export type Environments = {
	studio: Overrides?,
	private: Overrides?,
	reserved: Overrides?,
	live: Overrides?,
	-- By place id, applied on top of the environment kind.
	places: { [number]: Overrides }?,
}

export type Spec<V, F> = {
	-- Config.value(schema, default) (server only) or Config.shared(schema, default) per name.
	values: V?,
	-- Config.flag(rule) per name.
	flags: F?,
	segments: { [string]: Segment }?,
	environments: Environments?,
	-- Where live values come from. Off unless given.
	source: Source?,
	-- Seconds between live source fetches. Defaults to 60.
	refresh: number?,
}

export type Flag = {
	read name: string,
	-- On the server, evaluates the flag for the player (once, then cached until a rule or the
	-- player's groups change). On a client, whether the server said it is on for that player;
	-- clients only hear about their own flags.
	enabled: (self: Flag, player: Player) -> boolean,
	-- Calls observer with whether the flag is on for the player now, then on every change.
	-- Returns a function that stops it.
	observe: (self: Flag, player: Player, observer: (enabled: boolean) -> ()) -> () -> (),
}

export type Config<V, F> = {
	read name: string,
	-- Plain table lookups: GameConfig.values.RoundLength. Updated in place when a value changes.
	read values: V,
	read flags: F,
	-- Calls observer with the value now, then on every change. Returns a function that stops it.
	observe: (self: Config<V, F>, name: string, observer: (value: any, previous: any) -> ()) -> () -> (),
	-- Server: sets values or flag rules from code, above every other layer. Checked like a
	-- declaration; errors at your line when invalid.
	override: (self: Config<V, F>, overrides: Overrides) -> (),
	-- Server: removes these overrides, or every override.
	clearOverrides: (self: Config<V, F>, names: { string }?) -> (),
	-- Server: fetches from the live source now. Yields. Returns whether the fetch worked.
	refresh: (self: Config<V, F>) -> boolean,
	-- The shared values this client received (inside t:as under loopback). For tests.
	replica: (self: Config<V, F>) -> { [string]: any },
}

type Decl = {
	kind: "value",
	schema: any,
	default: any,
	shared: boolean,
	check: any,
}

type FlagObject = {
	kind: "flag",
	name: string,
	rule: any,
	config: Internal?,
}

type Observer = (...any) -> ()

type Internal = {
	name: string,
	values: { [string]: any },
	-- The public flags table errors on unknown names, so lookups inside go through flagObjects.
	flags: { [string]: FlagObject },
	flagObjects: { [string]: FlagObject },

	decls: { [string]: Decl },
	-- Every value and flag name, sorted: what the live source is asked for.
	names: { string },
	segments: { [string]: Compiled },
	baseRules: { [string]: Compiled },
	kinds: { [string]: Overrides },
	places: { [number]: Overrides },
	env: Overrides,
	remote: Overrides,
	-- What the source last sent that was accepted, to skip re-checking unchanged values.
	remoteRaw: Overrides,
	overridden: Overrides,
	rules: { [string]: Compiled },
	context: Rules.Context,

	observers: { [string]: { Observer } },
	results: { [Player]: { [string]: boolean } },
	flagObservers: { [Player]: { [string]: { Observer } } },
	ranks: { [Player]: { [number]: number } },
	groupIds: { number },

	shared: State.Map<string, any>?,
	flagState: State.PlayerMap<string, boolean>?,
	-- The app is running this config on the server, so changes are written to State.
	synced: boolean,

	source: Source?,
	refreshEvery: number,
	running: boolean,
	timer: thread?,
	unsubscribe: (() -> ())?,
	fetches: number,
	applied: number,
	warned: { [string]: string },
}

-- How long start waits for the first live fetch, and playerAdded for group ranks, before going
-- on without them. Late results still apply when they arrive.
local FIRST_FETCH_TIMEOUT = 5
local GROUP_TIMEOUT = 5
local DEFAULT_REFRESH = 60

local MARK = {}

local SPEC_FIELDS = { values = true, flags = true, segments = true, environments = true, source = true, refresh = true }

local configs: { Internal } = {}
local byName: { [string]: Internal } = {}
local flagsByName: { [string]: FlagObject } = {}

local Define = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local side: "server" | "client" | "none" | nil = nil

-- A real client (not a loopback test, not a server).
local function realClient(): boolean
	if Runtime.Loopback then
		return false
	end
	if not side then
		local RunService = game:GetService("RunService")
		side = if RunService:IsServer() then "server" elseif RunService:IsClient() then "client" else "none"
	end
	return side == "client"
end

-- Code running as a client: a real client, or a fake one inside loopback:as.
local function clientContext(): boolean
	local loopback = Runtime.Loopback
	if loopback then
		return loopback:client() ~= nil
	end
	return realClient()
end

local function isPlayer(value: any): boolean
	if typeof(value) == "Instance" then
		return value.ClassName == "Player"
	end
	return type(value) == "table" and type(value.UserId) == "number"
end

local function freezeCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in value do
		copy[freezeCopy(key)] = freezeCopy(item)
	end
	return table.freeze(copy)
end

local function equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

local function warnOnce(config: Internal, key: string, message: string)
	if config.warned[key] ~= message then
		config.warned[key] = message
		Log.warn(message)
	end
end

local function call(what: string, observer: Observer, ...: any)
	local ok, err = xpcall(observer, debug.traceback, ...)
	if not ok then
		Log.warn(`[HYDROGEN] Observer of {what} failed: {err}`)
	end
end

-- Each observer in its own thread, so one that yields or errors doesn't hold up the rest.
local function notify(what: string, observers: { Observer }?, ...: any)
	if not observers then
		return
	end
	for _, observer in table.clone(observers) do
		task.spawn(call, what, observer, ...)
	end
end

local function remove(list: { Observer }, observer: Observer)
	local index = table.find(list, observer)
	if index then
		table.remove(list, index)
	end
end

-- Runs work in a new thread and waits for it, at most `seconds` on Hydrogen.Clock.
local function waitFor(seconds: number, work: () -> ())
	local finished = false
	local timedOut = false
	local waiter: thread? = nil

	task.spawn(function()
		pcall(work)
		finished = true
		if waiter then
			local thread = waiter
			waiter = nil
			task.spawn(thread)
		end
	end)
	if finished then
		return
	end

	waiter = coroutine.running()
	local timer = Clock.delay(seconds, function()
		timedOut = true
		if waiter then
			local thread = waiter
			waiter = nil
			task.spawn(thread)
		end
	end)
	coroutine.yield()
	if not timedOut then
		Clock.cancel(timer)
	end
end

--------------------------------------------------------------------------------
-- Checking names and values
--------------------------------------------------------------------------------

local function describe(config: Internal): string
	return `Config {config.name}`
end

-- A value or flag rule for one name, checked. Returns what the layer stores, or nil and why not.
local function accept(config: Internal, name: string, value: any, allowFunctions: boolean): (any, string?)
	local decl = config.decls[name]
	if decl then
		local ok, cause = decl.check:matches(value)
		if not ok then
			return nil, `doesn't match the schema: {cause:formatErr()}`
		end
		return freezeCopy(value), nil
	end
	if config.flagObjects[name] then
		local rule, problem = Rules.compile(value, config.segments, allowFunctions)
		if not rule then
			return nil, problem
		end
		return rule, nil
	end
	return nil, "isn't a declared value or flag"
end

-- An overrides table from code, checked whole. Errors with a plain message.
local function acceptAll(config: Internal, where: string, overrides: any): Overrides
	if type(overrides) ~= "table" then
		error(`[HYDROGEN] {describe(config)}: {where} must be a table of name = value, got {typeof(overrides)}`, 0)
	end
	local layer = {}
	for name, value in overrides do
		if type(name) ~= "string" then
			error(`[HYDROGEN] {describe(config)}: {where} has a non-string key {tostring(name)}`, 0)
		end
		local accepted, problem = accept(config, name, value, true)
		if problem then
			error(`[HYDROGEN] {describe(config)}: {where} sets {name}, which {problem}`, 0)
		end
		layer[name] = accepted
	end
	return layer
end

--------------------------------------------------------------------------------
-- Resolving
--------------------------------------------------------------------------------

local function layered(config: Internal, name: string): any
	local value = config.overridden[name]
	if value ~= nil then
		return value
	end
	value = config.remote[name]
	if value ~= nil then
		return value
	end
	return config.env[name]
end

local function computeEnv(config: Internal)
	local environment = Environment.current()
	local env: Overrides = table.clone(config.kinds[environment.kind] or {})
	local place: Overrides = config.places[environment.placeId] or {}
	for name, value in place do
		env[name] = value
	end
	config.env = env
end

-- Defined with the group lookups below.
local lookUpNewGroups: (config: Internal, changed: { [string]: boolean }, players: { Player }) -> ()

-- Writes this player's flags to State, as the set of flags that are on.
local function syncFlags(config: Internal, player: Player)
	local flagState = config.flagState
	local results = config.results[player]
	if not (config.synced and flagState and results) then
		return
	end
	local on = {}
	for name, enabled in results do
		if enabled then
			on[name] = true
		end
	end
	flagState:replace(player, on)
end

-- Evaluates flags for a player (all of them, or only `names`), notifying what changed.
local function evaluate(config: Internal, player: Player, names: { [string]: boolean }?): { [string]: boolean }
	local previous = config.results[player]
	local results: { [string]: boolean } = if previous then table.clone(previous) else {}
	for name in config.flagObjects do
		if names == nil or names[name] then
			results[name] = Rules.evaluate(config.rules[name], name, player, config.context)
		end
	end
	config.results[player] = results

	local observers = config.flagObservers[player]
	if previous and observers then
		for name, enabled in results do
			if previous[name] ~= enabled then
				notify(`flag {name}`, observers[name], enabled)
			end
		end
	end
	syncFlags(config, player)
	return results
end

-- Brings values and flag rules up to date with the layers, notifying what changed.
local function recompute(config: Internal)
	local values = config.values
	for name, decl in config.decls do
		local value = layered(config, name)
		if value == nil then
			value = decl.default
		end
		local previous = rawget(values, name)
		if not equal(previous, value) then
			rawset(values, name, value)
			if config.synced and decl.shared and config.shared then
				config.shared:set(name, value)
			end
			notify(`Config {config.name}.{name}`, config.observers[name], value, previous)
		end
	end

	local changed: { [string]: boolean } = {}
	local any = false
	for name in config.flagObjects do
		local rule = layered(config, name) or config.baseRules[name]
		if config.rules[name] ~= rule then
			config.rules[name] = rule
			changed[name] = true
			any = true
		end
	end
	if any then
		local players = {}
		for player in config.results do
			table.insert(players, player)
		end
		for _, player in players do
			evaluate(config, player, changed)
		end
		lookUpNewGroups(config, changed, players)
	end
end

--------------------------------------------------------------------------------
-- Groups and custom checks
--------------------------------------------------------------------------------

local function groupRank(player: Player, groupId: number): number
	local method = (player :: any).GetRankInGroup
	if typeof(player) ~= "Instance" and type(method) ~= "function" then
		-- A test's fake player; give it a GetRankInGroup method to test group rules.
		return 0
	end
	return (player :: any):GetRankInGroup(groupId)
end

-- Looks every group up at once and returns when all of them have answered.
local function lookUpRanks(config: Internal, player: Player, groupIds: { number })
	local remaining = #groupIds
	local waiter: thread? = nil
	for _, groupId in groupIds do
		task.spawn(function()
			local ok, rank = pcall(groupRank, player, groupId)
			local ranks = config.ranks[player]
			-- No ranks table: the player left while we looked.
			if ranks then
				if ok and type(rank) == "number" then
					ranks[groupId] = rank
				else
					Log.warn(`[HYDROGEN] {describe(config)}: could not look up {player.Name}'s rank in group {groupId}: {rank}; group rules treat them as outside it`)
					ranks[groupId] = 0
				end
			end
			remaining -= 1
			if remaining == 0 and waiter then
				local thread = waiter
				waiter = nil
				task.spawn(thread)
			end
		end)
	end
	if remaining > 0 then
		waiter = coroutine.running()
		coroutine.yield()
	end
end

-- A rule from an override or the live source can name groups no rule named at join: look those
-- up for the players already in, then evaluate them again.
function lookUpNewGroups(config: Internal, changed: { [string]: boolean }, players: { Player })
	local fresh = {}
	for name in changed do
		local groups: { number } = config.rules[name].groups or {}
		for _, groupId in groups do
			if not table.find(config.groupIds, groupId) then
				table.insert(config.groupIds, groupId)
				table.insert(fresh, groupId)
			end
		end
	end
	if #fresh == 0 then
		return
	end
	for _, player in players do
		if config.ranks[player] then
			task.spawn(function()
				lookUpRanks(config, player, fresh)
				if config.ranks[player] then
					evaluate(config, player, nil)
				end
			end)
		end
	end
end

local function runCheck(config: Internal, fn: (player: Player) -> boolean, player: Player, what: string): boolean
	local thread = coroutine.create(fn)
	local ok, result = coroutine.resume(thread, player)
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		Log.warn(`[HYDROGEN] {describe(config)}: {what}'s when yielded for {player.Name}; checks must not yield, so it counts as false`)
		return false
	end
	if not ok then
		Log.warn(`[HYDROGEN] {describe(config)}: {what}'s when failed for {player.Name}: {result}; it counts as false`)
		return false
	end
	return result == true
end

--------------------------------------------------------------------------------
-- Live source
--------------------------------------------------------------------------------

local function applyRemote(config: Internal, source: Source, fetched: { [string]: any })
	for _, name in config.names do
		local raw = fetched[name]
		if raw == nil then
			config.remote[name] = nil
			config.remoteRaw[name] = nil
			config.warned[name] = nil
		elseif not equal(raw, config.remoteRaw[name]) then
			local accepted, problem = accept(config, name, raw, false)
			if problem then
				local kept = if config.remote[name] ~= nil then "the last good value" else "the value from code"
				warnOnce(config, name, `[HYDROGEN] {describe(config)}: rejected {name} from live source {source.name}: it {problem}; keeping {kept}`)
			else
				config.remote[name] = accepted
				config.remoteRaw[name] = freezeCopy(raw)
				config.warned[name] = nil
			end
		end
	end
	for name in fetched do
		if type(name) ~= "string" or not (config.decls[name] or config.flagObjects[name]) then
			warnOnce(config, `?{name}`, `[HYDROGEN] {describe(config)}: live source {source.name} sent {tostring(name)}, which isn't a declared value or flag; ignored`)
		end
	end
	recompute(config)
end

-- One fetch. Results arriving after a newer fetch's are dropped.
local function refreshNow(config: Internal): boolean
	local source = config.source
	if not source then
		return false
	end
	config.fetches += 1
	local fetch = config.fetches
	local ok, result = pcall(source.fetch, source, config.names)
	if fetch < config.applied then
		return false
	end
	config.applied = fetch

	if not ok then
		warnOnce(config, "<fetch>", `[HYDROGEN] {describe(config)}: live source {source.name} failed: {result}; keeping the last good values`)
		return false
	end
	if result ~= nil and type(result) ~= "table" then
		warnOnce(config, "<fetch>", `[HYDROGEN] {describe(config)}: live source {source.name} returned a {typeof(result)}, not a table of values; keeping the last good values`)
		return false
	end
	config.warned["<fetch>"] = nil
	applyRemote(config, source, result or {})
	return true
end

local function schedule(config: Internal)
	config.timer = Clock.delay(config.refreshEvery, function()
		config.timer = nil
		if not config.running then
			return
		end
		refreshNow(config)
		if config.running and config.timer == nil then
			schedule(config)
		end
	end)
end

local function startLive(config: Internal)
	local source = config.source
	if not source or config.running then
		return
	end
	config.running = true

	local subscribe = source.subscribe
	if subscribe then
		-- Subscribing may yield (MessagingService), so it doesn't hold up the boot.
		task.spawn(function()
			local ok, stop = pcall(subscribe, source, function()
				if config.running then
					task.spawn(refreshNow, config)
				end
			end)
			if not ok then
				Log.warn(`[HYDROGEN] {describe(config)}: live source {source.name} could not subscribe: {stop}; values still refresh every {config.refreshEvery}s`)
			elseif not config.running then
				pcall(stop)
			else
				config.unsubscribe = stop
			end
		end)
	end

	waitFor(FIRST_FETCH_TIMEOUT, function()
		refreshNow(config)
	end)
	if config.running then
		schedule(config)
	end
end

local function stopLive(config: Internal)
	config.running = false
	if config.timer then
		Clock.cancel(config.timer)
		config.timer = nil
	end
	local unsubscribe = config.unsubscribe
	config.unsubscribe = nil
	if unsubscribe then
		local ok, err = pcall(unsubscribe)
		if not ok then
			Log.warn(`[HYDROGEN] {describe(config)}: stopping the live source failed: {err}`)
		end
	end
end

--------------------------------------------------------------------------------
-- Declarations
--------------------------------------------------------------------------------

local function declare<T>(schema: any, default: T, shared: boolean, level: number): T
	local ok, check = pcall(gt.build, schema)
	if type(schema) ~= "table" or not ok or check == nil then
		error(`[HYDROGEN] Config.{if shared then "shared" else "value"} expects a GreenTea schema (Hydrogen.gt), got {typeof(schema)}`, level)
	end
	local matches, cause = check:matches(default)
	if not matches then
		error(`[HYDROGEN] Config.{if shared then "shared" else "value"}: the default doesn't match the schema: {cause:formatErr()}`, level)
	end
	return {
		[MARK] = true,
		kind = "value",
		schema = schema,
		default = freezeCopy(default),
		shared = shared,
		check = check,
	} :: any
end

function Define.value<T>(schema: T, default: T): T
	return declare(schema, default, false, 3)
end

function Define.shared<T>(schema: T, default: T): T
	return declare(schema, default, true, 3)
end

--------------------------------------------------------------------------------
-- Flags
--------------------------------------------------------------------------------

local FlagMethods = {}
local FlagMeta = { __index = FlagMethods }

local function configOf(flag: FlagObject, method: string): Internal
	local config = flag.config
	if not config then
		error(`[HYDROGEN] This flag isn't part of a config yet; put it in Config.define's flags table before calling {method}`, 3)
	end
	return config
end

-- Flags read on the server before the config's own playerAdded are evaluated on the spot. With
-- the network running but the config never initialized, it was left out of the app.
local function evaluateLate(config: Internal, player: Player): { [string]: boolean }
	if not config.synced and Runtime.Initialized then
		warnOnce(config, "<app>", `[HYDROGEN] {describe(config)} isn't in the app, so clients never see its flags and group rules never load; add the config to the app on the server with app:addSystem`)
	end
	return evaluate(config, player, nil)
end

local function checkPlayer(flag: FlagObject, method: string, player: any)
	if not isPlayer(player) then
		error(`[HYDROGEN] Flag {flag.name}: pass the player (:{method}(player, ...)), got {typeof(player)}`, 3)
	end
end

function FlagMethods.enabled(self: FlagObject, player: Player): boolean
	local config = configOf(self, "enabled")
	checkPlayer(self, "enabled", player)
	if clientContext() then
		local flagState = config.flagState :: State.PlayerMap<string, boolean>
		return flagState:get(player, self.name) == true
	end
	local results = config.results[player] or evaluateLate(config, player)
	return results[self.name] == true
end

function FlagMethods.observe(self: FlagObject, player: Player, observer: (enabled: boolean) -> ()): () -> ()
	local config = configOf(self, "observe")
	checkPlayer(self, "observe", player)
	if type(observer) ~= "function" then
		error(`[HYDROGEN] Flag {self.name}: observe expects a function`, 2)
	end
	local name = self.name

	if clientContext() then
		local flagState = config.flagState :: State.PlayerMap<string, boolean>
		return flagState:observeKey(player, name, function(value: boolean?)
			observer(value == true)
		end)
	end

	local results = config.results[player] or evaluateLate(config, player)
	local byFlag = config.flagObservers[player]
	if not byFlag then
		byFlag = {}
		config.flagObservers[player] = byFlag
	end
	local list = byFlag[name]
	if not list then
		list = {}
		byFlag[name] = list
	end
	table.insert(list, observer)
	task.spawn(call, `flag {name}`, observer, results[name] == true)
	return function()
		remove(list, observer)
	end
end

function Define.flag(rule: FlagRule | boolean): Flag
	if type(rule) ~= "boolean" and type(rule) ~= "table" then
		error(`[HYDROGEN] Config.flag expects a boolean or a rule table, got {typeof(rule)}`, 2)
	end
	return setmetatable({ [MARK] = true, kind = "flag", rule = rule, config = nil }, FlagMeta) :: any
end

function Define.findFlag(name: string): Flag?
	return flagsByName[name] :: any
end

function Define.getFlag(name: string): Flag
	local flag = flagsByName[name]
	if not flag then
		error(`[HYDROGEN] No feature flag named {tostring(name)}; declare it in a Config.define flags table`, 2)
	end
	return flag :: any
end

--------------------------------------------------------------------------------
-- Config methods
--------------------------------------------------------------------------------

local Methods = {}
local Meta = { __index = Methods }

local function assertServer(config: Internal, method: string)
	if realClient() then
		error(`[HYDROGEN] {describe(config)}: {method} only works on the server`, 3)
	end
end

function Methods.observe(self: Internal, name: string, observer: (value: any, previous: any) -> ()): () -> ()
	local decl = self.decls[name]
	if not decl then
		if self.flagObjects[name] then
			error(`[HYDROGEN] {describe(self)}: {name} is a flag; observe it with flags.{name}:observe(player, fn)`, 2)
		end
		error(`[HYDROGEN] {describe(self)} has no value named {tostring(name)}`, 2)
	end
	if realClient() and not decl.shared then
		error(`[HYDROGEN] {describe(self)}: {name} is server-only, so clients can't observe it. Declare it with Config.shared(schema, default) if clients need it`, 2)
	end
	if type(observer) ~= "function" then
		error(`[HYDROGEN] {describe(self)}: observe expects a function`, 2)
	end
	local list = self.observers[name]
	if not list then
		list = {}
		self.observers[name] = list
	end
	table.insert(list, observer)
	task.spawn(call, `Config {self.name}.{name}`, observer, rawget(self.values, name), nil)
	return function()
		remove(list, observer)
	end
end

function Methods.override(self: Internal, overrides: Overrides)
	assertServer(self, "override")
	local ok, layer = pcall(acceptAll, self, "override", overrides)
	if not ok then
		error(layer, 2)
	end
	for name, value in layer do
		self.overridden[name] = value
	end
	recompute(self)
end

function Methods.clearOverrides(self: Internal, names: { string }?)
	assertServer(self, "clearOverrides")
	if names then
		for _, name in names do
			self.overridden[name] = nil
		end
	else
		table.clear(self.overridden)
	end
	recompute(self)
end

function Methods.refresh(self: Internal): boolean
	assertServer(self, "refresh")
	if not self.source then
		error(`[HYDROGEN] {describe(self)} has no live source; pass source = ... to Config.define`, 2)
	end
	return refreshNow(self)
end

function Methods.replica(self: Internal): { [string]: any }
	local shared = self.shared
	return if shared then shared:all() else {}
end

-- Lifecycle: everything happens on the server; on a real client the hooks do nothing.

function Methods.init(self: Internal)
	if realClient() then
		return
	end
	self.synced = true
	local shared = self.shared
	if shared then
		local entries = {}
		for name, decl in self.decls do
			if decl.shared then
				entries[name] = rawget(self.values, name)
			end
		end
		shared:replace(entries)
	end
end

function Methods.start(self: Internal)
	if realClient() then
		return
	end
	startLive(self)
end

function Methods.playerAdded(self: Internal, player: Player)
	if realClient() or next(self.flagObjects) == nil then
		return
	end
	-- Present while the player is in, so lookups finishing after they leave are dropped.
	self.ranks[player] = {}
	-- Evaluate now so flags read during the lookups have an answer, then again with ranks.
	evaluate(self, player, nil)
	if #self.groupIds == 0 then
		return
	end
	local groupIds = table.clone(self.groupIds)
	waitFor(GROUP_TIMEOUT, function()
		lookUpRanks(self, player, groupIds)
		if self.ranks[player] then
			evaluate(self, player, nil)
		end
	end)
end

function Methods.playerRemoving(self: Internal, player: Player)
	self.ranks[player] = nil
	self.results[player] = nil
	self.flagObservers[player] = nil
end

function Methods.stop(self: Internal)
	stopLive(self)
	self.synced = false
end

--------------------------------------------------------------------------------
-- define
--------------------------------------------------------------------------------

local function valuesMetatable(config: Internal)
	return {
		__index = function(_: any, key: any): any
			local decl = config.decls[key]
			if decl then
				if decl.shared or not realClient() then
					return nil
				end
				error(`[HYDROGEN] {describe(config)}: {key} is server-only, so clients can't read it. Declare it with Config.shared(schema, default) if clients need it`, 2)
			end
			if config.flagObjects[key] then
				error(`[HYDROGEN] {describe(config)}: {key} is a flag; read it with flags.{key}:enabled(player)`, 2)
			end
			error(`[HYDROGEN] {describe(config)} has no value named {tostring(key)}`, 2)
		end,
		__newindex = function(_: any, key: any)
			error(`[HYDROGEN] {describe(config)}: values are read-only; change {tostring(key)} with override, an environment or a live source`, 2)
		end,
	}
end

local function flagsMetatable(config: Internal)
	return {
		__index = function(_: any, key: any): any
			error(`[HYDROGEN] {describe(config)} has no flag named {tostring(key)}`, 2)
		end,
		__newindex = function(_: any, key: any)
			error(`[HYDROGEN] {describe(config)}: flags are read-only; declare {tostring(key)} in Config.define`, 2)
		end,
	}
end

-- Checks the spec and builds the config, without registering anything. Errors with plain messages.
local function build(name: string, spec: any): Internal
	if type(spec) ~= "table" then
		error(`[HYDROGEN] Config {name}: Config.define expects a spec table, got {typeof(spec)}`, 0)
	end
	for key in spec do
		if not SPEC_FIELDS[key] then
			error(`[HYDROGEN] Config {name}: unknown field {tostring(key)} (expected values, flags, segments, environments, source or refresh)`, 0)
		end
	end

	local config = {
		name = name,
		values = {},
		flags = {},
		flagObjects = {},
		decls = {},
		names = {},
		segments = {},
		baseRules = {},
		kinds = {},
		places = {} :: { [number]: Overrides },
		env = {},
		remote = {},
		remoteRaw = {},
		overridden = {},
		rules = {},
		observers = {},
		results = setmetatable({}, { __mode = "k" }) :: any,
		flagObservers = setmetatable({}, { __mode = "k" }) :: any,
		ranks = setmetatable({}, { __mode = "k" }) :: any,
		groupIds = {},
		shared = nil,
		flagState = nil,
		synced = false,
		source = nil,
		refreshEvery = DEFAULT_REFRESH,
		running = false,
		timer = nil,
		unsubscribe = nil,
		fetches = 0,
		applied = 0,
		warned = {},
		-- Set once the config exists, since its functions close over it.
		context = nil :: any,
	} :: Internal

	local values = spec.values or {}
	if type(values) ~= "table" then
		error(`[HYDROGEN] Config {name}: values must be a table`, 0)
	end
	for key, decl in values do
		if type(key) ~= "string" or key == "" then
			error(`[HYDROGEN] Config {name}: value names must be non-empty strings, got {tostring(key)}`, 0)
		end
		if type(decl) ~= "table" or decl[MARK] == nil or decl.kind ~= "value" then
			error(`[HYDROGEN] Config {name}: values.{key} must be Config.value(schema, default) or Config.shared(schema, default)`, 0)
		end
		config.decls[key] = decl
		table.insert(config.names, key)
	end

	local segments = spec.segments or {}
	if type(segments) ~= "table" then
		error(`[HYDROGEN] Config {name}: segments must be a table of name = segment`, 0)
	end
	for key, segment in segments do
		if type(key) ~= "string" then
			error(`[HYDROGEN] Config {name}: segment names must be strings, got {tostring(key)}`, 0)
		end
		local compiled, problem = Rules.compileSegment(segment)
		if not compiled then
			error(`[HYDROGEN] Config {name}: segment {key}: {problem}`, 0)
		end
		config.segments[key] = compiled
	end

	local flags = spec.flags or {}
	if type(flags) ~= "table" then
		error(`[HYDROGEN] Config {name}: flags must be a table`, 0)
	end
	for key, flag in flags do
		if type(key) ~= "string" or key == "" then
			error(`[HYDROGEN] Config {name}: flag names must be non-empty strings, got {tostring(key)}`, 0)
		end
		if type(flag) ~= "table" or flag[MARK] == nil or flag.kind ~= "flag" then
			error(`[HYDROGEN] Config {name}: flags.{key} must be Config.flag(rule)`, 0)
		end
		if flag.config then
			error(`[HYDROGEN] Config {name}: flags.{key} is already part of config {flag.config.name}; call Config.flag again for a new flag`, 0)
		end
		if config.decls[key] then
			error(`[HYDROGEN] Config {name}: {key} is both a value and a flag; names must be unique`, 0)
		end
		if flagsByName[key] then
			error(`[HYDROGEN] Config {name}: a flag named {key} already exists in config {(flagsByName[key].config :: Internal).name}; flag names are global`, 0)
		end
		local rule, problem = Rules.compile(flag.rule, config.segments, true)
		if not rule then
			error(`[HYDROGEN] Config {name}: flags.{key}: {problem}`, 0)
		end
		config.flags[key] = flag
		config.flagObjects[key] = flag
		config.baseRules[key] = rule
		table.insert(config.names, key)
	end
	table.sort(config.names)

	local environments = spec.environments or {}
	if type(environments) ~= "table" then
		error(`[HYDROGEN] Config {name}: environments must be a table`, 0)
	end
	for key, overrides in environments do
		if key == "places" then
			if type(overrides) ~= "table" then
				error(`[HYDROGEN] Config {name}: environments.places must be a table of placeId = overrides`, 0)
			end
			for placeId, placeOverrides in overrides do
				if type(placeId) ~= "number" then
					error(`[HYDROGEN] Config {name}: environments.places must be keyed by place id numbers, got {tostring(placeId)}`, 0)
				end
				config.places[placeId] = acceptAll(config, `environments.places[{placeId}]`, placeOverrides)
			end
		elseif Environment.isKind(key) then
			config.kinds[key] = acceptAll(config, `environments.{key}`, overrides)
		else
			error(`[HYDROGEN] Config {name}: unknown environment {tostring(key)} (expected studio, private, reserved, live or places)`, 0)
		end
	end

	local source = spec.source
	if source ~= nil and (type(source) ~= "table" or type(source.fetch) ~= "function") then
		error(`[HYDROGEN] Config {name}: source must have a fetch method (use Config.experienceConfigs(), Config.dataStore(name) or Config.memory())`, 0)
	end
	config.source = source

	local refresh = spec.refresh
	if refresh ~= nil and (type(refresh) ~= "number" or refresh ~= refresh or refresh <= 0) then
		error(`[HYDROGEN] Config {name}: refresh must be a positive number of seconds, got {tostring(refresh)}`, 0)
	end
	config.refreshEvery = refresh or DEFAULT_REFRESH

	-- Group ids every rule and segment might look at, from code and from environments.
	local groups: { [number]: boolean } = {}
	for _, rule in config.baseRules do
		Rules.groupsOf(rule, groups)
	end
	for _, segment in config.segments do
		Rules.groupsOf(segment, groups)
	end
	for _, layer in config.kinds do
		for key, rule in layer do
			if config.flagObjects[key] then
				Rules.groupsOf(rule, groups)
			end
		end
	end
	for _, layer in config.places do
		for key, rule in layer do
			if config.flagObjects[key] then
				Rules.groupsOf(rule, groups)
			end
		end
	end
	for groupId in groups do
		table.insert(config.groupIds, groupId)
	end
	table.sort(config.groupIds)

	return config
end

function Define.define<V, F>(name: string, spec: Spec<V, F>): Config<V, F> & Definition.Lifecycle
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] Config.define needs a non-empty name: Config.define("Game", \{ ... })`, 2)
	end
	if byName[name] then
		error(`[HYDROGEN] Config {name} is already defined; require the shared module instead of defining it again`, 2)
	end
	if Runtime.Initialized then
		error(`[HYDROGEN] Config {name} was defined after the network started; define configs in shared modules that both sides require before app:start()`, 2)
	end

	local ok, built = pcall(build, name, spec)
	if not ok then
		error(built, 2)
	end
	local config = built :: Internal

	local hasShared = false
	for _, decl in config.decls do
		if decl.shared then
			hasShared = true
		end
	end
	if hasShared then
		config.shared = State.map(`Config/{name}`, gt.string(), gt.any())
	end
	if next(config.flagObjects) ~= nil then
		config.flagState = State.playerMap(`Config/{name}/flags`, gt.string(), gt.boolean())
	end

	for flagName, flag in config.flagObjects do
		flag.name = flagName
		flag.config = config
		flagsByName[flagName] = flag
	end

	config.context = {
		rank = function(player: Player, groupId: number): number
			local ranks = config.ranks[player]
			return ranks and ranks[groupId] or 0
		end,
		segment = function(player: Player, segmentName: string): boolean
			local segment = config.segments[segmentName]
			return segment ~= nil and Rules.matchesSegment(segment, player, segmentName, config.context)
		end,
		check = function(fn: (player: Player) -> boolean, player: Player, what: string): boolean
			return runCheck(config, fn, player, what)
		end,
	}

	computeEnv(config)
	if realClient() then
		-- A real client knows shared values only from the server; it starts from the code values.
		for valueName, decl in config.decls do
			if decl.shared then
				local value = layered(config, valueName)
				config.values[valueName] = if value == nil then decl.default else value
			end
		end
		for flagName in config.flagObjects do
			config.rules[flagName] = config.baseRules[flagName]
		end
		local shared = config.shared
		if shared then
			shared:onChange(function(key: string, value: any)
				local decl = config.decls[key]
				if not decl or not decl.shared then
					Log.warn(`[HYDROGEN] {describe(config)}: the server sent {tostring(key)}, which isn't a shared value here; are both sides requiring the same config module?`)
					return
				end
				local matches, cause = decl.check:matches(value)
				if not matches then
					Log.warn(`[HYDROGEN] {describe(config)}: the server sent an invalid {key}: {cause:formatErr()}; ignored`)
					return
				end
				local previous = rawget(config.values, key)
				rawset(config.values, key, freezeCopy(value))
				notify(`Config {name}.{key}`, config.observers[key], rawget(config.values, key), previous)
			end)
		end
	else
		recompute(config)
	end

	setmetatable(config.values, valuesMetatable(config))
	setmetatable(config.flags, flagsMetatable(config))
	setmetatable(config :: any, Meta)

	byName[name] = config
	table.insert(configs, config)

	Definition.define(`Hydrogen.Config/{name}`, function()
		return config
	end)
	return config :: any
end

--------------------------------------------------------------------------------
-- Module functions
--------------------------------------------------------------------------------

function Define.environment(): Environment.Environment
	return Environment.current()
end

function Define.useEnvironment(environment: { kind: Environment.Kind?, placeId: number? }?)
	if environment ~= nil then
		if type(environment) ~= "table" then
			error(`[HYDROGEN] Config.useEnvironment expects \{ kind = ..., placeId = ... } or nil, got {typeof(environment)}`, 2)
		end
		local kind: Environment.Kind = environment.kind or "live"
		if not Environment.isKind(kind) then
			error(`[HYDROGEN] Config.useEnvironment: kind must be "studio", "private", "reserved" or "live", got {tostring(kind)}`, 2)
		end
		local placeId = environment.placeId or Environment.current().placeId
		if type(placeId) ~= "number" then
			error(`[HYDROGEN] Config.useEnvironment: placeId must be a number, got {typeof(placeId)}`, 2)
		end
		Environment.force(table.freeze({ kind = kind, placeId = placeId }))
	else
		Environment.force(nil)
	end
	for _, config in configs do
		computeEnv(config)
		if not realClient() then
			recompute(config)
		end
	end
end

function Define.reevaluate(player: Player?)
	if realClient() then
		error(`[HYDROGEN] Config.reevaluate only works on the server`, 2)
	end
	if player ~= nil and not isPlayer(player) then
		error(`[HYDROGEN] Config.reevaluate expects a player or nil, got {typeof(player)}`, 2)
	end
	for _, config in configs do
		if player then
			evaluate(config, player, nil)
		else
			local players = {}
			for each in config.results do
				table.insert(players, each)
			end
			for _, each in players do
				evaluate(config, each, nil)
			end
		end
	end
end

-- For tests: overrides, live values, flag results and observers dropped, and the real
-- environment back. Hydrogen.test calls it when it closes.
function Define.reset()
	Environment.force(nil)
	for _, config in configs do
		stopLive(config)
		config.synced = false
		table.clear(config.overridden)
		table.clear(config.remote)
		table.clear(config.remoteRaw)
		table.clear(config.results)
		table.clear(config.ranks)
		table.clear(config.flagObservers)
		table.clear(config.observers)
		table.clear(config.warned)
		config.fetches = 0
		config.applied = 0
		computeEnv(config)
		if not realClient() then
			recompute(config)
		end
	end
end

return Define
