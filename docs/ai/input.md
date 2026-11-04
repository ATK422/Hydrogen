# Hydrogen.Input
> Client-side action mapping: declare actions (`Jump`, `Sprint`, `Move`, `Aim`) once with keyboard/mouse, gamepad and touch bindings, group them in prioritized contexts, and react to actions instead of keys; with rebinding, saved binding tables, device-aware glyphs, touch buttons and headless simulation.

## Use it when / Don't use it when

Use it when:
- client code reacts to player input (abilities, movement, camera, interaction, UI shortcuts);
- the same action must work on keyboard/mouse, gamepad and touch;
- some input is modal (menu, vehicle, dialog) and must take keys from gameplay while open;
- players can rebind controls and you save their bindings;
- prompts must show the right key or button for the device in use.

Don't use it when:
- you are on the server: input only exists on the client (send a `Hydrogen.clientEvent` with the result);
- you need raw text entry: use a `TextBox`;
- you need to stop Roblox's default character controls: sinking only affects Hydrogen actions; disable them through the PlayerModule (`require(player.PlayerScripts:WaitForChild("PlayerModule")):GetControls():Disable()`);
- you need multi-touch gestures (pinch, swipe): use `UserInputService` touch events directly.

## Quick start

```luau
-- ReplicatedStorage/Client/Controls.luau: required by client systems (and safe to require on the server)
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Input = Hydrogen.Input
local Key = Enum.KeyCode

local Gameplay = Input.context("Gameplay")
local Menu = Input.context("Menu", { priority = 10, sink = true, enabled = false })

return {
	Gameplay = Gameplay,
	Menu = Menu,
	Jump = Gameplay:button("Jump", { Key.Space, Key.ButtonA }),
	Sprint = Gameplay:button("Sprint", { Key.LeftShift, Key.ButtonL3 }),
	Interact = Gameplay:button("Interact", { Key.E, Key.ButtonX }, { touch = true }),
	Move = Gameplay:vector2("Move", { { up = Key.W, down = Key.S, left = Key.A, right = Key.D }, Key.Thumbstick1 }),
	Aim = Gameplay:vector2("Aim", { Enum.UserInputType.MouseMovement, Key.Thumbstick2 }),
	Close = Menu:button("Close", { Key.Backspace, Key.ButtonB }),
}
```

```luau
-- ReplicatedStorage/ClientSystems/Abilities.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Controls = require(ReplicatedStorage.Client.Controls)

return Hydrogen.define(function()
	local Abilities = {}

	function Abilities:start()
		local scope = Hydrogen.Scope.of(self)
		scope:add(Controls.Interact:onBegan(function()
			print("interact")
		end))
		scope:add(Controls.Interact:onHold(1, function()
			print("held for a second")
		end))
		scope:connect(RunService.RenderStepped, function(_dt: number)
			local move: Vector2 = Controls.Move:value()
			local sprinting = Controls.Sprint:held()
			-- drive the character / camera
		end)
	end

	return Abilities
end)
```

Nothing to boot: the first action defined on a client starts listening to `UserInputService`.

## API

Module: `local Input = Hydrogen.Input`. Client-only at runtime: on the server, definitions and simulation work but real input never arrives. Nothing yields.

Definitions (call at module top level in a shared client module):
- `Input.context(name: string, options: ContextOptions?): Context` with `ContextOptions = { priority: number? (0), sink: boolean? (false), enabled: boolean? (true) }`
- `context:button(name: string, bindings: { Binding }, options: { touch: (boolean | TouchOptions)? }?): Action<boolean>`
- `context:axis(name: string, bindings: { Binding }, options: { deadzone: number? }?): Action<number>`
- `context:vector2(name: string, bindings: { Binding }, options: { deadzone: number? }?): Action<Vector2>`
- `Input.button / Input.axis / Input.vector2(name, bindings, options?)`: same, in `Input.default` (context `"Default"`, priority 0, enabled)
- `Input.action(name: string): AnyAction?`: look up by name
- `TouchOptions = { text: string?, image: string?, position: UDim2?, size: UDim2? }`

Bindings (`Binding = Key | BindingTable`, `Key = Enum.KeyCode | Enum.UserInputType.MouseButton1/2/3 | MouseMovement | MouseWheel`):
- `Key.Space`: single key. Button: pressed while held. Axis: 1 while held (triggers `ButtonL2/R2`: analog 0..1). Vector2: only `Thumbstick1/2` and `MouseMovement`.
- `{ key = Key.S, modifiers = { Key.LeftControl } }`: button only; either-hand modifiers count.
- `{ up = W, down = S, left = A, right = D }`: vector2 composite (any subset of the four).
- `{ positive = E, negative = Q }`: axis composite.
- `{ key = Key.Thumbstick2, axis = "x" | "y" }`: axis from one stick axis ("y" default).
- `scale = number` on any binding: multiplies its contribution (`-1` inverts).
- A binding's keys must all be on one device (keyboard+mouse, or gamepad).

`Action<V>` (`AnyAction` = the members without V):
- `action.name: string`, `action.kind: "button" | "axis" | "vector2"`, `action.context: ContextControls`
- `action:value(): V`: boolean / number / Vector2
- `action:held(): boolean`: pressed or non-zero
- `action:onBegan(fn: (value: V) -> ()): () -> ()`
- `action:onEnded(fn: () -> ()): () -> ()`
- `action:onChanged(fn: (value: V, previous: V) -> ()): () -> ()`: every change; fires before the onBegan or onEnded it causes
- `action:onHold(seconds: number, fn: () -> ()): () -> ()`: once per press after `seconds` held (uses `Hydrogen.Clock`)
- `action:bindings(device: ("keyboard" | "gamepad")?): { Binding }`
- `action:rebind(binding: Binding, options: { slot: number?, conflict: ("reject" | "swap" | "unbind" | "allow")? }?): (boolean, { Conflict })`
- `action:conflicts(binding: Binding, slot: number?): { Conflict }`
- `action:unbind(device: "keyboard" | "gamepad", slot: number?)`: one slot, or all of the device
- `action:resetBindings()`
- `action:glyph(device: Device?): Glyph?`: current device by default
- `action:observeGlyph(fn: (glyph: Glyph?) -> ()): () -> ()`: called now, then on device switch / rebind / provider change
- `action:touchButton(): GuiButton?`: the auto-made touch button, after the player first used touch
- `Conflict = { action: AnyAction, binding: Binding, device: Device, slot: number }`
- `Glyph = { key: string, device: Device, text: string, image: string? }`

`Context` (`ContextControls` = without the define methods):
- `context.name`, `context.priority`, `context.sink`
- `context:enabled(): boolean`
- `context:enable()`, `context:disable()`, `context:setEnabled(on: boolean)`: own state
- `context:enableFor(scope: Scope?): () -> ()`, `context:disableFor(scope: Scope?): () -> ()`: counted overrides, undone by the returned function or when the scope is destroyed
- `context:actions(): { AnyAction }`

Device and glyphs:
- `Input.device(): "keyboard" | "gamepad" | "touch"`
- `Input.onDeviceChanged(fn: (device, previous) -> ()): () -> ()`
- `Input.glyphs(provider: ((key: string, device: Device) -> Glyph?)?)`: custom icons; nil return = default

Rebinding and saving:
- `Input.captureKey(fn: (key: Key) -> (), device: ("keyboard" | "gamepad")?): () -> ()`: next press goes to fn only; returns cancel
- `Input.saveBindings(): SavedBindings`: `{ [actionName]: { [device]: { SavedBinding } } }`, only changed devices, key names as strings
- `Input.loadBindings(saved: SavedBindings)`: defaults, then saved on top
- `Input.resetBindings()`
- `Input.onBindingsChanged(fn: () -> ()): () -> ()`: after rebind / unbind / reset / load

Custom controls:
- `Input.bindButton(action: Action<boolean>, button: GuiButton, scope: Scope?): () -> ()`: pressed while any touch or left click is down on it
- `Input.source(action: Action<V>): Source<V>`: `source:set(value: V)`, `source:press()`, `source:release()`, `source:destroy()`

Config and tests:
- `Input.configure({ touchParent: Instance?, deadzone: number? })`: touch button parent (default `LocalPlayer.PlayerGui`); stick dead zone 0..1 (default 0.15)
- `Input.simulate.press(key)`, `.release(key)`, `.tap(key)`, `.move(key, value: number | Vector2)`, `.device(device)`
- `Input.reset()`: tests; also called by `Hydrogen.test` on close

Types from `Hydrogen`: `InputAction<V>`, `InputContext`, `InputDevice`, `InputKey`, `InputBinding`, `InputSavedBindings`, `InputGlyph`, `InputConflict`, `InputSource<V>`. Everything else from `Hydrogen.Input` types: `Input.AnyAction`, `Input.ContextControls`, `Input.RebindOptions`, `Input.TouchOptions`, `Input.Configuration`, ...

## Rules

- Define actions and contexts once, at module top level of a shared module. Names are unique across all contexts (saved bindings are keyed by name); `"Default"` is taken. Redefining errors.
- Routing: a key press goes to enabled contexts from highest `priority` down. A context with `sink = true` that binds the key stops it from reaching lower priorities. Equal priorities all receive it. Sinking is per key, not per context: keys the sinking context doesn't bind pass through.
- A button begins on the first press of any of its bindings and ends when the last is released. Repeated presses of a held key are ignored.
- Disabling a context, or a sinking context taking a held key, ends the affected actions (onEnded fires). Re-enabling never re-presses a held button; axes/vector2s recompute from what is held, so movement resumes.
- Context enabled = (own state or any open `enableFor`) and no open `disableFor`. Undo functions are idempotent.
- Modifiers: among matching button bindings, only those with the most modifiers held fire (Ctrl+S beats S). Releasing the modifier first doesn't end the action. Composite and axis bindings ignore modifiers.
- Game-processed input (TextBox focused, GuiButton pressed, gamepad UI selection) begins nothing; releases are always processed. Window focus loss releases all keys and sticks.
- Axis/vector2 values are clamped to magnitude 1 (sum of all bindings and sources), then mouse delta is added on top unclamped.
- `MouseMovement` / `MouseWheel` are deltas: `value()` includes the deltas of the current frame and returns to zero at the next Heartbeat (`Hydrogen.Clock.heartbeat`). Read in `onChanged` or RenderStepped.
- Sticks: radial dead zone with rescale (`(|v| - dz) / (1 - dz)`). Per-action `deadzone` overrides `Input.configure`.
- Device switches on `UserInputService.LastInputTypeChanged` (live) or on `Input.simulate` (stick moves inside the dead zone don't switch).
- Conflicts: two bindings conflict when one press triggers both (same key and same modifier set, or shared composite key), in the same context, or in contexts where neither outranks-and-sinks the other. Enabled state is ignored (contexts can be enabled later).
- `rebind` replaces the `slot` (default 1) of the binding's device; a slot past the end appends. Default `conflict = "reject"` returns `false, conflicts` and changes nothing. `"swap"` gives every conflicting binding this slot's old binding (removed instead if the slot was empty or the other action's kind can't use it); `"unbind"` removes them; `"allow"` keeps both. In a composite only the clashing direction changes (swap: set to the old key if it is a plain key; unbind: that direction removed; the composite is removed when no direction is left). Returned conflicts are as they were before the change.
- Rebinding or unbinding a key that is held releases the action.
- `loadBindings` validates everything and never errors: unknown action names are skipped silently; bad entries and wrong-device entries are warned and skipped; a device whose saved entries are all invalid keeps its defaults; an empty list means unbound.
- Touch buttons: made on the first switch to `"touch"` (never for keyboard/gamepad players), in a `ScreenGui` "HydrogenTouch" (`ResetOnSpawn = false`); visible while the device is touch and their context is enabled. `touch` is only valid on button actions.
- Listener order: context priority, then definition order; within an action, registration order. Errors are warned (`[HYDROGEN] Input action X onBegan listener errored`); yields don't block other listeners.
- Zero cost when unused: no connections until the first definition on a client; no per-frame work except while the mouse is moving over an action bound to `MouseMovement`/`MouseWheel`.

## Recipes

Menu that takes gameplay keys while open (counted, scope-tied):
```luau
local scope = Hydrogen.Scope.new("Shop")
Controls.Menu:enableFor(scope)
Controls.Gameplay:disableFor(scope)
scope:add(Controls.Close:onBegan(function()
	scope:destroy()
end))
```

Vehicle context that takes W/A/S/D from Move while seated (higher priority, sinks):
```luau
local Vehicle = Input.context("Vehicle", { priority = 5, sink = true, enabled = false })
local Throttle = Vehicle:axis("Throttle", { { positive = Key.W, negative = Key.S }, Key.ButtonR2 })
local Steer = Vehicle:axis("Steer", { { positive = Key.D, negative = Key.A }, { key = Key.Thumbstick1, axis = "x" } })
-- on sit:  Vehicle:enableFor(seatScope)   -- sinks W/A/S/D away from Move while seated
```

Rebinding UI with a "press a key" prompt and conflict handling:
```luau
local function promptRebind(action: Hydrogen.InputAction<boolean>, device: "keyboard" | "gamepad")
	status.Text = "Press a key..."
	local cancel = Input.captureKey(function(key)
		local ok, conflicts = action:rebind(key)
		if not ok then
			status.Text = `{conflicts[1].action.name} uses that. Swapped.`
			action:rebind(key, { conflict = "swap" })
		end
	end, device)
	scope:add(cancel)
end
```

Persist bindings through the server's Data store:
```luau
-- client
Input.loadBindings(Remotes.GetBindings:Invoke())
Input.onBindingsChanged(function()
	Remotes.SaveBindings:Fire(Input.saveBindings())
end)
-- server: validate size/shape, then Data.update(player, function(d) d.bindings = saved end)
```

Device-aware prompt:
```luau
scope:add(Controls.Interact:observeGlyph(function(glyph: Hydrogen.InputGlyph?)
	prompt.Visible = glyph ~= nil
	if glyph then
		prompt.Key.Text = glyph.text
		prompt.Icon.Image = glyph.image or ""
	end
end))
```

Custom touch joystick driving a vector2:
```luau
local stick = Input.source(Controls.Move)
scope:add(stick)
-- in your joystick's drag handler:
stick:set(Vector2.new(dx, -dy) / radius)
-- on release:
stick:set(Vector2.zero)
```

## Mistakes

- Don't listen to `UserInputService.InputBegan` for game actions; define an action and use `onBegan`.
- Don't call `context:enable()` / `disable()` from two UIs that can overlap; use `enableFor(scope)` / `disableFor(scope)`.
- Don't define actions inside `start` or per player; define them once at module top level (redefinition errors).
- Don't bind `Key.Space` to a `vector2`; use `{ up = ..., down = ..., left = ..., right = ... }` or a thumbstick.
- Don't save `action:bindings()` (EnumItems); save `Input.saveBindings()` (strings).
- Don't read `Aim:value()` for mouse look in Heartbeat; deltas reset there. Use RenderStepped or `onChanged`.
- Don't expect a sinking context to stop the default Roblox character controls; disable them via the PlayerModule.
- Don't keep the returned disconnect functions on the floor in systems; `scope:add(...)` them.
- Don't listen to input on the server; it warns once and never fires.

## Testing

```luau
local Input = Hydrogen.Input
local Controls = require(path.to.Controls)

Hydrogen.test({ systems = { Abilities } }, function(t)
	Input.simulate.press(Enum.KeyCode.E)          -- routed through contexts like real input
	t:advance(1)                                   -- onHold timers run on the fake clock
	Input.simulate.release(Enum.KeyCode.E)
	Input.simulate.move(Enum.KeyCode.Thumbstick1, Vector2.new(0, 1)) -- device becomes "gamepad"
	assert(Controls.Move:value().Y > 0.99)
	Input.simulate.move(Enum.UserInputType.MouseMovement, Vector2.new(4, 0))
	t:advance(0)                                   -- delta cleared at the frame end
	Input.simulate.device("touch")
	Controls.Menu:enable()
end) -- Input.reset() runs here: bindings, contexts, device, listeners back to defaults
```

- `Hydrogen.test` resets Input when it closes; with another framework call `Input.reset()` in teardown.
- Touch buttons under Lune: `Input.configure({ touchParent = Instance.new("Folder") })`, then `Input.simulate.device("touch")`; inspect `action:touchButton()`. Lune Instances have no events, so press through `Input.bindButton(action, fakeButton)` with a table `{ InputBegan = signal, InputEnded = signal }` whose inputs have `UserInputType = Enum.UserInputType.Touch`, or through `Input.source(action)`.
- `UserInputService` itself is never connected under Lune (RunService:IsClient() is false). Hydrogen's own tests drive the adapter with a fake service via `src/Input/Device.luau`'s `connect`.

## Errors and warnings

- `[HYDROGEN] Input action X is already defined; action names are unique across contexts` → define once in a shared module and require it; rename one of them.
- `[HYDROGEN] Input context X is already defined` → same, for contexts.
- `[HYDROGEN] Input action X (kind): binding N: <reason>` → the binding doesn't fit the kind; the reason says what to bind instead (e.g. "a vector2 action binds a thumbstick, MouseMovement, or { up, down, left, right }", "it mixes keyboard and gamepad keys").
- `[HYDROGEN] Input action X has no option Y` / `Input context X has no option Y` → typo in options.
- `[HYDROGEN] Input action X: touch buttons are for button actions; drive a <kind> from your own control with Input.source`.
- `[HYDROGEN] Input action X: rebind conflict must be "reject", "swap", "unbind" or "allow"`.
- `[HYDROGEN] Input action X: unbind takes "keyboard" or "gamepad"`.
- `[HYDROGEN] Input action X is a <kind>; source:set expects a <type>`.
- `[HYDROGEN] <Key> is analog; use Input.simulate.move` / `[HYDROGEN] <Key> is not analog; use Input.simulate.press and release` → wrong simulate call for the key.
- `[HYDROGEN] Input action X onBegan listener errored: <error>` (warning) → your listener threw; other listeners still ran.
- `[HYDROGEN] Hydrogen.Input is client-only: X:onBegan on the server never fires` (warning, once) → move the listener to a client system.
- `[HYDROGEN] Input.loadBindings skipped a <device> binding of X: <reason>` (warning) → saved data was edited or from an older version; the rest still loaded.
- `[HYDROGEN] Input.loadBindings skipped X.<device>` (warning) → unknown device key in saved data.
- `[HYDROGEN] Input.loadBindings expects the table Input.saveBindings returned` (warning) → nil or wrong type passed; defaults kept.
- `[HYDROGEN] Input glyph provider errored for <key>` (warning) → your `Input.glyphs` function threw; the default glyph was used.

## Works with

- `Hydrogen.Scope`: `scope:add(action:onBegan(...))`, `context:enableFor(scope)`, `Input.bindButton(action, button, scope)`.
- `Hydrogen.Clock`: `onHold` timers and mouse-delta frame resets use it, so `Hydrogen.test`'s fake clock drives them.
- `Hydrogen.test`: resets Input on close; capture warnings with `t:expectWarning`.
- `Hydrogen.Data` / network: persist `Input.saveBindings()` through a `clientEvent` into a Data field; load with `Input.loadBindings`.
- Client systems (`Hydrogen.define`): attach listeners in `start` with `Scope.of(self)`.
