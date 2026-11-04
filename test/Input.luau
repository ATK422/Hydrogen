--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Core = require("../src/Input/Core")
local Device = require("../src/Input/Device")

local Input = Hydrogen.Input
local Scope = Hydrogen.Scope
local Key = Enum.KeyCode
local simulate = Input.simulate

-- A signal with Connect/Disconnect and a fire method, for fake buttons and services.
local function fakeSignal()
	local signal = { listeners = {} :: { [any]: (...any) -> () } }
	function signal:Connect(callback: (...any) -> ())
		local connection = {}
		self.listeners[connection] = callback
		function connection.Disconnect()
			self.listeners[connection] = nil
		end
		return connection
	end
	function signal:fire(...: any)
		for _, callback in table.clone(self.listeners) do
			callback(...)
		end
	end
	return signal
end

-- Records an action's events as strings: "began:true", "changed:true", "ended".
local function record(action: Hydrogen.InputAction<any>): { string }
	local log = {}
	action:onBegan(function(value)
		table.insert(log, `began:{value}`)
	end)
	action:onChanged(function(value)
		table.insert(log, `changed:{value}`)
	end)
	action:onEnded(function()
		table.insert(log, "ended")
	end)
	return log
end

local function near(a: Vector2, b: Vector2): boolean
	return (a - b).Magnitude < 1e-6
end

return function()
	-- Actions are defined once, like a game's shared Controls module.
	local Gameplay = Input.context("Gameplay")
	local Overlay = Input.context("Overlay", { priority = 5 })
	local Menu = Input.context("Menu", { priority = 10, sink = true, enabled = false })
	local Vehicle = Input.context("Vehicle", { priority = 0, enabled = false })

	local Jump = Gameplay:button("Jump", { Key.Space, Key.ButtonA }, { touch = true })
	local Interact = Gameplay:button("Interact", { Key.E, Key.ButtonX }, { touch = { text = "Use" } })
	local Sprint = Gameplay:button("Sprint", { Key.LeftShift, Key.ButtonL3 })
	local Crouch = Gameplay:button("Crouch", { Key.C })
	local Save = Gameplay:button("Save", { { key = Key.S, modifiers = { Key.LeftControl } } })
	local Move = Gameplay:vector2("Move", {
		{ up = Key.W, down = Key.S, left = Key.A, right = Key.D },
		Key.Thumbstick1,
	})
	local Aim = Gameplay:vector2("Aim", { Enum.UserInputType.MouseMovement, Key.Thumbstick2 })
	local Zoom = Gameplay:axis("Zoom", { Enum.UserInputType.MouseWheel, { key = Key.Thumbstick2, axis = "y" } })
	local Ping = Overlay:button("Ping", { Key.E, Key.ButtonY })
	local Confirm = Menu:button("Confirm", { Key.E, Key.ButtonA })
	local Back = Menu:button("Back", { Key.Backspace, Key.ButtonB })
	local Throttle = Vehicle:axis("Throttle", { { positive = Key.W, negative = Key.S }, Key.ButtonR2 })
	local Wave = Input.button("Wave", { Key.G })

	test.on_test_leave(function()
		Input.reset()
	end)

	test.suite("Input actions", function()
		test.case("a button begins on the first press and ends on the last release", function()
			Hydrogen.test({}, function(t)
				local log = record(Jump)
				simulate.press(Key.Space)
				check.equal(Jump:held(), true)
				check.equal(Jump:value(), true)
				simulate.press(Key.ButtonA)
				simulate.release(Key.Space)
				check.equal(Jump:held(), true)
				simulate.release(Key.ButtonA)
				check.equal(Jump:held(), false)
				check.equal(table.concat(log, ","), "changed:true,began:true,changed:false,ended")
				-- Repeated presses of a held key don't begin again.
				simulate.press(Key.Space)
				simulate.press(Key.Space)
				simulate.release(Key.Space)
				check.equal(#log, 8)
			end)
			return nil
		end)

		test.case("actions in the default context work without a context", function()
			Hydrogen.test({}, function(t)
				check.equal(Wave.context.name, "Default")
				local began = 0
				Wave:onBegan(function()
					began += 1
				end)
				simulate.tap(Key.G)
				check.equal(began, 1)
			end)
			return nil
		end)

		test.case("a disconnected listener stops", function()
			Hydrogen.test({}, function(t)
				local count = 0
				local disconnect = Jump:onBegan(function()
					count += 1
				end)
				simulate.tap(Key.Space)
				disconnect()
				disconnect()
				simulate.tap(Key.Space)
				check.equal(count, 1)
			end)
			return nil
		end)

		test.case("a listener that errors is warned about and the others still run", function()
			Hydrogen.test({}, function(t)
				local ran = false
				Jump:onBegan(function()
					error("boom")
				end)
				Jump:onBegan(function()
					ran = true
				end)
				simulate.tap(Key.Space)
				check.equal(ran, true)
				t:expectWarning("Input action Jump onBegan listener errored")
			end)
			return nil
		end)

		test.case("a listener that yields doesn't hold up the others", function()
			Hydrogen.test({}, function(t)
				local order = {}
				Jump:onBegan(function()
					Hydrogen.Clock.wait(1)
					table.insert(order, "slow")
				end)
				Jump:onBegan(function()
					table.insert(order, "fast")
				end)
				simulate.press(Key.Space)
				check.equal(table.concat(order, ","), "fast")
				t:advance(1)
				check.equal(table.concat(order, ","), "fast,slow")
			end)
			return nil
		end)

		test.case("onHold fires once per press after the time, and not after an early release", function()
			Hydrogen.test({}, function(t)
				local held = 0
				Interact:onHold(1, function()
					held += 1
				end)
				simulate.press(Key.E)
				t:advance(0.5)
				simulate.release(Key.E)
				t:advance(2)
				check.equal(held, 0)

				simulate.press(Key.E)
				t:advance(1)
				check.equal(held, 1)
				t:advance(5)
				check.equal(held, 1)
				simulate.release(Key.E)

				-- A quick re-press doesn't inherit the earlier press's timer.
				simulate.press(Key.E)
				t:advance(0.5)
				simulate.release(Key.E)
				simulate.press(Key.E)
				t:advance(0.5)
				check.equal(held, 1)
				t:advance(0.5)
				check.equal(held, 2)
			end)
			return nil
		end)

		test.case("modifiers: Ctrl+S fires Save and not a plain S binding; either hand counts", function()
			Hydrogen.test({}, function(t)
				simulate.press(Key.S)
				check.equal(Save:held(), false)
				check.equal(near(Move:value(), Vector2.new(0, -1)), true)
				simulate.release(Key.S)

				simulate.press(Key.RightControl)
				simulate.press(Key.S)
				check.equal(Save:held(), true)
				-- Releasing the modifier first keeps the action held until its key is released.
				simulate.release(Key.RightControl)
				check.equal(Save:held(), true)
				simulate.release(Key.S)
				check.equal(Save:held(), false)
			end)
			return nil
		end)

		test.case("defining errors say what is wrong", function()
			check.should_error(function()
				Gameplay:button("Jump", { Key.Space })
				return nil
			end)
			check.should_error(function()
				Input.context("Gameplay")
				return nil
			end)
			check.should_error(function()
				Gameplay:vector2("BadMove", { Key.Space })
				return nil
			end)
			check.should_error(function()
				Gameplay:button("BadButton", { Key.Thumbstick1 })
				return nil
			end)
			check.should_error(function()
				Gameplay:button("BadMixed", { { key = Key.ButtonA, modifiers = { Key.LeftShift } } })
				return nil
			end)
			check.should_error(function()
				Gameplay:axis("BadTouch", { Key.E }, { touch = true } :: any)
				return nil
			end)
			check.should_error(function()
				Input.context("BadOptions", { priorty = 2 } :: any)
				return nil
			end)
			local ok, err = pcall(Gameplay.vector2, Gameplay, "BadMove2", { Key.Space })
			check.equal(ok, false)
			check.equal(string.find(tostring(err), "[HYDROGEN] Input action BadMove2 (vector2): binding 1", 1, true) ~= nil, true)
			return nil
		end)
	end)

	test.suite("Input axes", function()
		test.case("a composite vector2 is normalized on diagonals", function()
			Hydrogen.test({}, function(t)
				simulate.press(Key.W)
				check.equal(near(Move:value(), Vector2.new(0, 1)), true)
				simulate.press(Key.D)
				local diagonal = Move:value()
				check.equal(math.abs(diagonal.Magnitude - 1) < 1e-6, true)
				check.equal(diagonal.X > 0 and diagonal.Y > 0, true)
				simulate.press(Key.S)
				check.equal(near(Move:value(), Vector2.new(1, 0)), true)
				simulate.release(Key.W)
				simulate.release(Key.S)
				simulate.release(Key.D)
				check.equal(Move:held(), false)
			end)
			return nil
		end)

		test.case("sticks apply the dead zone and rescale", function()
			Hydrogen.test({}, function(t)
				local log = record(Move)
				simulate.move(Key.Thumbstick1, Vector2.new(0.1, 0))
				check.equal(Move:held(), false)
				check.equal(#log, 0)
				simulate.move(Key.Thumbstick1, Vector2.new(1, 0))
				check.equal(near(Move:value(), Vector2.new(1, 0)), true)
				simulate.move(Key.Thumbstick1, Vector2.new(0.575, 0))
				check.equal(near(Move:value(), Vector2.new(0.5, 0)), true)
				simulate.move(Key.Thumbstick1, Vector2.zero)
				check.equal(Move:held(), false)
				check.equal(log[#log], "ended")

				Input.configure({ deadzone = 0.5 })
				simulate.move(Key.Thumbstick1, Vector2.new(0.4, 0))
				check.equal(Move:held(), false)
			end)
			return nil
		end)

		test.case("an axis from two keys, a trigger and a stick axis", function()
			Hydrogen.test({}, function(t)
				Vehicle:enable()
				simulate.press(Key.W)
				check.equal(Throttle:value(), 1)
				simulate.press(Key.S)
				check.equal(Throttle:value(), 0)
				simulate.release(Key.W)
				check.equal(Throttle:value(), -1)
				simulate.release(Key.S)

				simulate.move(Key.ButtonR2, 0.25)
				check.equal(Throttle:value(), 0.25)
				simulate.move(Key.ButtonR2, 0)
				check.equal(Throttle:held(), false)
				-- A trigger pressed with no analog value counts as fully down.
				simulate.press(Key.ButtonR2)
				check.equal(Throttle:value(), 1)
				simulate.release(Key.ButtonR2)

				simulate.move(Key.Thumbstick2, Vector2.new(0, 1))
				check.equal(Zoom:value(), 1)
				simulate.move(Key.Thumbstick2, Vector2.zero)
			end)
			return nil
		end)

		test.case("mouse deltas last until the end of the frame", function()
			Hydrogen.test({}, function(t)
				local changes = {}
				Aim:onChanged(function(value: Vector2)
					table.insert(changes, value)
				end)
				simulate.move(Enum.UserInputType.MouseMovement, Vector2.new(3, -2))
				simulate.move(Enum.UserInputType.MouseMovement, Vector2.new(1, 0))
				check.equal(near(Aim:value(), Vector2.new(4, -2)), true)
				t:advance(0)
				check.equal(Aim:value(), Vector2.zero)
				check.equal(#changes, 3)

				simulate.move(Enum.UserInputType.MouseWheel, 1)
				check.equal(Zoom:value(), 1)
				t:advance(0)
				check.equal(Zoom:value(), 0)
				-- Nothing waits for frames once the mouse is still.
				check.equal(Hydrogen.Clock.active() ~= nil, true)
			end)
			return nil
		end)

		test.case("a source drives an action directly while its context is enabled", function()
			Hydrogen.test({}, function(t)
				local stick = Input.source(Move)
				stick:set(Vector2.new(0, 0.5))
				check.equal(near(Move:value(), Vector2.new(0, 0.5)), true)
				simulate.press(Key.W)
				check.equal(near(Move:value(), Vector2.new(0, 1)), true)
				simulate.release(Key.W)
				Gameplay:disable()
				check.equal(Move:held(), false)
				Gameplay:enable()
				check.equal(near(Move:value(), Vector2.new(0, 0.5)), true)
				stick:destroy()
				check.equal(Move:held(), false)

				local button = Input.source(Jump)
				button:press()
				check.equal(Jump:held(), true)
				button:release()
				check.equal(Jump:held(), false)
				check.should_error(function()
					stick:set(1 :: any)
					return nil
				end)
			end)
			return nil
		end)
	end)

	test.suite("Input contexts", function()
		test.case("a higher-priority sinking context takes the keys it binds", function()
			Hydrogen.test({}, function(t)
				local interact = record(Interact)
				local confirm = record(Confirm)
				simulate.tap(Key.E)
				check.equal(#interact, 4)
				check.equal(#confirm, 0)

				Menu:enable()
				simulate.tap(Key.E)
				check.equal(#interact, 4)
				check.equal(#confirm, 4)

				-- Keys the menu doesn't bind still reach gameplay.
				simulate.tap(Key.Space)
				check.equal(Jump:held(), false)
				local jumped = false
				Jump:onBegan(function()
					jumped = true
				end)
				simulate.tap(Key.Space)
				check.equal(jumped, true)
			end)
			return nil
		end)

		test.case("contexts that don't sink pass keys on, and equal priorities all receive them", function()
			Hydrogen.test({}, function(t)
				simulate.press(Key.E)
				check.equal(Ping:held(), true)
				check.equal(Interact:held(), true)
				simulate.release(Key.E)

				-- Vehicle and Gameplay share priority 0, so W reaches both.
				Vehicle:enable()
				simulate.press(Key.W)
				check.equal(Throttle:value(), 1)
				check.equal(near(Move:value(), Vector2.new(0, 1)), true)
				simulate.release(Key.W)
			end)
			return nil
		end)

		test.case("disabling a context ends its held actions; re-enabling doesn't press them again", function()
			Hydrogen.test({}, function(t)
				local sprint = record(Sprint)
				simulate.press(Key.LeftShift)
				simulate.press(Key.W)
				Gameplay:disable()
				check.equal(Sprint:held(), false)
				check.equal(sprint[#sprint], "ended")
				check.equal(Move:held(), false)

				Gameplay:enable()
				-- A held button stays released (no surprise jump when a menu closes)...
				check.equal(Sprint:held(), false)
				-- ...but axes resume from what is held, so walking continues.
				check.equal(near(Move:value(), Vector2.new(0, 1)), true)
				simulate.release(Key.LeftShift)
				simulate.release(Key.W)
				check.equal(#sprint, 4)
			end)
			return nil
		end)

		test.case("enabling a sinking context mid-press releases what it now takes", function()
			Hydrogen.test({}, function(t)
				simulate.press(Key.E)
				check.equal(Interact:held(), true)
				Menu:enable()
				check.equal(Interact:held(), false)
				-- The press started before the menu opened, so it doesn't confirm.
				check.equal(Confirm:held(), false)
				simulate.release(Key.E)
				check.equal(Confirm:held(), false)
			end)
			return nil
		end)

		test.case("enableFor and disableFor are counted and tied to scopes", function()
			Hydrogen.test({}, function(t)
				local inventory = Scope.new("Inventory")
				local map = Scope.new("Map")
				Menu:enableFor(inventory)
				Gameplay:disableFor(inventory)
				local undoMap = Menu:enableFor(map)
				Gameplay:disableFor(map)
				check.equal(Menu:enabled(), true)
				check.equal(Gameplay:enabled(), false)

				inventory:destroy()
				check.equal(Menu:enabled(), true)
				check.equal(Gameplay:enabled(), false)

				undoMap()
				undoMap()
				check.equal(Menu:enabled(), false)
				check.equal(Gameplay:enabled(), false)
				map:destroy()
				check.equal(Gameplay:enabled(), true)

				-- disableFor wins over enable.
				local undo = Gameplay:disableFor()
				Gameplay:enable()
				check.equal(Gameplay:enabled(), false)
				undo()
				check.equal(Gameplay:enabled(), true)
			end)
			return nil
		end)

		test.case("Hydrogen.test resets contexts, bindings and held keys between tests", function()
			Hydrogen.test({}, function(t)
				Menu:enable()
				Gameplay:disableFor()
				Jump:rebind(Key.J)
				simulate.press(Key.W)
				simulate.device("gamepad")
			end)
			check.equal(Menu:enabled(), false)
			check.equal(Gameplay:enabled(), true)
			check.equal(Jump:bindings("keyboard")[1], Key.Space)
			check.equal(Move:held(), false)
			check.equal(Input.device(), "keyboard")
			return nil
		end)
	end)

	test.suite("Input rebinding", function()
		test.case("a rebind that conflicts in the same context is rejected by default", function()
			Hydrogen.test({}, function(t)
				local ok, conflicts = Jump:rebind(Key.C)
				check.equal(ok, false)
				check.equal(#conflicts, 1)
				check.equal(conflicts[1].action, Crouch)
				check.equal(conflicts[1].binding, Key.C)
				check.equal(conflicts[1].device, "keyboard")
				check.equal(conflicts[1].slot, 1)
				check.equal(Jump:bindings("keyboard")[1], Key.Space)

				-- conflicts() reports the same without changing anything.
				check.equal(#Jump:conflicts(Key.C), 1)
				check.equal(#Jump:conflicts(Key.J), 0)
			end)
			return nil
		end)

		test.case("swap, unbind and allow resolve conflicts", function()
			Hydrogen.test({}, function(t)
				local ok = Jump:rebind(Key.C, { conflict = "swap" })
				check.equal(ok, true)
				check.equal(Jump:bindings("keyboard")[1], Key.C)
				check.equal(Crouch:bindings("keyboard")[1], Key.Space)

				Jump:rebind(Key.LeftShift, { conflict = "unbind" })
				check.equal(Jump:bindings("keyboard")[1], Key.LeftShift)
				check.equal(#Sprint:bindings("keyboard"), 0)

				local allowed, conflicts = Crouch:rebind(Key.LeftShift, { conflict = "allow" })
				check.equal(allowed, true)
				check.equal(#conflicts, 1)
				simulate.press(Key.LeftShift)
				check.equal(Jump:held() and Crouch:held(), true)
				simulate.release(Key.LeftShift)
			end)
			return nil
		end)

		test.case("swap and unbind change only the clashing direction of a composite", function()
			Hydrogen.test({}, function(t)
				local ok, conflicts = Jump:rebind(Key.W, { conflict = "swap" })
				check.equal(ok, true)
				check.equal(#conflicts, 2)
				check.equal((Move:bindings("keyboard")[1] :: any).up, Key.Space)
				check.equal((Throttle:bindings("keyboard")[1] :: any).positive, Key.Space)
				simulate.press(Key.Space)
				check.equal(near(Move:value(), Vector2.new(0, 1)), true)
				check.equal(Jump:held(), false)
				simulate.release(Key.Space)

				Crouch:rebind(Key.D, { conflict = "unbind" })
				local move = Move:bindings("keyboard")[1] :: any
				check.equal(move.right, nil)
				check.equal(move.left, Key.A)
				simulate.press(Key.S)
				check.equal(near(Move:value(), Vector2.new(0, -1)), true)
				simulate.release(Key.S)

				-- Ctrl+S can't be a direction, so swapping it in removes the direction instead.
				Save:rebind(Key.A, { conflict = "swap" })
				check.equal((Move:bindings("keyboard")[1] :: any).left, nil)
			end)
			return nil
		end)

		test.case("conflicts across contexts only count when both would fire", function()
			Hydrogen.test({}, function(t)
				-- Menu sinks and outranks Gameplay: Back on C never fires Crouch.
				check.equal(#Back:conflicts(Key.C), 0)
				-- Overlay outranks Gameplay but passes keys on: Ping on C would fire Crouch too.
				check.equal(#Ping:conflicts(Key.C), 1)
				-- Composite parts count, and disabled contexts too (they can be enabled together):
				-- Jump on W would also move, and also throttle in a vehicle.
				check.equal(#Jump:conflicts(Key.W), 2)
				-- Ctrl+C is a different press from C; Ctrl+S is Save's, from either hand.
				check.equal(#Save:conflicts({ key = Key.C, modifiers = { Key.LeftControl } }), 0)
				check.equal(#Jump:conflicts({ key = Key.S, modifiers = { Key.RightControl } }), 1)
			end)
			return nil
		end)

		test.case("slots, unbind and reset", function()
			Hydrogen.test({}, function(t)
				Jump:rebind(Key.J, { slot = 2 })
				check.equal(#Jump:bindings("keyboard"), 2)
				simulate.tap(Key.J)
				local jumped = false
				Jump:onBegan(function()
					jumped = true
				end)
				simulate.tap(Key.J)
				check.equal(jumped, true)

				Jump:unbind("keyboard", 1)
				check.equal(Jump:bindings("keyboard")[1], Key.J)
				Jump:unbind("gamepad")
				check.equal(#Jump:bindings("gamepad"), 0)
				Jump:resetBindings()
				check.equal(Jump:bindings("keyboard")[1], Key.Space)
				check.equal(Jump:bindings("gamepad")[1], Key.ButtonA)
				check.should_error(function()
					Jump:unbind("touch" :: any)
					return nil
				end)
			end)
			return nil
		end)

		test.case("rebinding a held key releases the action", function()
			Hydrogen.test({}, function(t)
				simulate.press(Key.Space)
				check.equal(Jump:held(), true)
				Jump:rebind(Key.J)
				check.equal(Jump:held(), false)
				simulate.release(Key.Space)
				check.equal(Jump:held(), false)
			end)
			return nil
		end)

		test.case("bindings save as plain data and load back, skipping what's broken", function()
			Hydrogen.test({}, function(t)
				local changed = 0
				Input.onBindingsChanged(function()
					changed += 1
				end)
				check.equal(next(Input.saveBindings()), nil)
				Jump:rebind(Key.J)
				Save:rebind({ key = Key.P, modifiers = { Key.LeftControl } })
				Move:rebind({ up = Key.I, down = Key.K, left = Key.J, right = Key.L }, { conflict = "allow" })
				check.equal(changed, 3)

				local saved = Input.saveBindings()
				check.equal(saved.Jump.keyboard[1], "J")
				check.equal(saved.Jump.gamepad, nil)
				check.equal((saved.Save.keyboard[1] :: any).key, "P")
				check.equal((saved.Save.keyboard[1] :: any).modifiers[1], "LeftControl")
				check.equal((saved.Move.keyboard[1] :: any).up, "I")

				Input.resetBindings()
				check.equal(Jump:bindings("keyboard")[1], Key.Space)
				Input.loadBindings(saved)
				check.equal(Jump:bindings("keyboard")[1], Key.J)
				check.equal((Move:bindings("keyboard")[1] :: any).left, Key.J)
				simulate.press(Key.I)
				check.equal(near(Move:value(), Vector2.new(0, 1)), true)
				simulate.release(Key.I)

				Input.loadBindings({
					Jump = { keyboard = { "NotAKey", "K" } },
					Crouch = { keyboard = { "Thumbstick1" } },
					Sprint = { gamepad = { "Q" } },
					RemovedInAnUpdate = { keyboard = { "Z" } },
					Wave = { phone = { "G" } },
				} :: any)
				check.equal(Jump:bindings("keyboard")[1], Key.K)
				check.equal(Crouch:bindings("keyboard")[1], Key.C)
				check.equal(Sprint:bindings("gamepad")[1], Key.ButtonL3)
				check.equal(Jump:bindings("keyboard")[2], nil)
				t:expectWarning("skipped a keyboard binding of Jump")
				t:expectWarning("skipped a keyboard binding of Crouch")
				t:expectWarning("skipped a gamepad binding of Sprint: it is a keyboard binding")
				t:expectWarning("skipped Wave.phone")

				Input.loadBindings(nil :: any)
				check.equal(Jump:bindings("keyboard")[1], Key.Space)
				t:expectWarning("Input.loadBindings expects the table")
			end)
			return nil
		end)

		test.case("an empty saved list means the player unbound the device", function()
			Hydrogen.test({}, function(t)
				Crouch:unbind("keyboard")
				local saved = Input.saveBindings()
				check.equal(#saved.Crouch.keyboard, 0)
				Input.resetBindings()
				Input.loadBindings(saved)
				check.equal(#Crouch:bindings("keyboard"), 0)
			end)
			return nil
		end)

		test.case("captureKey takes the next press for a rebinding prompt", function()
			Hydrogen.test({}, function(t)
				local captured: Enum.KeyCode? = nil
				Input.captureKey(function(key)
					captured = key :: Enum.KeyCode
				end, "gamepad")
				simulate.press(Key.Space)
				check.equal(captured, nil)
				check.equal(Jump:held(), true)
				simulate.release(Key.Space)

				simulate.press(Key.ButtonA)
				check.equal(captured, Key.ButtonA)
				-- The captured press doesn't jump.
				check.equal(Jump:held(), false)
				simulate.release(Key.ButtonA)

				local cancel = Input.captureKey(function()
					error("cancelled")
				end)
				cancel()
				simulate.tap(Key.Space)
			end)
			return nil
		end)
	end)

	test.suite("Input devices", function()
		test.case("the device follows the last input and drives glyphs", function()
			Hydrogen.test({}, function(t)
				local switches = {}
				Input.onDeviceChanged(function(device, previous)
					table.insert(switches, `{previous}>{device}`)
				end)
				local glyphs = {}
				Interact:observeGlyph(function(glyph)
					table.insert(glyphs, if glyph then `{glyph.device}:{glyph.text}` else "none")
				end)

				check.equal(Input.device(), "keyboard")
				simulate.tap(Key.ButtonA)
				check.equal(Input.device(), "gamepad")
				-- A resting stick inside the dead zone doesn't switch device.
				simulate.tap(Key.E)
				simulate.move(Key.Thumbstick1, Vector2.new(0.05, 0))
				check.equal(Input.device(), "keyboard")
				simulate.device("touch")
				Interact:rebind(Key.F)
				simulate.tap(Key.F)

				check.equal(table.concat(switches, ","), "keyboard>gamepad,gamepad>keyboard,keyboard>touch,touch>keyboard")
				check.equal(table.concat(glyphs, ","), "keyboard:E,gamepad:X,keyboard:E,touch:Use,touch:Use,keyboard:F")
			end)
			return nil
		end)

		test.case("glyphs per device, with modifiers and composites, and a custom provider", function()
			Hydrogen.test({}, function(t)
				local jump = Jump:glyph("gamepad") :: Hydrogen.InputGlyph
				check.equal(jump.key, "ButtonA")
				check.equal(jump.text, "A")
				check.equal((Save:glyph() :: Hydrogen.InputGlyph).text, "Ctrl+S")
				check.equal((Move:glyph() :: Hydrogen.InputGlyph).text, "W/S/A/D")
				check.equal((Sprint:glyph() :: Hydrogen.InputGlyph).text, "Shift")
				check.equal(Sprint:glyph("touch"), nil)
				check.equal((Jump:glyph("touch") :: Hydrogen.InputGlyph).text, "Jump")

				Input.glyphs(function(key, device)
					if device == "gamepad" then
						return { key = key, device = device, text = key, image = `rbxassetid://{key}` }
					end
					return nil
				end)
				check.equal((Jump:glyph("gamepad") :: Hydrogen.InputGlyph).image, "rbxassetid://ButtonA")
				check.equal((Jump:glyph("keyboard") :: Hydrogen.InputGlyph).text, "Space")
			end)
			return nil
		end)

		test.case("touch buttons appear on touch, follow their context and press their action", function()
			Hydrogen.test({}, function(t)
				local folder = Instance.new("Folder")
				Input.configure({ touchParent = folder })
				check.equal(folder:FindFirstChild("HydrogenTouch"), nil)
				check.equal(Jump:touchButton(), nil)

				simulate.device("touch")
				local gui = folder:FindFirstChild("HydrogenTouch") :: ScreenGui
				check.equal(gui ~= nil, true)
				check.equal(gui.Enabled, true)
				local use = Interact:touchButton() :: TextButton
				check.equal(use.Text, "Use")
				check.equal(use.Visible, true)
				check.equal(Sprint:touchButton(), nil)

				Gameplay:disable()
				check.equal(use.Visible, false)
				Gameplay:enable()
				simulate.tap(Key.E)
				check.equal(gui.Enabled, false)

				Input.reset()
				check.equal(gui.Parent, nil)
			end)
			return nil
		end)

		test.case("bindButton presses while any finger is down, and lets go when the context closes", function()
			Hydrogen.test({}, function(t)
				local button = { InputBegan = fakeSignal(), InputEnded = fakeSignal() }
				local scope = Scope.new()
				Input.bindButton(Interact, button :: any, scope)

				local function touch()
					local changed = fakeSignal()
					local input = {
						UserInputType = Enum.UserInputType.Touch,
						UserInputState = Enum.UserInputState.Begin,
					}
					function input:GetPropertyChangedSignal()
						return changed
					end
					return input, function()
						input.UserInputState = Enum.UserInputState.End
						changed:fire()
					end
				end

				local first, liftFirst = touch()
				local second, liftSecond = touch()
				button.InputBegan:fire(first)
				button.InputBegan:fire(second)
				check.equal(Interact:held(), true)
				-- The first finger slid off the button and lifted elsewhere.
				liftFirst()
				check.equal(Interact:held(), true)
				button.InputEnded:fire(second)
				liftSecond()
				check.equal(Interact:held(), false)

				-- Keyboard presses on the button are ignored.
				button.InputBegan:fire({ UserInputType = Enum.UserInputType.Keyboard })
				check.equal(Interact:held(), false)

				local third = touch()
				button.InputBegan:fire(third)
				Gameplay:disable()
				check.equal(Interact:held(), false)
				Gameplay:enable()

				scope:destroy()
				local fourth = touch()
				button.InputBegan:fire(fourth)
				check.equal(Interact:held(), false)
				check.should_error(function()
					Input.bindButton(Move :: any, button :: any)
					return nil
				end)
			end)
			return nil
		end)

		test.case("UserInputService events become actions; processed input and lost focus are handled", function()
			Hydrogen.test({}, function(t)
				local service = {
					InputBegan = fakeSignal(),
					InputChanged = fakeSignal(),
					InputEnded = fakeSignal(),
					LastInputTypeChanged = fakeSignal(),
					WindowFocusReleased = fakeSignal(),
					TouchEnabled = false,
					KeyboardEnabled = true,
				}
				function service:GetLastInputType()
					return Enum.UserInputType.Gamepad1
				end
				local disconnect = Device.connect(service)
				check.equal(Input.device(), "gamepad")

				local function key(code: Enum.KeyCode): any
					return { UserInputType = Enum.UserInputType.Keyboard, KeyCode = code }
				end

				-- Typing in chat: the press is processed and no action begins.
				service.InputBegan:fire(key(Key.Space), true)
				check.equal(Jump:held(), false)
				service.InputEnded:fire(key(Key.Space), true)

				service.InputBegan:fire(key(Key.Space), false)
				check.equal(Jump:held(), true)
				-- A release that arrives processed (a TextBox took focus) still lets go.
				service.InputEnded:fire(key(Key.Space), true)
				check.equal(Jump:held(), false)

				service.InputBegan:fire(key(Key.LeftShift), false)
				service.InputBegan:fire(key(Key.W), false)
				service.InputChanged:fire({
					UserInputType = Enum.UserInputType.Gamepad1,
					KeyCode = Key.Thumbstick2,
					Position = Vector3.new(0, 1, 0),
				}, false)
				check.equal(Sprint:held(), true)
				check.equal(Zoom:value(), 1)
				service.WindowFocusReleased:fire()
				check.equal(Sprint:held(), false)
				check.equal(Move:held(), false)
				check.equal(Zoom:value(), 0)

				service.InputChanged:fire({
					UserInputType = Enum.UserInputType.MouseMovement,
					KeyCode = Key.Unknown,
					Delta = Vector3.new(2, 3, 0),
				}, false)
				check.equal(near(Aim:value(), Vector2.new(2, 3)), true)
				t:advance(0)

				service.InputBegan:fire({ UserInputType = Enum.UserInputType.Gamepad1, KeyCode = Key.ButtonR2 }, false)
				service.InputChanged:fire({
					UserInputType = Enum.UserInputType.Gamepad1,
					KeyCode = Key.ButtonR2,
					Position = Vector3.new(0, 0, 0.5),
				}, false)
				Vehicle:enable()
				check.equal(Throttle:value(), 0.5)
				service.InputEnded:fire({ UserInputType = Enum.UserInputType.Gamepad1, KeyCode = Key.ButtonR2 }, false)
				check.equal(Throttle:value(), 0)

				service.LastInputTypeChanged:fire(Enum.UserInputType.Touch)
				check.equal(Input.device(), "touch")
				service.LastInputTypeChanged:fire(Enum.UserInputType.MouseMovement)
				check.equal(Input.device(), "keyboard")
				service.LastInputTypeChanged:fire(Enum.UserInputType.Focus)
				check.equal(Input.device(), "keyboard")

				disconnect()
				service.InputBegan:fire(key(Key.Space), false)
				check.equal(Jump:held(), false)
			end)
			return nil
		end)

		test.case("listening on the server warns once", function()
			Hydrogen.test({}, function(t)
				local isServer = Core.isServer
				Core.isServer = function()
					return true
				end
				local ok, err = pcall(function()
					Jump:onBegan(function() end)
					Sprint:onEnded(function() end)
				end)
				Core.isServer = isServer
				assert(ok, err)
				t:expectWarning("Hydrogen.Input is client-only: Jump:onBegan")
				check.equal(#t:warnings(), 1)
			end)
			return nil
		end)
	end)
end
