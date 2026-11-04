--!strict

-- The engine behind Hydrogen.Input: contexts, actions, routing keys to actions by priority,
-- rebinding and the current device. Raw input arrives through press, release and move, from
-- UserInputService in a game (Device.luau) or from Input.simulate in tests, so both run this code.

local Clock = require("../Clock")
local Log = require("../Log")
local Keys = require("./Keys")
local Types = require("./Types")

type Spec = Keys.Spec
type Device = Types.Device
type Kind = Types.Kind
type Listener = (...any) -> ()

export type Hold = { seconds: number, listener: () -> () }

export type ContextState = {
	name: string,
	priority: number,
	sink: boolean,
	_initial: boolean,
	_base: boolean,
	_enablers: number,
	_disablers: number,
	_active: boolean,
	_order: number,
	-- Bumped by reset, so enableFor and disableFor handles from before it do nothing.
	_epoch: number,
	_actions: { ActionState },
}

export type ActionState = {
	name: string,
	kind: Kind,
	context: ContextState,
	_order: number,
	_defaults: { [string]: { Spec } },
	_bindings: { [string]: { Spec } },
	_deadzone: number?,
	_touch: Types.TouchOptions?,
	_value: any,
	-- Button: what is pressing it (a key name or a Source), and how many.
	_sources: { [any]: boolean },
	_pressed: number,
	-- Axis and vector2: values set through Input.source.
	_sourceValues: { [any]: any },
	-- Mouse movement or wheel since the last frame.
	_delta: any?,
	_began: { Listener },
	_ended: { Listener },
	_changed: { Listener },
	_holds: { Hold },
	_holdThreads: { thread }?,
	_glyphObservers: { Listener },
	-- Bumped on every begin, so a hold timer from an earlier press can't fire.
	_generation: number,
}

type Route = { list: { ActionState }, set: { [ActionState]: boolean } }
type Found = { action: ActionState, spec: Spec }

-- Devices that have bindings. Touch drives actions through on-screen buttons instead.
local DEVICES = { "keyboard", "gamepad" }
local DEFAULT_DEADZONE = 0.15

local Core = {}

local ContextMethods = {}
local contextMetatable = { __index = ContextMethods }
local ActionMethods = {}
local actionMetatable = { __index = ActionMethods }

-- Set by the modules around this one, so none of them require each other in a cycle.
-- Called after the first definition: starts the real input source on a client.
Core.onDefine = nil :: (() -> ())?
-- Called when the device, a context or the touch actions change: updates the touch buttons.
Core.onTouchChange = nil :: (() -> ())?
-- Called by reset: removes the touch buttons.
Core.onReset = nil :: (() -> ())?
-- The engine's text and image for a key (keyboard layout, platform button art), in a game.
Core.engineGlyph = nil :: ((key: string) -> (string?, string?))?
-- The on-screen button made for an action.
Core.touchButton = nil :: ((action: ActionState) -> GuiButton?)?

function Core.isServer(): boolean
	local ok, server = pcall(function()
		return game:GetService("RunService"):IsServer()
	end)
	return ok and server == true
end

local contexts: { ContextState } = {}
local contextNames: { [string]: ContextState } = {}
local actions: { ActionState } = {}
local actionNames: { [string]: ActionState } = {}
local defined = 0

-- Key -> actions with a binding that uses it. Rebuilt after a definition or rebind.
local keyIndex: { [string]: { ActionState } }? = nil
-- Key -> the actions it reaches now, given enabled contexts and sinking. Cleared on any change.
local routes: { [string]: Route } = {}
local EMPTY_ROUTE: Route = { list = {}, set = {} }

local down: { [string]: boolean } = {}
local analog: { [string]: any } = {}
-- Key -> the button actions its press began, released with it whatever has changed since.
local claims: { [string]: { ActionState } } = {}

local device: Device = "keyboard"
local deviceListeners: { Listener } = {}
local bindingListeners: { Listener } = {}
local glyphProvider: Types.GlyphProvider? = nil
local capture: { listener: (key: any) -> (), device: Device? }? = nil
local warnedServer = false

Core.config = {
	deadzone = DEFAULT_DEADZONE,
	touchParent = nil :: Instance?,
}

-- Listeners run in a reused thread, so one that yields or errors can't stop the others.
local freeRunner: thread? = nil

local function runListener(label: string, listener: Listener, ...: any)
	local runner = freeRunner
	freeRunner = nil
	local ok, err = xpcall(listener, debug.traceback, ...)
	if not ok then
		Log.warn(`[HYDROGEN] Input {label} listener errored: {err}`)
	end
	freeRunner = runner
end

local function runnerLoop(...: any)
	runListener(...)
	while true do
		runListener(coroutine.yield())
	end
end

local function call(label: string, listener: Listener, ...: any)
	if freeRunner == nil then
		freeRunner = coroutine.create(runnerLoop)
	end
	task.spawn(freeRunner :: thread, label, listener, ...)
end

local function fire(list: { Listener }, label: string, ...: any)
	if #list == 0 then
		return
	end
	for _, listener in table.clone(list) do
		-- Skips listeners an earlier one disconnected.
		if table.find(list, listener) then
			call(label, listener, ...)
		end
	end
end

local function zero(kind: Kind): any
	if kind == "button" then
		return false
	elseif kind == "axis" then
		return 0
	end
	return Vector2.zero
end

local function isZero(value: any): boolean
	return value == false or value == 0 or value == nil or (typeof(value) == "Vector2" and value.Magnitude == 0)
end

local function copyBindings(from: { [string]: { Spec } }): { [string]: { Spec } }
	local copy = {}
	for _, name in DEVICES do
		copy[name] = table.clone(from[name] or {})
	end
	return copy
end

local function index(): { [string]: { ActionState } }
	local existing = keyIndex
	if existing then
		return existing
	end
	local built: { [string]: { ActionState } } = {}
	for _, action in actions do
		for _, name in DEVICES do
			for _, spec in action._bindings[name] do
				for _, part in spec.parts do
					local list = built[part]
					if not list then
						list = {}
						built[part] = list
					end
					if not table.find(list, action) then
						table.insert(list, action)
					end
				end
			end
		end
	end
	keyIndex = built
	return built
end

-- The actions a key reaches: enabled contexts from the highest priority down, stopping below
-- a context that binds the key and sinks. Contexts with equal priority all receive it.
local function route(key: string): Route
	local cached = routes[key]
	if cached then
		return cached
	end
	local candidates = index()[key]
	if not candidates then
		routes[key] = EMPTY_ROUTE
		return EMPTY_ROUTE
	end

	local result: Route = { list = {}, set = {} }
	local stopBelow: number? = nil
	for _, context in contexts do
		if stopBelow and context.priority < stopBelow then
			break
		end
		if context._active then
			local matched = false
			for _, action in context._actions do
				if table.find(candidates, action) then
					matched = true
					table.insert(result.list, action)
					result.set[action] = true
				end
			end
			if matched and context.sink then
				stopBelow = context.priority
			end
		end
	end
	routes[key] = result
	return result
end

local function stopHolds(action: ActionState)
	local threads = action._holdThreads
	if threads then
		action._holdThreads = nil
		for _, thread in threads do
			-- The timer may be the thread releasing the action.
			pcall(Clock.cancel, thread)
		end
	end
end

local function startHolds(action: ActionState)
	if #action._holds == 0 then
		return
	end
	local generation = action._generation
	local threads = {}
	for _, hold in action._holds do
		table.insert(
			threads,
			Clock.delay(hold.seconds, function()
				if action._generation == generation and not isZero(action._value) and table.find(action._holds, hold) then
					call(`action {action.name} onHold`, hold.listener)
				end
			end)
		)
	end
	action._holdThreads = threads
end

local function setValue(action: ActionState, value: any)
	local previous = action._value
	if previous == value then
		return
	end
	action._value = value
	local wasZero, nowZero = isZero(previous), isZero(value)
	fire(action._changed, `action {action.name} onChanged`, value, previous)
	if wasZero and not nowZero then
		action._generation += 1
		startHolds(action)
		fire(action._began, `action {action.name} onBegan`, value)
	elseif nowZero and not wasZero then
		stopHolds(action)
		fire(action._ended, `action {action.name} onEnded`)
	end
end

local function addSource(action: ActionState, token: any)
	if action._sources[token] then
		return
	end
	action._sources[token] = true
	action._pressed += 1
	if action._pressed == 1 then
		setValue(action, true)
	end
end

local function removeSource(action: ActionState, token: any)
	if not action._sources[token] then
		return
	end
	action._sources[token] = nil
	action._pressed -= 1
	if action._pressed == 0 then
		setValue(action, false)
	end
end

local function applyDeadzone(value: Vector2, deadzone: number): Vector2
	local magnitude = value.Magnitude
	if magnitude <= deadzone then
		return Vector2.zero
	end
	-- Rescaled, so the value still starts at 0 just past the dead zone and reaches 1.
	return value.Unit * math.min((magnitude - deadzone) / (1 - deadzone), 1)
end

local function contribution(action: ActionState, spec: Spec, deadzone: number): any
	local function reaches(key: string?): boolean
		return key ~= nil and route(key).set[action] == true
	end
	local function pressed(key: string?): number
		return if key and down[key] and reaches(key) then 1 else 0
	end

	local key = spec.key
	if key then
		if not reaches(key) or Keys.isDelta(key) then
			return zero(action.kind)
		end
		if Keys.isStick(key) then
			local stick = applyDeadzone(analog[key] or Vector2.zero, deadzone)
			if action.kind == "vector2" then
				return stick * spec.scale
			end
			return (if spec.axis == "x" then stick.X else stick.Y) * spec.scale
		elseif Keys.isTrigger(key) then
			-- A trigger pressed without an analog value (a simulated press) counts as fully down.
			local amount = analog[key] or (if down[key] then 1 else 0)
			return amount * spec.scale
		end
		return (if down[key] then 1 else 0) * spec.scale
	end

	if action.kind == "vector2" then
		local x = pressed(spec.right) - pressed(spec.left)
		local y = pressed(spec.up) - pressed(spec.down)
		return Vector2.new(x, y) * spec.scale
	end
	return (pressed(spec.positive) - pressed(spec.negative)) * spec.scale
end

local function recompute(action: ActionState)
	if action.kind == "button" then
		return
	end
	local active = action.context._active
	local held: any = zero(action.kind)
	if active then
		local deadzone = action._deadzone or Core.config.deadzone
		for _, name in DEVICES do
			for _, spec in action._bindings[name] do
				held += contribution(action, spec, deadzone)
			end
		end
		for _, value in action._sourceValues do
			held += value
		end
	end

	if action.kind == "axis" then
		held = math.clamp(held, -1, 1)
	elseif held.Magnitude > 1 then
		held = held.Unit
	end
	if active and action._delta ~= nil then
		held += action._delta
	end
	setValue(action, held)
end

local function refreshAxes(key: string)
	local list = index()[key]
	if list then
		for _, action in list do
			if action.kind ~= "button" then
				recompute(action)
			end
		end
	end
end

local function notifyTouch()
	local onTouchChange = Core.onTouchChange
	if onTouchChange then
		onTouchChange()
	end
end

-- After contexts or bindings change: actions a held key no longer reaches are released, and
-- axes are recomputed from what is held now. Button presses never begin again by themselves.
local function reconcile()
	routes = {}
	for key, list in table.clone(claims) do
		local reached = route(key)
		for position = #list, 1, -1 do
			local action = list[position]
			if not reached.set[action] then
				table.remove(list, position)
				removeSource(action, key)
			end
		end
		if #list == 0 and claims[key] == list then
			claims[key] = nil
		end
	end
	for _, action in table.clone(actions) do
		if action.kind == "button" then
			if not action.context._active and action._pressed > 0 then
				for token in table.clone(action._sources) do
					removeSource(action, token)
				end
			end
		else
			recompute(action)
		end
	end
	notifyTouch()
end

local function modifierHeld(name: string): boolean
	if down[name] then
		return true
	end
	local twin = Keys.twin(name)
	return twin ~= nil and down[twin] == true
end

-- The button actions a press of key begins. When several bindings match, only those with the
-- most modifiers held fire, so Ctrl+S doesn't also press S.
local function matchButtons(key: string): { ActionState }
	local matched: { ActionState } = {}
	local counts: { [ActionState]: number } = {}
	local best = -1
	local keyDevice = Keys.device(key)
	for _, action in route(key).list do
		if action.kind == "button" then
			local actionBest = -1
			for _, spec in action._bindings[keyDevice] do
				if spec.key == key then
					local count = 0
					local satisfied = true
					if spec.modifiers then
						for _, modifier in spec.modifiers do
							if modifierHeld(modifier) then
								count += 1
							else
								satisfied = false
								break
							end
						end
					end
					if satisfied and count > actionBest then
						actionBest = count
					end
				end
			end
			if actionBest >= 0 then
				table.insert(matched, action)
				counts[action] = actionBest
				best = math.max(best, actionBest)
			end
		end
	end
	local result = {}
	for _, action in matched do
		if counts[action] == best then
			table.insert(result, action)
		end
	end
	return result
end

function Core.press(key: string)
	if down[key] then
		return
	end
	down[key] = true

	local waiting = capture
	if waiting and not Keys.isStick(key) and not Keys.isDelta(key) and (waiting.device == nil or waiting.device == Keys.device(key)) then
		-- Captured for rebinding: nothing else sees this press.
		capture = nil
		call("captureKey", waiting.listener, Keys.enum(key))
		return
	end

	for _, action in matchButtons(key) do
		local list = claims[key]
		if not list then
			list = {}
			claims[key] = list
		end
		table.insert(list, action)
		addSource(action, key)
	end
	refreshAxes(key)
end

function Core.release(key: string)
	down[key] = nil
	local list = claims[key]
	if list then
		claims[key] = nil
		for _, action in list do
			removeSource(action, key)
		end
	end
	refreshAxes(key)
end

local stopDeltaFrame: (() -> ())? = nil
local deltaActions: { [ActionState]: boolean } = {}

-- Mouse deltas last until the end of the frame they arrived in; the clock is only used while
-- the mouse moves.
local function scheduleDeltaReset()
	if stopDeltaFrame or next(deltaActions) == nil then
		return
	end
	stopDeltaFrame = Clock.heartbeat(function()
		local stop = stopDeltaFrame
		stopDeltaFrame = nil
		if stop then
			stop()
		end
		local finished = deltaActions
		deltaActions = {}
		for action in finished do
			action._delta = nil
			recompute(action)
		end
	end)
end

function Core.move(key: string, value: any)
	if Keys.isDelta(key) then
		for _, action in route(key).list do
			if action.kind ~= "button" then
				local delta: any = nil
				for _, name in DEVICES do
					for _, spec in action._bindings[name] do
						if spec.key == key then
							delta = (delta or zero(action.kind)) + value * spec.scale
						end
					end
				end
				if delta ~= nil then
					action._delta = (action._delta or zero(action.kind)) + delta
					deltaActions[action] = true
					recompute(action)
				end
			end
		end
		scheduleDeltaReset()
		return
	end
	analog[key] = if isZero(value) then nil else value
	refreshAxes(key)
end

-- Lets go of every key and stick, e.g. when the window loses focus mid-press.
function Core.releaseAll()
	for key in table.clone(down) do
		Core.release(key)
	end
	for key in table.clone(analog) do
		analog[key] = nil
		refreshAxes(key)
	end
end

-- Device and glyphs

local function glyphFor(action: ActionState, name: Device): Types.Glyph?
	if name == "touch" then
		local touch = action._touch
		if touch then
			return { key = "Touch", device = "touch", text = touch.text or action.name, image = touch.image }
		end
		return nil
	end
	local spec = action._bindings[name][1]
	if not spec then
		return nil
	end
	local key = spec.key or spec.parts[1]

	local provider = glyphProvider
	if provider then
		local ok, result = pcall(provider, key, name)
		if not ok then
			Log.warn(`[HYDROGEN] Input glyph provider errored for {key}: {result}`)
		elseif result ~= nil then
			return result
		end
	end

	local engineGlyph = Core.engineGlyph
	local function text(part: string): string
		if engineGlyph then
			local engineText = engineGlyph(part)
			if engineText then
				return engineText
			end
		end
		return Keys.text(part)
	end

	local label: string
	if spec.key then
		label = text(spec.key)
		if spec.modifiers then
			local parts = {}
			for _, modifier in spec.modifiers do
				table.insert(parts, text(modifier))
			end
			table.insert(parts, label)
			label = table.concat(parts, "+")
		end
	else
		local parts = {}
		for _, part in spec.parts do
			table.insert(parts, text(part))
		end
		label = table.concat(parts, "/")
	end

	local image: string? = nil
	if engineGlyph and not spec.modifiers then
		local _, engineImage = engineGlyph(key)
		image = engineImage
	end
	return { key = key, device = name, text = label, image = image }
end

local function notifyGlyphs(action: ActionState)
	if #action._glyphObservers > 0 then
		fire(action._glyphObservers, `action {action.name} observeGlyph`, glyphFor(action, device))
	end
end

function Core.device(): Device
	return device
end

function Core.setDevice(new: Device)
	if new == device then
		return
	end
	local previous = device
	device = new
	fire(deviceListeners, "onDeviceChanged", new, previous)
	for _, action in actions do
		notifyGlyphs(action)
	end
	notifyTouch()
end

function Core.onDeviceChanged(listener: (device: Device, previous: Device) -> ()): () -> ()
	if type(listener) ~= "function" then
		error(`[HYDROGEN] Input.onDeviceChanged expects a function`, 2)
	end
	table.insert(deviceListeners, listener)
	local list = deviceListeners
	return function()
		local position = table.find(list, listener)
		if position then
			table.remove(list, position)
		end
	end
end

function Core.setGlyphProvider(provider: Types.GlyphProvider?)
	glyphProvider = provider
	for _, action in actions do
		notifyGlyphs(action)
	end
end

function Core.captureKey(listener: (key: any) -> (), only: Device?): () -> ()
	if type(listener) ~= "function" then
		error(`[HYDROGEN] Input.captureKey expects a function`, 2)
	end
	if only ~= nil and only ~= "keyboard" and only ~= "gamepad" then
		error(`[HYDROGEN] Input.captureKey can wait for "keyboard" or "gamepad" keys, not {only}`, 2)
	end
	local waiting = { listener = listener, device = only }
	capture = waiting
	return function()
		if capture == waiting then
			capture = nil
		end
	end
end

-- Definitions

local function sortContexts()
	table.sort(contexts, function(a, b)
		if a.priority ~= b.priority then
			return a.priority > b.priority
		end
		return a._order < b._order
	end)
end

local function checkName(kind: string, name: any, level: number)
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] Input {kind} names must be non-empty strings, got {typeof(name)}`, level + 1)
	end
end

function Core.context(name: string, options: Types.ContextOptions?, level: number): ContextState
	checkName("context", name, level)
	if contextNames[name] then
		error(`[HYDROGEN] Input context {name} is already defined; define each context once in a shared module and require it`, level)
	end
	local settings: { [string]: any } = options or {}
	if type(settings) ~= "table" then
		error(`[HYDROGEN] Input context {name}: options must be a table`, level)
	end
	for field in settings do
		if field ~= "priority" and field ~= "sink" and field ~= "enabled" then
			error(`[HYDROGEN] Input context {name} has no option {field}; it takes priority, sink and enabled`, level)
		end
	end
	local priority = settings.priority or 0
	if type(priority) ~= "number" or priority ~= priority then
		error(`[HYDROGEN] Input context {name}: priority must be a number`, level)
	end
	if settings.sink ~= nil and type(settings.sink) ~= "boolean" then
		error(`[HYDROGEN] Input context {name}: sink must be a boolean`, level)
	end
	if settings.enabled ~= nil and type(settings.enabled) ~= "boolean" then
		error(`[HYDROGEN] Input context {name}: enabled must be a boolean`, level)
	end
	local enabled = settings.enabled ~= false

	defined += 1
	local context: ContextState = setmetatable({
		name = name,
		priority = priority,
		sink = settings.sink == true,
		_initial = enabled,
		_base = enabled,
		_enablers = 0,
		_disablers = 0,
		_active = enabled,
		_order = defined,
		_epoch = 0,
		_actions = {},
	}, contextMetatable) :: any
	table.insert(contexts, context)
	contextNames[name] = context
	sortContexts()
	routes = {}
	return context
end

local OPTIONS: { [Kind]: { [string]: boolean } } = {
	button = { touch = true },
	axis = { deadzone = true },
	vector2 = { deadzone = true },
}

-- level: how far up the stack the user's call is, for errors (3 from a method or Input.button).
function Core.define(context: ContextState, kind: Kind, name: string, bindings: { any }, options: { [string]: any }?, level: number): ActionState
	checkName("action", name, level)
	if actionNames[name] then
		error(`[HYDROGEN] Input action {name} is already defined; action names are unique across contexts (saved bindings use them)`, level)
	end
	if type(bindings) ~= "table" then
		error(`[HYDROGEN] Input action {name}: bindings must be a list, e.g. \{ Enum.KeyCode.E, Enum.KeyCode.ButtonX }`, level)
	end

	local defaults: { [string]: { Spec } } = { keyboard = {}, gamepad = {} }
	for position, binding in bindings do
		local ok, result = pcall(Keys.spec, binding, kind)
		if not ok then
			error(`[HYDROGEN] Input action {name} ({kind}): binding {position}: {result}`, level)
		end
		table.insert(defaults[result.device], result)
	end

	local settings = options or {}
	if type(settings) ~= "table" then
		error(`[HYDROGEN] Input action {name}: options must be a table`, level)
	end
	for field in settings do
		if not OPTIONS[kind][field] then
			if field == "touch" then
				error(`[HYDROGEN] Input action {name}: touch buttons are for button actions; drive a {kind} from your own control with Input.source`, level)
			end
			error(`[HYDROGEN] Input action {name} ({kind}) has no option {field}`, level)
		end
	end

	local touch: Types.TouchOptions? = nil
	if settings.touch == true then
		touch = {}
	elseif type(settings.touch) == "table" then
		touch = table.clone(settings.touch)
	elseif settings.touch ~= nil and settings.touch ~= false then
		error(`[HYDROGEN] Input action {name}: touch must be true or a table of touch options`, level)
	end

	local deadzone = settings.deadzone
	if deadzone ~= nil and (type(deadzone) ~= "number" or deadzone < 0 or deadzone >= 1) then
		error(`[HYDROGEN] Input action {name}: deadzone must be a number from 0 up to (not including) 1`, level)
	end

	defined += 1
	local action: ActionState = setmetatable({
		name = name,
		kind = kind,
		context = context,
		_order = defined,
		_defaults = defaults,
		_bindings = copyBindings(defaults),
		_deadzone = deadzone,
		_touch = touch,
		_value = zero(kind),
		_sources = {},
		_pressed = 0,
		_sourceValues = {},
		_delta = nil,
		_began = {},
		_ended = {},
		_changed = {},
		_holds = {},
		_holdThreads = nil,
		_glyphObservers = {},
		_generation = 0,
	}, actionMetatable) :: any

	table.insert(context._actions, action)
	table.insert(actions, action)
	actionNames[name] = action
	keyIndex = nil
	routes = {}

	local onDefine = Core.onDefine
	if onDefine then
		onDefine()
	end
	if touch then
		notifyTouch()
	end
	return action
end

function Core.isAction(value: any): boolean
	return type(value) == "table" and getmetatable(value) == actionMetatable
end

function Core.action(name: string): ActionState?
	return actionNames[name]
end

function Core.touchActions(): { ActionState }
	local list = {}
	for _, action in actions do
		if action._touch then
			table.insert(list, action)
		end
	end
	return list
end

-- Contexts

local function updateContext(context: ContextState)
	local active = (context._base or context._enablers > 0) and context._disablers == 0
	if active == context._active then
		return
	end
	context._active = active
	reconcile()
end

function ContextMethods.enabled(self: ContextState): boolean
	return self._active
end

function ContextMethods.setEnabled(self: ContextState, enabled: boolean)
	if type(enabled) ~= "boolean" then
		error(`[HYDROGEN] Input context {self.name}: setEnabled expects a boolean`, 2)
	end
	self._base = enabled
	updateContext(self)
end

function ContextMethods.enable(self: ContextState)
	self._base = true
	updateContext(self)
end

function ContextMethods.disable(self: ContextState)
	self._base = false
	updateContext(self)
end

local function counted(context: ContextState, field: "_enablers" | "_disablers", scope: any): () -> ()
	local epoch = context._epoch
	local context_ = context :: any
	context_[field] += 1
	updateContext(context)
	local done = false
	local function undo()
		if done then
			return
		end
		done = true
		if context._epoch ~= epoch then
			return
		end
		context_[field] -= 1
		updateContext(context)
	end
	if scope ~= nil then
		scope:add(undo)
	end
	return undo
end

function ContextMethods.enableFor(self: ContextState, scope: any): () -> ()
	return counted(self, "_enablers", scope)
end

function ContextMethods.disableFor(self: ContextState, scope: any): () -> ()
	return counted(self, "_disablers", scope)
end

function ContextMethods.button(self: ContextState, name: string, bindings: { any }, options: any): ActionState
	return Core.define(self, "button", name, bindings, options, 3)
end

function ContextMethods.axis(self: ContextState, name: string, bindings: { any }, options: any): ActionState
	return Core.define(self, "axis", name, bindings, options, 3)
end

function ContextMethods.vector2(self: ContextState, name: string, bindings: { any }, options: any): ActionState
	return Core.define(self, "vector2", name, bindings, options, 3)
end

function ContextMethods.actions(self: ContextState): { ActionState }
	return table.clone(self._actions)
end

-- Actions

local function warnOnServer(action: ActionState, method: string)
	if not warnedServer and Core.isServer() then
		warnedServer = true
		Log.warn(`[HYDROGEN] Hydrogen.Input is client-only: {action.name}:{method} on the server never fires. Listen from a client system`)
	end
end

local function remover(list: { any }, item: any): () -> ()
	local connected = true
	return function()
		if not connected then
			return
		end
		connected = false
		local position = table.find(list, item)
		if position then
			table.remove(list, position)
		end
	end
end

local function listen(action: ActionState, list: { Listener }, listener: any, method: string): () -> ()
	if type(listener) ~= "function" then
		error(`[HYDROGEN] Input action {action.name}: {method} expects a function`, 3)
	end
	warnOnServer(action, method)
	table.insert(list, listener)
	return remover(list, listener)
end


function ActionMethods.value(self: ActionState): any
	return self._value
end

function ActionMethods.held(self: ActionState): boolean
	return not isZero(self._value)
end

function ActionMethods.onBegan(self: ActionState, listener: any): () -> ()
	return listen(self, self._began, listener, "onBegan")
end

function ActionMethods.onEnded(self: ActionState, listener: any): () -> ()
	return listen(self, self._ended, listener, "onEnded")
end

function ActionMethods.onChanged(self: ActionState, listener: any): () -> ()
	return listen(self, self._changed, listener, "onChanged")
end

function ActionMethods.onHold(self: ActionState, seconds: number, listener: any): () -> ()
	if type(seconds) ~= "number" or seconds < 0 or seconds ~= seconds then
		error(`[HYDROGEN] Input action {self.name}: onHold expects seconds (a non-negative number), then a function`, 2)
	end
	if type(listener) ~= "function" then
		error(`[HYDROGEN] Input action {self.name}: onHold expects a function after the seconds`, 2)
	end
	warnOnServer(self, "onHold")
	local hold: Hold = { seconds = seconds, listener = listener }
	table.insert(self._holds, hold)
	return remover(self._holds, hold)
end

local function checkDevice(action: ActionState, name: any, method: string, level: number)
	if name ~= "keyboard" and name ~= "gamepad" then
		error(`[HYDROGEN] Input action {action.name}: {method} takes "keyboard" or "gamepad", not {tostring(name)}`, level + 1)
	end
end

function ActionMethods.bindings(self: ActionState, name: Device?): { any }
	local list = {}
	for _, deviceName in DEVICES do
		if name == nil or name == deviceName then
			for _, spec in self._bindings[deviceName] do
				table.insert(list, Keys.public(spec))
			end
		end
	end
	return list
end

local function specFor(action: ActionState, binding: any, level: number): Spec
	local ok, result = pcall(Keys.spec, binding, action.kind)
	if not ok then
		error(`[HYDROGEN] Input action {action.name} ({action.kind}): {result}`, level + 1)
	end
	return result
end

local function canBothReceive(a: ContextState, b: ContextState): boolean
	if a == b or a.priority == b.priority then
		return true
	end
	local higher = if a.priority > b.priority then a else b
	return not higher.sink
end

-- What a press must match to trigger a binding: each key, with its modifiers.
local function triggers(spec: Spec): { string }
	if spec.key then
		if spec.modifiers then
			return { `{table.concat(spec.modifiers, "+")}+{spec.key}` }
		end
		return { spec.key }
	end
	return spec.parts
end

local function overlaps(a: Spec, b: Spec): boolean
	for _, x in triggers(a) do
		for _, y in triggers(b) do
			if x == y then
				return true
			end
		end
	end
	return false
end

-- Other bindings a press of spec's keys would also trigger, with both contexts enabled.
local function findConflicts(action: ActionState, spec: Spec, slot: number): { Found }
	local found: { Found } = {}
	for _, other in actions do
		if canBothReceive(action.context, other.context) then
			for position, existing in other._bindings[spec.device] do
				if not (other == action and position == slot) and overlaps(spec, existing) then
					table.insert(found, { action = other, spec = existing })
				end
			end
		end
	end
	return found
end

local function publicConflicts(found: { Found }): { Types.Conflict }
	local list = {}
	for _, entry in found do
		table.insert(list, {
			action = entry.action :: any,
			binding = Keys.public(entry.spec),
			device = entry.spec.device,
			slot = table.find(entry.action._bindings[entry.spec.device], entry.spec) or 0,
		})
	end
	return list
end

local function bindingsChanged(changed: { ActionState })
	keyIndex = nil
	reconcile()
	for _, action in changed do
		notifyGlyphs(action)
	end
	fire(bindingListeners, "onBindingsChanged")
end

local function checkSlot(action: ActionState, slot: any, method: string)
	if slot ~= nil and (type(slot) ~= "number" or slot < 1 or slot % 1 ~= 0) then
		error(`[HYDROGEN] Input action {action.name}: {method} slot must be a whole number from 1`, 3)
	end
end

function ActionMethods.conflicts(self: ActionState, binding: any, slot: number?): { Types.Conflict }
	checkSlot(self, slot, "conflicts")
	local spec = specFor(self, binding, 2)
	return publicConflicts(findConflicts(self, spec, slot or 1))
end

local MODES = { reject = true, swap = true, unbind = true, allow = true }

local function fits(spec: Spec, kind: Kind): boolean
	return (pcall(Keys.spec, Keys.save(spec), kind))
end

local COMPOSITE_FIELDS = { "up", "down", "left", "right", "positive", "negative" }

-- A composite with its clashing directions set to part, or removed if part can't be one.
-- nil when no direction is left.
local function replaceParts(spec: Spec, kind: Kind, clashing: { string }, part: string?): Spec?
	local function attempt(with: string?): Spec?
		local saved = Keys.save(spec)
		local remaining = 0
		for _, field in COMPOSITE_FIELDS do
			if saved[field] and table.find(clashing, saved[field]) then
				saved[field] = with
			end
			if saved[field] then
				remaining += 1
			end
		end
		if remaining == 0 then
			return nil
		end
		local ok, result = pcall(Keys.spec, saved, kind)
		return if ok then result else nil
	end
	return (part and attempt(part)) or attempt(nil)
end

function ActionMethods.rebind(self: ActionState, binding: any, options: Types.RebindOptions?): (boolean, { Types.Conflict })
	local settings: Types.RebindOptions = options or {}
	checkSlot(self, settings.slot, "rebind")
	local mode = settings.conflict or "reject"
	if not MODES[mode] then
		error(`[HYDROGEN] Input action {self.name}: rebind conflict must be "reject", "swap", "unbind" or "allow"`, 2)
	end
	local spec = specFor(self, binding, 2)

	local list = self._bindings[spec.device]
	local slot = math.min(settings.slot or 1, #list + 1)
	local found = findConflicts(self, spec, slot)
	local conflicts = publicConflicts(found)
	if #found > 0 and mode == "reject" then
		return false, conflicts
	end

	local old = list[slot]
	if old and old.id == spec.id then
		return true, conflicts
	end
	list[slot] = spec

	local changed = { self }
	if mode == "swap" or mode == "unbind" then
		for _, entry in found do
			local theirs = entry.action._bindings[spec.device]
			local position = table.find(theirs, entry.spec)
			if position then
				local replacement: Spec? = nil
				if entry.spec.key == nil then
					-- A composite: only the clashing directions change, to the old key when swapping.
					local part = if mode == "swap" and old and old.key and not old.modifiers and old.scale == 1
						then old.key
						else nil
					replacement = replaceParts(entry.spec, entry.action.kind, triggers(spec), part)
				elseif mode == "swap" and old and fits(old, entry.action.kind) then
					-- The old binding only moves to an action it can drive.
					replacement = old
				end
				if replacement then
					theirs[position] = replacement
				else
					table.remove(theirs, position)
				end
				if not table.find(changed, entry.action) then
					table.insert(changed, entry.action)
				end
			end
		end
	end
	bindingsChanged(changed)
	return true, conflicts
end

function ActionMethods.unbind(self: ActionState, name: Device, slot: number?)
	checkDevice(self, name, "unbind", 2)
	checkSlot(self, slot, "unbind")
	local list = self._bindings[name]
	if slot then
		if list[slot] == nil then
			return
		end
		table.remove(list, slot)
	else
		if #list == 0 then
			return
		end
		table.clear(list)
	end
	bindingsChanged({ self })
end

function ActionMethods.resetBindings(self: ActionState)
	self._bindings = copyBindings(self._defaults)
	bindingsChanged({ self })
end

function ActionMethods.glyph(self: ActionState, name: Device?): Types.Glyph?
	return glyphFor(self, name or device)
end

function ActionMethods.observeGlyph(self: ActionState, observer: any): () -> ()
	local disconnect = listen(self, self._glyphObservers, observer, "observeGlyph")
	call(`action {self.name} observeGlyph`, observer, glyphFor(self, device))
	return disconnect
end

function ActionMethods.touchButton(self: ActionState): GuiButton?
	local touchButton = Core.touchButton
	return if touchButton then touchButton(self) else nil
end

-- Sources

function Core.source(action: ActionState): any
	local source = {}

	function source.press(_: any)
		if action.kind ~= "button" then
			error(`[HYDROGEN] Input action {action.name} is a {action.kind}; use source:set(value)`, 2)
		end
		if action.context._active then
			addSource(action, source)
		end
	end

	function source.release(_: any)
		if action.kind == "button" then
			removeSource(action, source)
		elseif action._sourceValues[source] ~= nil then
			action._sourceValues[source] = nil
			recompute(action)
		end
	end

	function source.set(_: any, value: any)
		if action.kind == "button" then
			if value then
				source:press()
			else
				source:release()
			end
			return
		end
		local expected = if action.kind == "axis" then "number" else "Vector2"
		if typeof(value) ~= expected then
			error(`[HYDROGEN] Input action {action.name} is a {action.kind}; source:set expects a {expected}, got {typeof(value)}`, 2)
		end
		action._sourceValues[source] = if isZero(value) then nil else value
		recompute(action)
	end

	function source.destroy(_: any)
		source:release()
	end

	return source
end

-- Saving

local function ids(list: { Spec }): string
	local parts = {}
	for _, spec in list do
		table.insert(parts, spec.id)
	end
	return table.concat(parts, ";")
end

function Core.saveBindings(): Types.SavedBindings
	local saved: Types.SavedBindings = {}
	for _, action in actions do
		for _, name in DEVICES do
			local list = action._bindings[name]
			if ids(list) ~= ids(action._defaults[name]) then
				local entry = saved[action.name]
				if not entry then
					entry = {}
					saved[action.name] = entry
				end
				local out = {}
				for _, spec in list do
					table.insert(out, Keys.save(spec))
				end
				entry[name] = out
			end
		end
	end
	return saved
end

function Core.loadBindings(saved: any)
	if type(saved) ~= "table" then
		Log.warn(`[HYDROGEN] Input.loadBindings expects the table Input.saveBindings returned, got {typeof(saved)}; keeping the defaults`)
		saved = {}
	end
	for _, action in actions do
		action._bindings = copyBindings(action._defaults)
	end
	for name, devices in saved do
		-- Saved data can outlive an action that a game update removed: skipped quietly.
		local action = if type(name) == "string" then actionNames[name] else nil
		if action and type(devices) == "table" then
			for deviceName, list in devices do
				if (deviceName ~= "keyboard" and deviceName ~= "gamepad") or type(list) ~= "table" then
					Log.warn(`[HYDROGEN] Input.loadBindings skipped {name}.{tostring(deviceName)}: expected "keyboard" or "gamepad" with a list of bindings`)
					continue
				end
				local specs = {}
				local skipped = 0
				for _, entry in list do
					local ok, result = pcall(Keys.spec, entry, action.kind)
					if ok and result.device ~= deviceName then
						ok, result = false, `it is a {result.device} binding` :: any
					end
					if ok then
						table.insert(specs, result)
					else
						skipped += 1
						Log.warn(`[HYDROGEN] Input.loadBindings skipped a {deviceName} binding of {name}: {result}`)
					end
				end
				-- Nothing usable left: the defaults beat an action the player can't trigger.
				if skipped == 0 or #specs > 0 then
					action._bindings[deviceName] = specs
				end
			end
		end
	end
	bindingsChanged(table.clone(actions))
end

function Core.resetBindings()
	for _, action in actions do
		action._bindings = copyBindings(action._defaults)
	end
	bindingsChanged(table.clone(actions))
end

function Core.onBindingsChanged(listener: () -> ()): () -> ()
	if type(listener) ~= "function" then
		error(`[HYDROGEN] Input.onBindingsChanged expects a function`, 2)
	end
	table.insert(bindingListeners, listener)
	local list = bindingListeners
	return function()
		local position = table.find(list, listener)
		if position then
			table.remove(list, position)
		end
	end
end

-- Puts everything back as defined, for tests: bindings, contexts, device and held input.
-- Listeners are dropped; definitions are kept.
function Core.reset()
	capture = nil
	local stop = stopDeltaFrame
	stopDeltaFrame = nil
	if stop then
		stop()
	end
	deltaActions = {}
	table.clear(down)
	table.clear(analog)
	table.clear(claims)
	for _, action in actions do
		stopHolds(action)
		action._began = {}
		action._ended = {}
		action._changed = {}
		action._holds = {}
		action._glyphObservers = {}
		action._sources = {}
		action._pressed = 0
		action._sourceValues = {}
		action._delta = nil
		action._value = zero(action.kind)
		action._bindings = copyBindings(action._defaults)
		action._generation += 1
	end
	for _, context in contexts do
		context._base = context._initial
		context._enablers = 0
		context._disablers = 0
		context._active = context._initial
		context._epoch += 1
	end
	keyIndex = nil
	routes = {}
	device = "keyboard"
	deviceListeners = {}
	bindingListeners = {}
	glyphProvider = nil
	warnedServer = false
	Core.config.deadzone = DEFAULT_DEADZONE
	Core.config.touchParent = nil
	local onReset = Core.onReset
	if onReset then
		onReset()
	end
end

return Core
