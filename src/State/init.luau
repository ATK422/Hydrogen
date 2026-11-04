--!strict

-- Server-authoritative state replicated to clients. Define states in shared modules (like network
-- objects); the server writes, both sides read and observe. Changes made in one frame go out as one
-- message per changed state, and collections send only what changed.

local Computed = require("@self/Computed")
local List = require("@self/List")
local Map = require("@self/Map")
local Store = require("@self/Store")
local Value = require("@self/Value")
local Wire = require("@self/Wire")

type Def = Store.Def
type Event = Wire.Event

-- Who sees a per-player state: only the player it belongs to, or every player.
export type VisibleTo = "owner" | "everyone"

-- Sends values in another form, e.g. a class instance as a plain table.
export type Serializer = {
	-- GreenTea schema of the serialized form; it is what the wire is checked against.
	schema: any,
	serialize: (value: any) -> any,
	deserialize: (wire: any) -> any,
}

export type Options = {
	-- Pack payloads into a buffer (calls :Encode() on the underlying event).
	encode: boolean?,
	serializer: Serializer?,
}

export type PlayerOptions = {
	-- Defaults to "owner".
	visibleTo: VisibleTo?,
	encode: boolean?,
	serializer: Serializer?,
}

type Disconnect = () -> ()

export type Value<T> = {
	read name: string,
	-- The serverEvent that carries this state, for middleware such as Hydrogen.logger.
	read event: Event,
	get: (self: Value<T>) -> T,
	set: (self: Value<T>, value: T) -> (),
	update: (self: Value<T>, transform: (current: T) -> T) -> (),
	-- Calls observer with the value now and on every change. Returns a disconnect function.
	observe: (self: Value<T>, observer: (value: T, previous: T?) -> ()) -> Disconnect,
}

export type Map<K, V> = {
	read name: string,
	read event: Event,
	get: (self: Map<K, V>, key: K) -> V?,
	-- A copy of every entry.
	all: (self: Map<K, V>) -> { [K]: V },
	size: (self: Map<K, V>) -> number,
	-- A nil value removes the key.
	set: (self: Map<K, V>, key: K, value: V?) -> (),
	remove: (self: Map<K, V>, key: K) -> (),
	update: (self: Map<K, V>, key: K, transform: (current: V?) -> V?) -> (),
	-- Makes the map equal to entries; only the keys that differ are sent.
	replace: (self: Map<K, V>, entries: { [K]: V }) -> (),
	clear: (self: Map<K, V>) -> (),
	observe: (self: Map<K, V>, observer: (entries: { [K]: V }) -> ()) -> Disconnect,
	observeKey: (self: Map<K, V>, key: K, observer: (value: V?) -> ()) -> Disconnect,
	-- Called for each changed key, without an initial call.
	onChange: (self: Map<K, V>, listener: (key: K, value: V?, previous: V?) -> ()) -> Disconnect,
}

export type List<T> = {
	read name: string,
	read event: Event,
	get: (self: List<T>, index: number) -> T?,
	all: (self: List<T>) -> { T },
	size: (self: List<T>) -> number,
	push: (self: List<T>, value: T) -> (),
	insert: (self: List<T>, index: number, value: T) -> (),
	remove: (self: List<T>, index: number) -> T,
	set: (self: List<T>, index: number, value: T) -> (),
	replace: (self: List<T>, items: { T }) -> (),
	clear: (self: List<T>) -> (),
	observe: (self: List<T>, observer: (items: { T }) -> ()) -> Disconnect,
}

export type PlayerValue<T> = {
	read name: string,
	read event: Event,
	get: (self: PlayerValue<T>, player: Player) -> T,
	set: (self: PlayerValue<T>, player: Player, value: T) -> (),
	update: (self: PlayerValue<T>, player: Player, transform: (current: T) -> T) -> (),
	observe: (self: PlayerValue<T>, player: Player, observer: (value: T, previous: T?) -> ()) -> Disconnect,
}

export type PlayerMap<K, V> = {
	read name: string,
	read event: Event,
	get: (self: PlayerMap<K, V>, player: Player, key: K) -> V?,
	all: (self: PlayerMap<K, V>, player: Player) -> { [K]: V },
	size: (self: PlayerMap<K, V>, player: Player) -> number,
	set: (self: PlayerMap<K, V>, player: Player, key: K, value: V?) -> (),
	remove: (self: PlayerMap<K, V>, player: Player, key: K) -> (),
	update: (self: PlayerMap<K, V>, player: Player, key: K, transform: (current: V?) -> V?) -> (),
	replace: (self: PlayerMap<K, V>, player: Player, entries: { [K]: V }) -> (),
	clear: (self: PlayerMap<K, V>, player: Player) -> (),
	observe: (self: PlayerMap<K, V>, player: Player, observer: (entries: { [K]: V }) -> ()) -> Disconnect,
	observeKey: (self: PlayerMap<K, V>, player: Player, key: K, observer: (value: V?) -> ()) -> Disconnect,
	onChange: (self: PlayerMap<K, V>, player: Player, listener: (key: K, value: V?, previous: V?) -> ()) -> Disconnect,
}

export type PlayerList<T> = {
	read name: string,
	read event: Event,
	get: (self: PlayerList<T>, player: Player, index: number) -> T?,
	all: (self: PlayerList<T>, player: Player) -> { T },
	size: (self: PlayerList<T>, player: Player) -> number,
	push: (self: PlayerList<T>, player: Player, value: T) -> (),
	insert: (self: PlayerList<T>, player: Player, index: number, value: T) -> (),
	remove: (self: PlayerList<T>, player: Player, index: number) -> T,
	set: (self: PlayerList<T>, player: Player, index: number, value: T) -> (),
	replace: (self: PlayerList<T>, player: Player, items: { T }) -> (),
	clear: (self: PlayerList<T>, player: Player) -> (),
	observe: (self: PlayerList<T>, player: Player, observer: (items: { T }) -> ()) -> Disconnect,
}

export type Computed<T> = Computed.Computed<T>

--------------------------------------------------------------------------------
-- Checks. Raised at level 4: check <- operation <- method wrapper <- caller.
--------------------------------------------------------------------------------

local function assertValid(state: any, check: any, value: any, what: string)
	local ok, cause = check:matches(value)
	if not ok then
		error(`[HYDROGEN] State {state.name} got an invalid {what}: {cause:formatErr()}`, 4)
	end
end

local function assertPresent(state: any, value: any, what: string)
	if value == nil then
		error(`[HYDROGEN] State {state.name} can't hold nil as a {what}`, 4)
	end
end

local function assertIndex(state: any, index: any, last: number)
	if type(index) ~= "number" or index % 1 ~= 0 or index < 1 or index > last then
		error(`[HYDROGEN] State {state.name}: index {index} is out of range (1 to {last})`, 4)
	end
end

local function writable(state: any)
	-- assertWritable <- writable <- operation <- wrapper <- caller
	Store.assertWritable(state, 4)
end

--------------------------------------------------------------------------------
-- Operations, written once with a player argument (nil for global state).
--------------------------------------------------------------------------------

type Ops = { [string]: (state: any, player: Player?, ...any) -> any }

local ValueOps: Ops = {}

function ValueOps.get(state, player)
	return Value.get(state, player)
end

function ValueOps.set(state, player, value)
	writable(state)
	assertValid(state, state._check, value, "value")
	Value.set(state, player, value)
	return nil
end

function ValueOps.update(state, player, transform)
	writable(state)
	local value = transform(Value.current(state, player))
	assertValid(state, state._check, value, "value from update")
	Value.set(state, player, value)
	return nil
end

function ValueOps.observe(state, player, observer)
	return Value.observe(state, player, observer)
end

local MapOps: Ops = {}

function MapOps.get(state, player, key)
	return Map.get(state, player, key)
end

function MapOps.all(state, player)
	return Map.all(state, player)
end

function MapOps.size(state, player)
	return Map.size(state, player)
end

function MapOps.set(state, player, key, value)
	writable(state)
	assertPresent(state, key, "key")
	assertValid(state, state._keyCheck, key, "key")
	if value ~= nil then
		assertValid(state, state._check, value, "value")
	end
	Map.set(state, player, key, value)
	return nil
end

function MapOps.remove(state, player, key)
	writable(state)
	assertPresent(state, key, "key")
	Map.set(state, player, key, nil)
	return nil
end

function MapOps.update(state, player, key, transform)
	writable(state)
	assertPresent(state, key, "key")
	assertValid(state, state._keyCheck, key, "key")
	local value = transform(Map.current(state, player, key))
	if value ~= nil then
		assertValid(state, state._check, value, "value from update")
	end
	Map.set(state, player, key, value)
	return nil
end

function MapOps.replace(state, player, entries)
	writable(state)
	if type(entries) ~= "table" then
		error(`[HYDROGEN] State {state.name}: replace expects a table, got {typeof(entries)}`, 3)
	end
	for key, value in entries do
		assertValid(state, state._keyCheck, key, "key")
		assertValid(state, state._check, value, "value")
	end
	Map.replace(state, player, entries)
	return nil
end

function MapOps.clear(state, player)
	writable(state)
	Map.clear(state, player)
	return nil
end

function MapOps.observe(state, player, observer)
	return Map.observe(state, player, observer)
end

function MapOps.observeKey(state, player, key, observer)
	return Map.observeKey(state, player, key, observer)
end

function MapOps.onChange(state, player, listener)
	return Map.onChange(state, player, listener)
end

local ListOps: Ops = {}

function ListOps.get(state, player, index)
	return List.get(state, player, index)
end

function ListOps.all(state, player)
	return List.all(state, player)
end

function ListOps.size(state, player)
	return List.size(state, player)
end

function ListOps.push(state, player, value)
	writable(state)
	assertPresent(state, value, "list item")
	assertValid(state, state._check, value, "list item")
	List.insert(state, player, List.count(state, player) + 1, value)
	return nil
end

function ListOps.insert(state, player, index, value)
	writable(state)
	assertIndex(state, index, List.count(state, player) + 1)
	assertPresent(state, value, "list item")
	assertValid(state, state._check, value, "list item")
	List.insert(state, player, index, value)
	return nil
end

function ListOps.remove(state, player, index)
	writable(state)
	assertIndex(state, index, List.count(state, player))
	return List.remove(state, player, index)
end

function ListOps.set(state, player, index, value)
	writable(state)
	assertIndex(state, index, List.count(state, player))
	assertPresent(state, value, "list item")
	assertValid(state, state._check, value, "list item")
	List.set(state, player, index, value)
	return nil
end

function ListOps.replace(state, player, items)
	writable(state)
	if type(items) ~= "table" then
		error(`[HYDROGEN] State {state.name}: replace expects an array, got {typeof(items)}`, 3)
	end
	for _, item in items do
		assertValid(state, state._check, item, "list item")
	end
	List.replace(state, player, items)
	return nil
end

function ListOps.clear(state, player)
	writable(state)
	List.clear(state, player)
	return nil
end

function ListOps.observe(state, player, observer)
	return List.observe(state, player, observer)
end

--------------------------------------------------------------------------------
-- Methods: global state passes no player; per-player state checks the one it was given.
--------------------------------------------------------------------------------

local function isPlayer(value: any): boolean
	if typeof(value) == "Instance" then
		return value.ClassName == "Player"
	end
	return type(value) == "table" and type(value.UserId) == "number"
end

-- Each wrapper is exactly one frame between the caller and the operation, so checks inside
-- operations can raise errors at the caller's line. Results go through a local for the same reason.
local function globalMethods(ops: Ops): { [string]: any }
	local methods = {}
	for name, op in ops do
		methods[name] = function(self: any, a: any, b: any)
			local result = op(self, nil, a, b)
			return result
		end
	end
	return methods
end

local function playerMethods(ops: Ops): { [string]: any }
	local methods = {}
	for name, op in ops do
		methods[name] = function(self: any, player: any, a: any, b: any)
			if not isPlayer(player) then
				error(`[HYDROGEN] State {self.name} is per player: pass the player first (:{name}(player, ...)), got {typeof(player)}`, 2)
			end
			local result = op(self, player, a, b)
			return result
		end
	end
	return methods
end

local metatables = {
	value = { __index = globalMethods(ValueOps) },
	map = { __index = globalMethods(MapOps) },
	list = { __index = globalMethods(ListOps) },
	playerValue = { __index = playerMethods(ValueOps) },
	playerMap = { __index = playerMethods(MapOps) },
	playerList = { __index = playerMethods(ListOps) },
}

--------------------------------------------------------------------------------
-- Definitions
--------------------------------------------------------------------------------

local kinds = {
	value = Value :: Store.Kind,
	map = Map :: Store.Kind,
	list = List :: Store.Kind,
}

local function identity(value: any): any
	return value
end

type Spec = {
	name: any,
	kind: "value" | "map" | "list",
	perPlayer: boolean,
	options: any,
	schema: any,
	keySchema: any?,
	initial: any,
}

local function define(spec: Spec): any
	local name = spec.name
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] State needs a non-empty name`, 3)
	end
	if Store.byName[name] then
		error(`[HYDROGEN] State {name} is already defined; state names must be unique`, 3)
	end
	if Wire.networkStarted() then
		error(`[HYDROGEN] State {name} was defined after the network started; define states in shared modules that both sides require before app:start()`, 3)
	end

	local options = spec.options or {}
	if type(options) ~= "table" then
		error(`[HYDROGEN] State {name}: options must be a table`, 3)
	end

	local visibleTo = options.visibleTo
	if not spec.perPlayer and visibleTo ~= nil then
		error(`[HYDROGEN] State {name}: visibleTo only applies to per-player state (playerValue, playerMap, playerList)`, 3)
	end
	if visibleTo ~= nil and visibleTo ~= "owner" and visibleTo ~= "everyone" then
		error(`[HYDROGEN] State {name}: visibleTo must be "owner" or "everyone", got {visibleTo}`, 3)
	end
	local public = not spec.perPlayer or visibleTo == "everyone"

	local serializer = options.serializer
	if serializer ~= nil and (type(serializer) ~= "table" or type(serializer.serialize) ~= "function" or type(serializer.deserialize) ~= "function" or serializer.schema == nil) then
		error(`[HYDROGEN] State {name}: serializer needs schema, serialize and deserialize`, 3)
	end

	local check = Wire.build(spec.schema)
	if spec.kind == "value" then
		local ok, cause = check:matches(spec.initial)
		if not ok then
			error(`[HYDROGEN] State {name}: the initial value doesn't match the schema: {cause:formatErr()}`, 3)
		end
	end

	local wireSchema = if serializer then serializer.schema else spec.schema
	local event = Wire.event(name, spec.kind, spec.perPlayer and public, wireSchema, spec.keySchema, options.encode == true)

	local state = {
		name = name,
		event = event,
		kind = kinds[spec.kind],
		perPlayer = spec.perPlayer,
		public = public,
		initial = spec.initial,
		wire = if serializer then serializer.serialize else identity,
		unwire = if serializer then serializer.deserialize else identity,
		global = {},
		players = {},
		watchers = {},
		_check = check,
		_keyCheck = if spec.keySchema ~= nil then Wire.build(spec.keySchema) else nil,
	} :: any

	state.receive = function(...: any)
		Store.receive(state, ...)
	end
	event:On(state.receive)

	Store.byName[name] = state
	table.insert(Store.states, state :: Def)

	local metatableName = if spec.perPlayer
		then "player" .. string.upper(string.sub(spec.kind, 1, 1)) .. string.sub(spec.kind, 2)
		else spec.kind
	return setmetatable(state, (metatables :: any)[metatableName])
end

local State = {}

-- One value everyone sees, such as the round phase or a timer.
function State.value<T>(name: string, schema: T, initial: T, options: Options?): Value<T>
	return define({ name = name, kind = "value", perPlayer = false, options = options, schema = schema, initial = initial })
end

-- A key -> value table everyone sees. Changes are sent per key.
function State.map<K, V>(name: string, keySchema: K, valueSchema: V, options: Options?): Map<K, V>
	return define({ name = name, kind = "map", perPlayer = false, options = options, schema = valueSchema, keySchema = keySchema })
end

-- An array everyone sees. Changes are sent as the inserts, removes and sets that made them.
function State.list<T>(name: string, itemSchema: T, options: Options?): List<T>
	return define({ name = name, kind = "list", perPlayer = false, options = options, schema = itemSchema })
end

-- A value per player, seen by that player ("owner", the default) or by everyone.
function State.playerValue<T>(name: string, schema: T, initial: T, options: PlayerOptions?): PlayerValue<T>
	return define({ name = name, kind = "value", perPlayer = true, options = options, schema = schema, initial = initial })
end

-- A key -> value table per player, such as an inventory.
function State.playerMap<K, V>(name: string, keySchema: K, valueSchema: V, options: PlayerOptions?): PlayerMap<K, V>
	return define({ name = name, kind = "map", perPlayer = true, options = options, schema = valueSchema, keySchema = keySchema })
end

-- An array per player, such as a quest log.
function State.playerList<T>(name: string, itemSchema: T, options: PlayerOptions?): PlayerList<T>
	return define({ name = name, kind = "list", perPlayer = true, options = options, schema = itemSchema })
end

-- State derived from other state by a function. It is never sent: each side computes it from its
-- own copy. It recomputes when any state the function read changes.
function State.computed<T>(compute: () -> T): Computed<T>
	return Computed.new(compute)
end

-- Sends every pending change now instead of at the end of the frame, e.g. before firing an event
-- whose listeners expect to see the new state.
function State.flush()
	Store.flush()
end

-- For tests: every state back to its initial value, everywhere, with observers dropped.
function State.reset()
	Store.reset()
end

return State
