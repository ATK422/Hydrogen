--!strict

-- Components: code bound to every instance with a CollectionService tag. A component is a
-- system. After its start hook it constructs one object per tagged instance in the game,
-- each with its own scope, and destroys it when the instance is untagged, destroyed or
-- streamed out, or stops passing the component's filters. app:stop() destroys them all.

local Definition = require("./Definition")
local Scope = require("./Scope")
local Clock = require("./Clock")
local Log = require("./Log")
local Source = require("@self/Source")
local gt = require("../roblox_packages/gt")

type Scope = Scope.Scope
type Source = Source.Source

export type Options<I, A, T> = {
	-- Bind only instances under one of these, e.g. { workspace }, so templates in
	-- ReplicatedStorage or ServerStorage are left alone. Checked again when an instance moves.
	ancestors: { Instance }?,
	-- Children that must exist before construct runs: names ({ "Hitbox" }) or names to classes
	-- ({ Hitbox = "BasePart" }). If one is removed the object is destroyed until it is back.
	children: ({ string } | { [string]: string })?,
	-- A GreenTea schema for the instance's attributes: gt.table({ Value = gt.number() }), or
	-- the plain table { Value = gt.number() }. construct waits until they match, and gets them typed.
	attributes: A?,
	-- Seconds to wait for children or attributes before warning. Waiting goes on after the
	-- warning. Defaults to 5.
	timeout: number?,
	-- Runs for each tagged instance; may yield. What it returns is the instance's object
	-- (Component:get), or the instance itself if it returns nothing. Add cleanup to scope.
	construct: (instance: I, scope: Scope, attributes: A) -> T,
	-- Runs before the scope is destroyed, for objects whose construct returned. Mustn't yield.
	destroy: ((object: T, instance: I) -> ())?,
}

export type Component<I, T> = {
	-- The CollectionService tag.
	read tag: string,
	-- The instance's object, or nil if it isn't constructed (yet).
	get: (self: Component<I, T>, instance: Instance) -> T?,
	-- Whether the instance's object is constructed.
	has: (self: Component<I, T>, instance: Instance) -> boolean,
	-- Every constructed object, in no particular order.
	all: (self: Component<I, T>) -> { T },
	-- Every instance with a constructed object, in no particular order.
	instances: (self: Component<I, T>) -> { I },
	-- Yields until the instance's object is constructed and returns it, or nil after timeout
	-- seconds or when the component stops. Without a timeout it warns after 5s and keeps waiting.
	wait: (self: Component<I, T>, instance: Instance, timeout: number?) -> T?,
}

type Use = <S>(system: S) -> Definition.System<S>

type Entry = {
	instance: Instance,
	-- Stops the ancestry, children and attribute watchers.
	unwatch: () -> (),
	-- From construct starting until the object is destroyed.
	scope: Scope?,
	-- Set once construct returned.
	object: any,
	constructed: boolean,
	-- The table construct got, kept current while the attributes still match.
	attributes: { [string]: any }?,
	-- construct errored; it isn't tried again until the instance stops qualifying.
	failed: boolean,
	-- Warns when children or attributes take longer than the timeout.
	timer: thread?,
	warned: boolean,
}

type Waiter = {
	instance: Instance,
	thread: thread,
	timer: thread?,
}

type Run = {
	source: Source,
	scope: Scope,
	entries: { [Instance]: Entry },
	waiters: { Waiter },
	stopListening: () -> (),
}

type Config = {
	tag: string,
	name: string,
	ancestors: { Instance }?,
	-- Name -> class the child must be (IsA).
	children: { [string]: string }?,
	attributes: any?,
	timeout: number,
	construct: (Instance, Scope, any) -> any,
	destroy: ((any, Instance) -> ())?,
	needs: Source.Needs,
}

local DEFAULT_TIMEOUT = 5

local Component = {
	-- Tests of the game path: a CollectionService stand-in (with a root field for its DataModel)
	-- that components use through signals, even under a fake clock.
	_collectionService = nil :: any,
}

local function describe(instance: Instance): string
	local ok, name = pcall(instance.GetFullName, instance)
	return if ok then name else tostring(instance)
end

local function validate(tag: any, options: any, level: number): Config
	if type(tag) ~= "string" or tag == "" then
		error(`[HYDROGEN] Component.new needs a tag: Component.new("Coin", \{ construct = ... \})`, level)
	end
	local name = `{tag} component`
	if type(options) ~= "table" then
		error(`[HYDROGEN] {name}: Component.new expects an options table with construct`, level)
	end
	if type(options.construct) ~= "function" then
		error(`[HYDROGEN] {name} needs a construct function: construct = function(instance, scope) ... end`, level)
	end
	if options.destroy ~= nil and type(options.destroy) ~= "function" then
		error(`[HYDROGEN] {name}: destroy must be a function`, level)
	end

	local ancestors = options.ancestors
	if ancestors ~= nil then
		if type(ancestors) ~= "table" or #ancestors == 0 then
			error(`[HYDROGEN] {name}: ancestors must be a list of Instances, e.g. \{ workspace \}`, level)
		end
		for _, ancestor in ancestors do
			-- Tables pass too, for stand-in Instances in tests.
			if typeof(ancestor) ~= "Instance" and type(ancestor) ~= "table" then
				error(`[HYDROGEN] {name}: ancestors must be a list of Instances, got a {typeof(ancestor)}`, level)
			end
		end
	end

	local children: { [string]: string }? = nil
	if options.children ~= nil then
		if type(options.children) ~= "table" then
			error(`[HYDROGEN] {name}: children must be a list of names or a table of names to classes`, level)
		end
		local required: { [string]: string } = {}
		for key, value in options.children do
			if type(key) == "number" and type(value) == "string" then
				required[value] = "Instance"
			elseif type(key) == "string" and type(value) == "string" then
				required[key] = value
			else
				error(`[HYDROGEN] {name}: children must be a list of names or a table of names to classes`, level)
			end
		end
		if next(required) ~= nil then
			children = required
		end
	end

	local attributes = nil
	if options.attributes ~= nil then
		-- A plain table of schemas is a gt.table.
		local ok, schema = pcall(gt.typeof, options.attributes)
		if type(options.attributes) ~= "table" or not ok or not gt.isGtType(schema) then
			error(`[HYDROGEN] {name}: attributes must be a GreenTea schema, e.g. gt.table(\{ Value = gt.number() \})`, level)
		end
		attributes = gt.typecast(schema)
	end

	local timeout = options.timeout
	if timeout == nil then
		timeout = DEFAULT_TIMEOUT
	elseif type(timeout) ~= "number" or timeout < 0 or timeout ~= timeout then
		error(`[HYDROGEN] {name}: timeout must be a number of seconds`, level)
	end

	return {
		tag = tag,
		name = name,
		ancestors = ancestors,
		children = children,
		attributes = attributes,
		timeout = timeout,
		construct = options.construct,
		destroy = options.destroy,
		needs = {
			ancestry = ancestors ~= nil,
			children = children ~= nil,
			attributes = attributes ~= nil,
		},
	}
end

-- Whether the instance is tagged and in the game. A destroyed instance (Lune errors on it) isn't.
local function tracked(config: Config, run: Run, instance: Instance): boolean
	local ok, result = pcall(function()
		return instance:HasTag(config.tag) and instance:IsDescendantOf(run.source.root)
	end)
	return ok and result == true
end

-- "ready" with the attributes, "filtered" (outside the ancestors) or "waiting" with what for.
local function check(config: Config, instance: Instance): (string, any)
	local ancestors = config.ancestors
	if ancestors then
		local inside = false
		for _, ancestor in ancestors do
			if instance:IsDescendantOf(ancestor) then
				inside = true
				break
			end
		end
		if not inside then
			return "filtered", nil
		end
	end

	local children = config.children
	if children then
		for childName, className in children do
			local child = instance:FindFirstChild(childName)
			if child == nil then
				return "waiting", `child "{childName}"`
			end
			if className ~= "Instance" and not child:IsA(className) then
				return "waiting", `child "{childName}" to be a {className} (it is a {child.ClassName})`
			end
		end
	end

	local schema = config.attributes
	if schema then
		local attributes = instance:GetAttributes()
		local ok, cause = schema:matches(attributes)
		if not ok then
			return "waiting", `attributes matching the schema ({cause:formatErr()})`
		end
		return "ready", attributes
	end

	return "ready", nil
end

local function wake(run: Run, entry: Entry)
	local index = 1
	while index <= #run.waiters do
		local waiter = run.waiters[index]
		if waiter.instance == entry.instance then
			table.remove(run.waiters, index)
			if waiter.timer then
				Clock.cancel(waiter.timer)
			end
			task.spawn(waiter.thread, entry.object)
		else
			index += 1
		end
	end
end

local function stopTimer(entry: Entry)
	local timer = entry.timer
	if timer then
		entry.timer = nil
		Clock.cancel(timer)
	end
end

local function construct(config: Config, run: Run, entry: Entry, attributes: { [string]: any }?)
	local instance = entry.instance
	local scope = run.scope:child(`{config.name} for {describe(instance)}`)
	entry.scope = scope
	entry.attributes = attributes

	local thread = coroutine.create(function()
		local ok, result = xpcall(config.construct, debug.traceback, instance, scope, attributes)
		if not ok then
			Log.warn(`[HYDROGEN] {config.name} failed to construct for {describe(instance)}: {result}`)
		end
		-- The instance left while construct ran (construct itself may have destroyed it).
		if entry.scope ~= scope then
			return
		end
		if not ok then
			entry.scope = nil
			entry.attributes = nil
			entry.failed = true
			scope:destroy()
			return
		end
		entry.object = if result == nil then instance else result
		entry.constructed = true
		wake(run, entry)
	end)
	-- Destroying the scope cancels a construct that is still yielding.
	scope:add(thread)
	task.spawn(thread)
end

local function deconstruct(config: Config, entry: Entry)
	local scope = entry.scope
	if scope == nil then
		return
	end
	local object = entry.object
	local constructed = entry.constructed
	entry.scope = nil
	entry.object = nil
	entry.constructed = false
	entry.attributes = nil

	local destroy = config.destroy
	if constructed and destroy then
		local ok, err = xpcall(destroy, debug.traceback, object, entry.instance)
		if not ok then
			Log.warn(`[HYDROGEN] {config.name} failed to destroy for {describe(entry.instance)}: {err}`)
		end
	end
	scope:destroy()
end

local function startTimer(config: Config, entry: Entry, waitingFor: string)
	if entry.timer or entry.warned then
		return
	end
	entry.timer = Clock.delay(config.timeout, function()
		entry.timer = nil
		entry.warned = true
		Log.warn(
			`[HYDROGEN] {config.name}: {describe(entry.instance)} has waited {config.timeout}s for {waitingFor}; it is constructed as soon as that's there. Fix the instance (or its template), or raise the component's timeout if it is just slow`
		)
	end)
end

local function refresh(config: Config, run: Run, entry: Entry)
	local ok, status, detail = pcall(check, config, entry.instance)
	if not ok then
		-- The instance went away mid-check (Lune errors on destroyed instances).
		status, detail = "filtered", nil
	end

	if status == "ready" then
		stopTimer(entry)
		entry.warned = false
		if entry.scope == nil then
			if not entry.failed then
				construct(config, run, entry, detail)
			end
		elseif detail and entry.attributes then
			-- Still valid: update the table construct got, in place.
			local current = entry.attributes
			table.clear(current)
			for key, value in detail do
				current[key] = value
			end
		end
		return
	end

	entry.failed = false
	if entry.scope then
		if status == "waiting" then
			Log.warn(`[HYDROGEN] {config.name}: {describe(entry.instance)} no longer has {detail}; its object is destroyed until it does`)
			-- Already said what it waits for.
			entry.warned = true
		end
		deconstruct(config, entry)
	end
	if status == "waiting" then
		startTimer(config, entry, detail)
	else
		stopTimer(entry)
		entry.warned = false
	end
end

local function drop(config: Config, run: Run, entry: Entry)
	run.entries[entry.instance] = nil
	entry.unwatch()
	stopTimer(entry)
	deconstruct(config, entry)
end

-- Every signal lands here: works out from scratch what the instance should be, so tags added
-- and removed in any order, deferred signals and reparenting all end in the right state.
local function evaluate(config: Config, run: Run, instance: Instance)
	local key = run.source.key(instance)
	local entry = run.entries[key]
	if not tracked(config, run, key) then
		if entry then
			drop(config, run, entry)
		end
		return
	end

	if entry == nil then
		local newEntry: Entry = {
			instance = key,
			unwatch = function() end,
			scope = nil,
			object = nil,
			constructed = false,
			attributes = nil,
			failed = false,
			timer = nil,
			warned = false,
		}
		entry = newEntry
		run.entries[key] = newEntry
		newEntry.unwatch = run.source.watch(key, config.needs, function()
			-- A watcher can fire after the entry was dropped and replaced.
			if run.entries[key] == newEntry then
				evaluate(config, run, key)
			end
		end)
	end
	refresh(config, run, entry :: Entry)
end

local stop: (config: Config, system: any) -> ()

local function start(config: Config, system: any)
	if system._run ~= nil then
		-- Usually an earlier test whose app was never stopped.
		Log.warn(`[HYDROGEN] {config.name} was still running in another app; stopping it there first`)
		stop(config, system)
	end

	local source = if Component._collectionService
		then Source.signals(Component._collectionService)
		elseif Clock.active() ~= nil or not Source.hasSignals() then Source.polled()
		else Source.signals()
	local run: Run = {
		source = source,
		scope = Scope.of(system),
		entries = {},
		waiters = {},
		stopListening = function() end,
	}
	system._run = run
	-- The system scope also closes when a boot fails, which runs no stop hooks.
	run.scope:add(function()
		if system._run == run then
			stop(config, system)
		end
	end)

	run.stopListening = source.listen(config.tag, function(instance)
		if system._run == run then
			evaluate(config, run, instance)
		end
	end)
	for _, instance in source.tagged(config.tag) do
		evaluate(config, run, instance)
	end
end

function stop(config: Config, system: any)
	local run = system._run :: Run?
	if run == nil then
		return
	end
	system._run = nil
	run.stopListening()

	local entries = {}
	for _, entry in run.entries do
		table.insert(entries, entry)
	end
	for _, entry in entries do
		drop(config, run, entry)
	end

	local waiters = run.waiters
	run.waiters = {}
	for _, waiter in waiters do
		if waiter.timer then
			Clock.cancel(waiter.timer)
		end
		task.spawn(waiter.thread, nil)
	end
end

local function build(config: Config): any
	local component = { tag = config.tag }

	local function entryOf(self: any, instance: Instance): Entry?
		local run = self._run :: Run?
		if run == nil or instance == nil then
			return nil
		end
		local entry = run.entries[run.source.key(instance)]
		return if entry and entry.constructed then entry else nil
	end

	function component:get(instance: Instance): any
		local entry = entryOf(self, instance)
		return if entry then entry.object else nil
	end

	function component:has(instance: Instance): boolean
		return entryOf(self, instance) ~= nil
	end

	function component:all(): { any }
		local objects = {}
		local run = self._run :: Run?
		if run then
			for _, entry in run.entries do
				if entry.constructed then
					table.insert(objects, entry.object)
				end
			end
		end
		return objects
	end

	function component:instances(): { Instance }
		local instances = {}
		local run = self._run :: Run?
		if run then
			for instance, entry in run.entries do
				if entry.constructed then
					table.insert(instances, instance)
				end
			end
		end
		return instances
	end

	function component:wait(instance: Instance, timeout: number?): any
		if instance == nil then
			error(`[HYDROGEN] {config.name}: wait expects an Instance, got nil`, 2)
		end
		local entry = entryOf(self, instance)
		if entry then
			return entry.object
		end
		local run = self._run :: Run?
		if run == nil then
			return nil
		end

		local waiter: Waiter = {
			instance = instance,
			thread = coroutine.running(),
			timer = nil,
		}
		local seconds = timeout or DEFAULT_TIMEOUT
		waiter.timer = Clock.delay(seconds, function()
			waiter.timer = nil
			if timeout == nil then
				Log.warn(`[HYDROGEN] {config.name}: still waiting for {describe(instance)} after {seconds}s; pass a timeout to wait(instance, timeout) to give up`)
				return
			end
			local index = table.find(run.waiters, waiter)
			if index then
				table.remove(run.waiters, index)
				task.spawn(waiter.thread, nil)
			end
		end)
		table.insert(run.waiters, waiter)
		return coroutine.yield()
	end

	function component:start()
		start(config, self)
	end

	function component:stop()
		stop(config, self)
	end

	return component
end

--[=[
	return Hydrogen.Component.new("Coin", function(use)
		local Wallet = use(WalletSystem)
		return {
			ancestors = { workspace },
			attributes = gt.table({ Value = gt.number() }),
			construct = function(coin: BasePart, scope, attributes)
				scope:connect(coin.Touched, function(hit) ... end)
			end,
		}
	end)
]=]
local function new(tag: string, options: any): any
	if type(options) == "function" then
		if type(tag) ~= "string" or tag == "" then
			validate(tag, nil, 3)
		end
		return Definition.define(`{tag} component`, function(use)
			local ok, result = pcall(options, use)
			if not ok then
				error(result, 0)
			end
			return build(validate(tag, result, 0))
		end)
	end

	local config = validate(tag, options, 3)
	return Definition.define(config.name, function()
		return build(config)
	end)
end

Component.new = (new :: any) :: (<I, A, T>(tag: string, options: Options<I, A, T>) -> Definition.Defined<Component<I, T>>)
	& (<I, A, T>(tag: string, constructor: (use: Use) -> Options<I, A, T>) -> Definition.Defined<Component<I, T>>)

return Component
