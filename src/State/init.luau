--!strict

-- Server-authoritative state replicated to clients. Define states in shared modules (like network
-- objects); the server writes, both sides read and observe. Changes made in one frame go out as one
-- message per changed state, and collections send only what changed.

local Computed = require("@self/Computed")
local List = require("@self/List")
local Map = require("@self/Map")
local Meter = require("@self/Meter")
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
	name: string,
	-- The serverEvent that carries this state, for middleware such as Hydrogen.logger.
	event: Event,
	get: (self: Value<T>) -> T,
	set: (self: Value<T>, value: T) -> (),
	update: (self: Value<T>, transform: (current: T) -> T) -> (),
	-- Calls observer with the value now and on every change. Returns a disconnect function.
	observe: (self: Value<T>, observer: (value: T, previous: T?) -> ()) -> Disconnect,
}

export type Map<K, V> = {
	name: string,
	event: Event,
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
	name: string,
	event: Event,
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
	name: string,
	event: Event,
	get: (self: PlayerValue<T>, player: Player) -> T,
	set: (self: PlayerValue<T>, player: Player, value: T) -> (),
	update: (self: PlayerValue<T>, player: Player, transform: (current: T) -> T) -> (),
	observe: (self: PlayerValue<T>, player: Player, observer: (value: T, previous: T?) -> ()) -> Disconnect,
	-- Every player's value: called now for each player whose value exists here, then on each change.
	observeAll: (self: PlayerValue<T>, observer: (player: Player, value: T, previous: T?) -> ()) -> Disconnect,
}

export type PlayerMap<K, V> = {
	name: string,
	event: Event,
	get: (self: PlayerMap<K, V>, player: Player, key: K) -> V?,
	all: (self: PlayerMap<K, V>, player: Player) -> { [K]: V },
	size: (self: PlayerMap<K, V>, player: Player) -> number,
	set: (self: PlayerMap<K, V>, player: Player, key: K, value: V?) -> (),
	remove: (self: PlayerMap<K, V>, player: Player, key: K) -> (),
	update: (self: PlayerMap<K, V>, player: Player, key: K, transform: (current: V?) -> V?) -> (),
	replace: (self: PlayerMap<K, V>, player: Player, entries: { [K]: V }) -> (),
	clear: (self: PlayerMap<K, V>, player: Player) -> (),
	observe: (self: PlayerMap<K, V>, player: Player, observer: (entries: { [K]: V }) -> ()) -> Disconnect,
	observeAll: (self: PlayerMap<K, V>, observer: (player: Player, entries: { [K]: V }) -> ()) -> Disconnect,
	observeKey: (self: PlayerMap<K, V>, player: Player, key: K, observer: (value: V?) -> ()) -> Disconnect,
	onChange: (self: PlayerMap<K, V>, player: Player, listener: (key: K, value: V?, previous: V?) -> ()) -> Disconnect,
}

export type PlayerList<T> = {
	name: string,
	event: Event,
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
	observeAll: (self: PlayerList<T>, observer: (player: Player, items: { T }) -> ()) -> Disconnect,
}

export type Computed<T> = Computed.Computed<T>

-- Where a meter stops: its min or its max.
export type MeterLimit = "min" | "max"

export type MeterOptions = {
	-- Defaults to 0.
	min: number?,
	max: number,
	-- The starting value. Defaults to max.
	value: number?,
	-- Units per second the value starts moving at; negative drains. Defaults to 0.
	rate: number?,
	-- Seconds of past values the server keeps for getAt, e.g. 1.5. Off by default.
	history: number?,
	encode: boolean?,
}

export type PlayerMeterOptions = {
	min: number?,
	max: number,
	value: number?,
	rate: number?,
	-- Defaults to "owner".
	visibleTo: VisibleTo?,
	-- Lets the owning client show predictRate / predictAdd before the server answers.
	predict: boolean?,
	-- Seconds a prediction shows if no update from the server arrives. Defaults to 1.
	predictTimeout: number?,
	-- Seconds of past values the server keeps for getAt, e.g. 1.5. Off by default.
	history: number?,
	encode: boolean?,
}

export type Meter = {
	name: string,
	event: Event,
	-- The value now, worked out from the last change, the rate and Clock.serverNow(), within
	-- [min, max]. Costs a little arithmetic; call it every frame for UI.
	get: (self: Meter) -> number,
	-- Server, needs the history option: the value at a past server time, such as a client's
	-- Clock.serverNow() stamp checked by Guards.timestamp. nil if older than history.
	getAt: (self: Meter, serverTime: number) -> number?,
	-- Units per second.
	getRate: (self: Meter) -> number,
	getRange: (self: Meter) -> (number, number),
	-- An instant change, clamped. The rate carries on from the new value.
	set: (self: Meter, value: number) -> (),
	add: (self: Meter, delta: number) -> (),
	-- The value carries on from where it is now at the new rate.
	setRate: (self: Meter, rate: number) -> (),
	setRange: (self: Meter, min: number, max: number) -> (),
	-- Calls observer with the value and rate now, then on every change (a write, an update
	-- arriving, a prediction). Not as time passes: read get() for that.
	observe: (self: Meter, observer: (value: number, rate: number) -> ()) -> Disconnect,
	-- Calls listener each time the value arrives at its min or max, by its rate (on time, with
	-- one timer) or by a change. Not called for where it is when connected.
	onLimit: (self: Meter, listener: (limit: MeterLimit) -> ()) -> Disconnect,
}

export type PlayerMeter = {
	name: string,
	event: Event,
	get: (self: PlayerMeter, player: Player) -> number,
	getAt: (self: PlayerMeter, player: Player, serverTime: number) -> number?,
	getRate: (self: PlayerMeter, player: Player) -> number,
	getRange: (self: PlayerMeter, player: Player) -> (number, number),
	set: (self: PlayerMeter, player: Player, value: number) -> (),
	add: (self: PlayerMeter, player: Player, delta: number) -> (),
	setRate: (self: PlayerMeter, player: Player, rate: number) -> (),
	setRange: (self: PlayerMeter, player: Player, min: number, max: number) -> (),
	-- Server: sends the meter again though nothing changed, so the owner's prediction is
	-- replaced at once, e.g. after turning down the request it predicted.
	sync: (self: PlayerMeter, player: Player) -> (),
	-- Owning client, with predict = true: shows the new rate (or instant change) at once, until
	-- the next update from the server replaces it or predictTimeout passes. Changes nothing on
	-- the server: send a clientEvent so the server makes the real change.
	predictRate: (self: PlayerMeter, player: Player, rate: number) -> (),
	predictAdd: (self: PlayerMeter, player: Player, delta: number) -> (),
	observe: (self: PlayerMeter, player: Player, observer: (value: number, rate: number) -> ()) -> Disconnect,
	observeAll: (self: PlayerMeter, observer: (player: Player, value: number, rate: number) -> ()) -> Disconnect,
	onLimit: (self: PlayerMeter, player: Player, listener: (limit: MeterLimit) -> ()) -> Disconnect,
}

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

local function finite(value: any): boolean
	return type(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function describe(value: any): string
	if value ~= value then
		return "NaN"
	elseif type(value) == "number" then
		return tostring(value)
	end
	return typeof(value)
end

local function assertFinite(state: any, value: any, method: string)
	if not finite(value) then
		error(`[HYDROGEN] State {state.name}: {method} expects a finite number, got {describe(value)}`, 4)
	end
end

--------------------------------------------------------------------------------
-- Operations, written once with a player argument (nil for global state).
--------------------------------------------------------------------------------

type Ops = { [string]: (state: any, player: Player?, ...any) -> ...any }

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

local MeterOps: Ops = {}

function MeterOps.get(state, player)
	return Meter.get(state, player)
end

function MeterOps.getAt(state, player, serverTime)
	if Store.context() ~= Store.SERVER then
		error(`[HYDROGEN] State {state.name}: getAt reads the server's past values and runs on the server only; a client reads its meter with get()`, 3)
	end
	if state.meter.history == 0 then
		local constructor = if state.perPlayer then "playerMeter" else "meter"
		error(
			`[HYDROGEN] State {state.name}: getAt needs history in the meter options, e.g. State.{constructor}("{state.name}", \{ max = 100, history = 1.5 }); make it at least Guards.timestamp's window (maxPing + tolerance, 1.2 s by default)`,
			3
		)
	end
	if not finite(serverTime) then
		error(`[HYDROGEN] State {state.name}: getAt expects a server time (a finite number from Clock.serverNow()), got {describe(serverTime)}`, 3)
	end
	return Meter.getAt(state, player, serverTime)
end

function MeterOps.getRate(state, player)
	return Meter.getRate(state, player)
end

function MeterOps.getRange(state, player)
	return Meter.getRange(state, player)
end

function MeterOps.set(state, player, value)
	writable(state)
	assertFinite(state, value, "set")
	Meter.set(state, player, value)
	return nil
end

function MeterOps.add(state, player, delta)
	writable(state)
	assertFinite(state, delta, "add")
	Meter.add(state, player, delta)
	return nil
end

function MeterOps.setRate(state, player, rate)
	writable(state)
	assertFinite(state, rate, "setRate")
	Meter.setRate(state, player, rate)
	return nil
end

function MeterOps.setRange(state, player, min, max)
	writable(state)
	assertFinite(state, min, "setRange")
	assertFinite(state, max, "setRange")
	if min > max then
		error(`[HYDROGEN] State {state.name}: setRange got min ({min}) greater than max ({max})`, 3)
	end
	Meter.setRange(state, player, min, max)
	return nil
end

function MeterOps.observe(state, player, observer)
	return Meter.observe(state, player, observer)
end

function MeterOps.onLimit(state, player, listener)
	if type(listener) ~= "function" then
		error(`[HYDROGEN] State {state.name}: onLimit expects a function, got {typeof(listener)}`, 3)
	end
	return Meter.onLimit(state, player, listener)
end

-- Checks a prediction may run here: on the client that owns the meter. Returns its context.
local function predicting(state: any, player: Player, method: string, serverMethod: string): any
	if not state.meter.predict then
		error(`[HYDROGEN] State {state.name}: {method} needs predict = true in the playerMeter options`, 4)
	end
	local ctx = Store.context()
	if ctx == Store.SERVER then
		error(`[HYDROGEN] State {state.name}: {method} runs on the client that owns the meter; the server changes it with {serverMethod}`, 4)
	end
	if Store.localUserId(ctx) ~= player.UserId then
		error(`[HYDROGEN] State {state.name}: a client can only predict its own meter; pass Players.LocalPlayer, got {player.Name}`, 4)
	end
	return ctx
end

-- Only per-player meters: the owning client predicts, and the server can resend to correct it.
local PlayerMeterOps: Ops = table.clone(MeterOps)

function PlayerMeterOps.sync(state, player)
	writable(state)
	Meter.sync(state, player)
	return nil
end

function PlayerMeterOps.predictRate(state, player, rate)
	local ctx = predicting(state, player :: Player, "predictRate", "setRate")
	assertFinite(state, rate, "predictRate")
	Meter.predict(state, ctx, player :: Player, rate, nil)
	return nil
end

function PlayerMeterOps.predictAdd(state, player, delta)
	local ctx = predicting(state, player :: Player, "predictAdd", "add")
	assertFinite(state, delta, "predictAdd")
	Meter.predict(state, ctx, player :: Player, nil, delta)
	return nil
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
			local result, second = op(self, nil, a, b)
			return result, second
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
			local result, second = op(self, player, a, b)
			return result, second
		end
	end
	return methods
end

-- observeAll takes no player: it covers all of them.
local function withObserveAll(methods: { [string]: any }, observeAll: (state: any, observer: (...any) -> ()) -> () -> ())
	methods.observeAll = function(self: any, observer: (...any) -> ())
		return observeAll(self, observer)
	end
	return methods
end

local metatables = {
	value = { __index = globalMethods(ValueOps) },
	map = { __index = globalMethods(MapOps) },
	list = { __index = globalMethods(ListOps) },
	meter = { __index = globalMethods(MeterOps) },
	playerValue = { __index = withObserveAll(playerMethods(ValueOps), Value.observeAll) },
	playerMap = { __index = withObserveAll(playerMethods(MapOps), Map.observeAll) },
	playerList = { __index = withObserveAll(playerMethods(ListOps), List.observeAll) },
	playerMeter = { __index = withObserveAll(playerMethods(PlayerMeterOps), Meter.observeAll) },
}

--------------------------------------------------------------------------------
-- Definitions
--------------------------------------------------------------------------------

local kinds = {
	value = Value :: Store.Kind,
	map = Map :: Store.Kind,
	list = List :: Store.Kind,
	meter = (Meter :: any) :: Store.Kind,
}

local function identity(value: any): any
	return value
end

type Spec = {
	name: any,
	kind: "value" | "map" | "list" | "meter",
	perPlayer: boolean,
	options: any,
	schema: any?,
	keySchema: any?,
	initial: any?,
}

local METER_OPTIONS = { "min", "max", "value", "rate", "history", "encode" }
local PLAYER_METER_OPTIONS = { "min", "max", "value", "rate", "history", "visibleTo", "predict", "predictTimeout", "encode" }

-- Checks a meter's options. Errors are raised at the caller of State.meter / State.playerMeter:
-- meterConfig <- define <- constructor <- caller.
local function meterConfig(name: string, options: { [any]: any }, perPlayer: boolean): Meter.Config
	local allowed = if perPlayer then PLAYER_METER_OPTIONS else METER_OPTIONS
	for key in options do
		if not table.find(allowed, key) then
			if not perPlayer and (key == "predict" or key == "predictTimeout") then
				error(`[HYDROGEN] State {name}: {key} only applies to State.playerMeter (a client predicts its own meter)`, 4)
			end
			error(`[HYDROGEN] State {name}: unknown meter option {tostring(key)}; meters take {table.concat(allowed, ", ")}`, 4)
		end
	end

	-- number <- meterConfig <- define <- constructor <- caller
	local function number(key: string, fallback: number?): number
		local value = options[key]
		if value == nil and fallback ~= nil then
			return fallback
		end
		if not finite(value) then
			local example = if key == "max" then ", e.g. { max = 100 }" else ""
			error(`[HYDROGEN] State {name}: meter option {key} must be a finite number{example}, got {describe(value)}`, 5)
		end
		return value
	end

	local min = number("min", 0)
	local max = number("max", nil)
	if min > max then
		error(`[HYDROGEN] State {name}: meter min ({min}) is greater than max ({max})`, 4)
	end
	local value = number("value", max)
	if value < min or value > max then
		error(`[HYDROGEN] State {name}: the initial value {value} is outside the meter's range ({min} to {max})`, 4)
	end
	local rate = number("rate", 0)

	local predict = options.predict
	if predict ~= nil and type(predict) ~= "boolean" then
		error(`[HYDROGEN] State {name}: predict must be true or false, got {typeof(predict)}`, 4)
	end
	local timeout = options.predictTimeout
	if timeout ~= nil then
		if predict ~= true then
			error(`[HYDROGEN] State {name}: predictTimeout only applies with predict = true`, 4)
		end
		if not finite(timeout) or timeout <= 0 then
			error(`[HYDROGEN] State {name}: predictTimeout must be a positive number of seconds, got {describe(timeout)}`, 4)
		end
	end

	local history = options.history
	if history ~= nil and (not finite(history) or history <= 0) then
		error(`[HYDROGEN] State {name}: history must be a positive number of seconds, e.g. history = 1.5, got {describe(history)}`, 4)
	end

	return {
		min = min,
		max = max,
		value = value,
		rate = rate,
		predict = predict == true,
		predictTimeout = timeout or 1,
		history = history or 0,
		resting = { value = value, rate = 0, min = min, max = max, at = 0, started = true },
	}
end

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
		error(`[HYDROGEN] State {name}: visibleTo only applies to per-player state (playerValue, playerMap, playerList, playerMeter)`, 3)
	end
	if visibleTo ~= nil and visibleTo ~= "owner" and visibleTo ~= "everyone" then
		error(`[HYDROGEN] State {name}: visibleTo must be "owner" or "everyone", got {visibleTo}`, 3)
	end
	local public = not spec.perPlayer or visibleTo == "everyone"

	local serializer = options.serializer
	if serializer ~= nil and (type(serializer) ~= "table" or type(serializer.serialize) ~= "function" or type(serializer.deserialize) ~= "function" or serializer.schema == nil) then
		error(`[HYDROGEN] State {name}: serializer needs schema, serialize and deserialize`, 3)
	end

	local meter = if spec.kind == "meter" then meterConfig(name, options, spec.perPlayer) else nil
	local check = if meter then nil else Wire.build(spec.schema)
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
		everyone = {},
		watchers = {},
		_check = check,
		_keyCheck = if spec.keySchema ~= nil then Wire.build(spec.keySchema) else nil,
		meter = meter,
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

-- A number that moves at a steady rate between a min and a max, which everyone sees: a shared
-- objective's heat, a zone's charge. Only changes are sent; get() works the value out for now.
function State.meter(name: string, options: MeterOptions): Meter
	return define({ name = name, kind = "meter", perPlayer = false, options = options })
end

-- A meter per player, such as stamina, mana or hunger, seen by that player ("owner", the
-- default) or by everyone. With predict = true the owning client can show a change at once.
function State.playerMeter(name: string, options: PlayerMeterOptions): PlayerMeter
	return define({ name = name, kind = "meter", perPlayer = true, options = options })
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
