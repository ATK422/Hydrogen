--!strict

-- Hydrogen.Input: declare actions once, with bindings for keyboard and mouse, gamepad and touch,
-- then react to actions, never to keys. Contexts group actions with a priority, rebinding is
-- checked for conflicts and saved as plain data, and Input.simulate drives it all in tests.
-- Client-only: on the server definitions work (so shared modules load) but nothing fires.

local Core = require("@self/Core")
local Device = require("@self/Device")
local Keys = require("@self/Keys")
local Touch = require("@self/Touch")
local Types = require("@self/Types")
local Scope = require("./Scope")

export type Device = Types.Device
export type Kind = Types.Kind
export type Key = Types.Key
export type Binding = Types.Binding
export type BindingTable = Types.BindingTable
export type SavedBinding = Types.SavedBinding
export type SavedBindings = Types.SavedBindings
export type Glyph = Types.Glyph
export type GlyphProvider = Types.GlyphProvider
export type Conflict = Types.Conflict
export type RebindOptions = Types.RebindOptions
export type TouchOptions = Types.TouchOptions
export type ButtonOptions = Types.ButtonOptions
export type AxisOptions = Types.AxisOptions
export type ContextOptions = Types.ContextOptions
export type Action<V> = Types.Action<V>
export type AnyAction = Types.AnyAction
export type Context = Types.Context
export type ContextControls = Types.ContextControls
export type Source<V> = Types.Source<V>
export type Configuration = Types.Configuration
export type Simulate = Types.Simulate

Core.onDefine = Device.ensure
Core.onTouchChange = Touch.update
Core.onReset = Touch.reset
Core.touchButton = Touch.button

local Input = {}

-- Holds the actions made with Input.button, Input.axis and Input.vector2: priority 0, enabled.
Input.default = (Core.context("Default", nil, 2) :: any) :: Context

-- A group of actions enabled and disabled together, e.g. Gameplay, Menu, Vehicle.
function Input.context(name: string, options: ContextOptions?): Context
	return Core.context(name, options, 3) :: any
end

-- Pressed or not: Jump, Sprint, Interact, Ability1. In the default context.
function Input.button(name: string, bindings: { Binding }, options: ButtonOptions?): Action<boolean>
	return Core.define(Input.default :: any, "button", name, bindings, options :: any, 3) :: any
end

-- A number: -1 to 1 from keys or a stick axis, 0 to 1 from a trigger. In the default context.
function Input.axis(name: string, bindings: { Binding }, options: AxisOptions?): Action<number>
	return Core.define(Input.default :: any, "axis", name, bindings, options :: any, 3) :: any
end

-- A Vector2 up to length 1 from a stick or four keys, or a mouse delta. In the default context.
function Input.vector2(name: string, bindings: { Binding }, options: AxisOptions?): Action<Vector2>
	return Core.define(Input.default :: any, "vector2", name, bindings, options :: any, 3) :: any
end

-- An action by name, e.g. to show a saved binding table in a settings menu.
function Input.action(name: string): AnyAction?
	return Core.action(name) :: any
end

-- The device of the last input: "keyboard" (with mouse), "gamepad" or "touch".
function Input.device(): Device
	return Core.device()
end

-- Calls listener(device, previous) when the player switches device. Returns a disconnect function.
Input.onDeviceChanged = Core.onDeviceChanged :: (listener: (device: Device, previous: Device) -> ()) -> () -> ()

-- Sets what action:glyph returns for a key (your icon set), or nil for Hydrogen's default.
function Input.glyphs(provider: GlyphProvider?)
	if provider ~= nil and type(provider) ~= "function" then
		error(`[HYDROGEN] Input.glyphs expects a function (key, device) -> Glyph?, or nil`, 2)
	end
	Core.setGlyphProvider(provider)
end

-- Calls listener with the next key pressed (on one device, if given) and swallows that press,
-- for a "press a key" rebinding prompt. Returns a function that cancels the wait.
Input.captureKey = Core.captureKey :: (listener: (key: Key) -> (), device: Device?) -> () -> ()

-- Every rebound binding as plain data (names, not EnumItems), ready for a DataStore.
Input.saveBindings = Core.saveBindings :: () -> SavedBindings
-- Puts saved bindings back on top of the defaults. Bad entries are skipped with a warning.
Input.loadBindings = Core.loadBindings :: (saved: SavedBindings) -> ()
-- Every action back to the bindings it was defined with.
Input.resetBindings = Core.resetBindings :: () -> ()
-- Calls listener after any rebind, unbind, reset or load: a good moment to save.
Input.onBindingsChanged = Core.onBindingsChanged :: (listener: () -> ()) -> () -> ()

local function checkAction(action: any, method: string)
	if not Core.isAction(action) then
		error(`[HYDROGEN] Input.{method} expects an action from Input.button, Input.axis, Input.vector2 or context:button/axis/vector2`, 3)
	end
end

-- Drives an action directly, as a custom control would (a touch joystick, a switch).
function Input.source<V>(action: Action<V>): Source<V>
	checkAction(action, "source")
	return Core.source(action :: any)
end

-- Presses a button action while a GuiButton is held, for a touch button you made yourself.
-- Returns a function that unbinds it; pass a scope to unbind when the scope is destroyed.
function Input.bindButton(action: Action<boolean>, button: GuiButton, scope: Scope.Scope?): () -> ()
	checkAction(action, "bindButton")
	if (action :: any).kind ~= "button" then
		error(`[HYDROGEN] Input.bindButton expects a button action; {action.name} is a {action.kind}`, 2)
	end
	local unbind = Touch.bind(action :: any, button)
	if scope ~= nil then
		scope:add(unbind)
	end
	return unbind
end

local CONFIGURATION = { touchParent = true, deadzone = true }

function Input.configure(configuration: Configuration)
	if type(configuration) ~= "table" then
		error(`[HYDROGEN] Input.configure expects a table`, 2)
	end
	for field in configuration :: any do
		if not CONFIGURATION[field] then
			error(`[HYDROGEN] Input.configure has no option {field}; it takes touchParent and deadzone`, 2)
		end
	end
	local deadzone = configuration.deadzone
	if deadzone ~= nil then
		if type(deadzone) ~= "number" or deadzone < 0 or deadzone >= 1 then
			error(`[HYDROGEN] Input.configure deadzone must be a number from 0 up to (not including) 1`, 2)
		end
		Core.config.deadzone = deadzone
	end
	local touchParent = configuration.touchParent
	if touchParent ~= nil then
		if typeof(touchParent) ~= "Instance" then
			error(`[HYDROGEN] Input.configure touchParent must be an Instance`, 2)
		end
		Core.config.touchParent = touchParent
		Touch.update()
	end
end

local function keyName(key: any, method: string): string
	local name = Keys.name(key)
	if name == nil then
		error(`[HYDROGEN] Input.simulate.{method} expects an Enum.KeyCode or a mouse Enum.UserInputType, got {tostring(key)}`, 3)
	end
	return name
end

local DEVICES = { keyboard = true, gamepad = true, touch = true }

Input.simulate = {
	press = function(key: Key)
		local name = keyName(key, "press")
		if Keys.isStick(name) or Keys.isDelta(name) then
			error(`[HYDROGEN] {name} is analog; use Input.simulate.move`, 2)
		end
		Core.setDevice(Keys.device(name))
		Core.press(name)
	end,
	release = function(key: Key)
		Core.release(keyName(key, "release"))
	end,
	tap = function(key: Key)
		local name = keyName(key, "tap")
		if Keys.isStick(name) or Keys.isDelta(name) then
			error(`[HYDROGEN] {name} is analog; use Input.simulate.move`, 2)
		end
		Core.setDevice(Keys.device(name))
		Core.press(name)
		Core.release(name)
	end,
	move = function(key: Key, value: number | Vector2)
		local name = keyName(key, "move")
		local expected = if Keys.isStick(name) or name == "MouseMovement"
			then "Vector2"
			elseif Keys.isTrigger(name) or name == "MouseWheel" then "number"
			else nil
		if expected == nil then
			error(`[HYDROGEN] {name} is not analog; use Input.simulate.press and release`, 2)
		end
		if typeof(value) ~= expected then
			error(`[HYDROGEN] Input.simulate.move({name}) expects a {expected}, got {typeof(value)}`, 2)
		end
		local magnitude = if typeof(value) == "Vector2" then (value :: Vector2).Magnitude else math.abs(value :: number)
		local threshold = if Keys.isStick(name) then Core.config.deadzone else 0
		if magnitude > threshold then
			Core.setDevice(Keys.device(name))
		end
		Core.move(name, value)
	end,
	device = function(device: Device)
		if not DEVICES[device] then
			error(`[HYDROGEN] Input.simulate.device expects "keyboard", "gamepad" or "touch", got {tostring(device)}`, 2)
		end
		Core.setDevice(device)
	end,
} :: Simulate

-- Tests: every action released and back to its default bindings, contexts back to how they
-- were defined, device "keyboard", listeners and touch buttons dropped. Definitions stay.
-- Hydrogen.test calls it when a test ends.
Input.reset = Core.reset :: () -> ()

return Input
