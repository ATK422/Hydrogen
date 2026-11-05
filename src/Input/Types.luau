--!strict

local Scope = require("../Scope")

type Scope = Scope.Scope

-- "keyboard" covers the mouse too. The device of the last input decides which glyphs to show.
export type Device = "keyboard" | "gamepad" | "touch"

-- button: pressed or not (Jump, Sprint, Interact). axis: a number from -1 to 1, or 0 to 1 on a
-- trigger (Throttle, Zoom). vector2: a Vector2 with magnitude up to 1 (Move, Aim).
export type Kind = "button" | "axis" | "vector2"

-- A key: any Enum.KeyCode (keyboard and gamepad), or Enum.UserInputType.MouseButton1/2/3,
-- MouseMovement or MouseWheel.
export type Key = Enum.KeyCode | Enum.UserInputType

-- One way to trigger an action. A bare key, or a table:
--   { key = S, modifiers = { LeftControl } }          button with modifiers (either hand counts)
--   { up = W, down = S, left = A, right = D }          vector2 from four keys
--   { positive = E, negative = Q }                     axis from two keys
--   { key = Thumbstick2, axis = "y" }                  axis from one stick axis
--   { key = Thumbstick2, scale = -1 }                  inverted
export type BindingTable = {
	key: Key?,
	modifiers: { Key }?,
	up: Key?,
	down: Key?,
	left: Key?,
	right: Key?,
	positive: Key?,
	negative: Key?,
	scale: number?,
	axis: ("x" | "y")?,
}
export type Binding = Key | BindingTable

-- A binding as saved data: key names ("Space", "ButtonA", "MouseButton1") instead of EnumItems.
export type SavedBinding = string | {
	key: string?,
	modifiers: { string }?,
	up: string?,
	down: string?,
	left: string?,
	right: string?,
	positive: string?,
	negative: string?,
	scale: number?,
	axis: string?,
}

-- Rebound actions only: action name -> device -> bindings. Safe to put in a DataStore.
export type SavedBindings = { [string]: { [string]: { SavedBinding } } }

-- What a prompt shows for an action on a device.
export type Glyph = {
	-- The key name, e.g. "E", "ButtonX", "MouseButton1", or "Touch" for an on-screen button.
	key: string,
	device: Device,
	-- Readable text, e.g. "E", "Shift", "LMB", "X". Uses the player's keyboard layout in a game.
	text: string,
	-- An image for the key, when there is one (gamepad buttons in a game).
	image: string?,
}

-- Returns the glyph to show for a key, or nil for Hydrogen's default.
export type GlyphProvider = (key: string, device: Device) -> Glyph?

export type Conflict = {
	-- The other action already using the keys.
	action: AnyAction,
	-- Its binding that clashes.
	binding: Binding,
	device: Device,
	-- Where that binding sits in the other action's bindings for the device.
	slot: number,
}

export type RebindOptions = {
	-- Which of the device's bindings to replace; 1 by default. Past the end appends.
	slot: number?,
	-- What to do when another action can be triggered by the same keys:
	-- "reject" (default) changes nothing; "swap" gives the other action this slot's old binding;
	-- "unbind" removes the other action's binding; "allow" keeps both.
	conflict: ("reject" | "swap" | "unbind" | "allow")?,
}

export type TouchOptions = {
	text: string?,
	image: string?,
	-- Set either to take the button out of the default grid and place it yourself.
	position: UDim2?,
	size: UDim2?,
}

export type ButtonOptions = {
	-- An on-screen button while the player uses touch: true, or how it looks.
	touch: (boolean | TouchOptions)?,
	-- Seconds a press stays usable for action:consumeBuffered, e.g. 0.15 for a combo that
	-- takes the next attack pressed during recovery.
	buffer: number?,
}

export type AxisOptions = {
	-- Thumbstick dead zone for this action; Input.configure's deadzone (0.15) by default.
	deadzone: number?,
}

export type ContextOptions = {
	-- Higher priorities see input first. 0 by default.
	priority: number?,
	-- Keys this context binds don't reach lower-priority contexts while it's enabled.
	sink: boolean?,
	-- Whether it starts enabled. true by default.
	enabled: boolean?,
}

-- What every action has, whatever its value type. Action<V> adds the value-typed members.
-- (Split so the types that refer to each other aren't generic, which Luau requires.)
export type AnyAction = {
	read name: string,
	read kind: Kind,
	read context: ContextControls,

	-- Pressed, or a non-zero value.
	held: (self: AnyAction) -> boolean,

	-- Each listener method returns a function that disconnects it; give it to scope:add.
	-- Ends: released, or back to zero.
	onEnded: (self: AnyAction, listener: () -> ()) -> () -> (),
	-- Once per press, after it has been held for seconds without a release.
	onHold: (self: AnyAction, seconds: number, listener: () -> ()) -> () -> (),
	-- Button defined with { buffer = seconds }: true if it began within the last buffer seconds
	-- and no call has taken that press yet. Takes it either way. Errors on actions without a buffer.
	consumeBuffered: (self: AnyAction) -> boolean,

	-- The current bindings, for one device or all of them.
	bindings: (self: AnyAction, device: Device?) -> { Binding },
	-- Replaces one of the binding's device's bindings. Returns whether it changed and the conflicts.
	rebind: (self: AnyAction, binding: Binding, options: RebindOptions?) -> (boolean, { Conflict }),
	-- The conflicts rebind would report, without changing anything.
	conflicts: (self: AnyAction, binding: Binding, slot: number?) -> { Conflict },
	-- Removes one binding of a device, or all of them.
	unbind: (self: AnyAction, device: Device, slot: number?) -> (),
	-- Back to the bindings the action was defined with.
	resetBindings: (self: AnyAction) -> (),

	-- What to show in a prompt: the first binding for a device (the current one by default).
	glyph: (self: AnyAction, device: Device?) -> Glyph?,
	-- Calls now, then whenever the device or the bindings change.
	observeGlyph: (self: AnyAction, observer: (glyph: Glyph?) -> ()) -> () -> (),
	-- The on-screen button Hydrogen made for a touch action, once the player has used touch.
	touchButton: (self: AnyAction) -> GuiButton?,
}

-- V is boolean for a button, number for an axis, Vector2 for a vector2.
export type Action<V> = AnyAction & {
	-- Current value: a button's pressed state, an axis' number, a vector2's Vector2.
	value: (self: Action<V>) -> V,
	-- Starts: pressed, or moved away from zero. Gets the value.
	onBegan: (self: Action<V>, listener: (value: V) -> ()) -> () -> (),
	-- Every change of value(), including begin and end.
	onChanged: (self: Action<V>, listener: (value: V, previous: V) -> ()) -> () -> (),
}

-- What every context has; Context adds the methods that define actions.
export type ContextControls = {
	read name: string,
	read priority: number,
	read sink: boolean,

	-- Enabled itself or by an enableFor still open, with no disableFor open.
	enabled: (self: ContextControls) -> boolean,
	enable: (self: ContextControls) -> (),
	disable: (self: ContextControls) -> (),
	setEnabled: (self: ContextControls, enabled: boolean) -> (),
	-- Enabled until the scope is destroyed or the returned function is called. Counted, so two
	-- open menus keep it enabled until both close.
	enableFor: (self: ContextControls, scope: Scope?) -> () -> (),
	-- Disabled until the scope is destroyed or the returned function is called. Counted, and
	-- wins over enable and enableFor.
	disableFor: (self: ContextControls, scope: Scope?) -> () -> (),
	actions: (self: ContextControls) -> { AnyAction },
}

export type Context = ContextControls & {
	button: (self: Context, name: string, bindings: { Binding }, options: ButtonOptions?) -> Action<boolean>,
	axis: (self: Context, name: string, bindings: { Binding }, options: AxisOptions?) -> Action<number>,
	vector2: (self: Context, name: string, bindings: { Binding }, options: AxisOptions?) -> Action<Vector2>,
}

-- Drives one action directly, bypassing bindings, while its context is enabled: a custom touch
-- control, an accessibility switch, a replay.
export type Source<V> = {
	set: (self: Source<V>, value: V) -> (),
	press: (self: Source<V>) -> (),
	release: (self: Source<V>) -> (),
	-- Releases and stops driving the action.
	destroy: (self: Source<V>) -> (),
}

export type Configuration = {
	-- Where the on-screen touch buttons go; the local player's PlayerGui by default.
	touchParent: Instance?,
	-- Thumbstick dead zone, 0 to 1. 0.15 by default.
	deadzone: number?,
}

-- Input as a device would produce it, routed through contexts and bindings. For tests.
export type Simulate = {
	press: (key: Key) -> (),
	release: (key: Key) -> (),
	-- press then release.
	tap: (key: Key) -> (),
	-- A stick (Vector2), a trigger (0 to 1), MouseMovement (Vector2 delta) or MouseWheel (number).
	move: (key: Key, value: number | Vector2) -> (),
	-- Switch the current device without input, e.g. to "touch".
	device: (device: Device) -> (),
}

return nil
