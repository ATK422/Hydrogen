--!strict

-- Real input: UserInputService events turned into the key names the engine routes. Started on
-- a client when the first action is defined; never on the server or under Lune.

local Core = require("./Core")
local Keys = require("./Keys")
local Types = require("./Types")

local Device = {}

local started = false

local function deviceOf(inputType: EnumItem): Types.Device?
	local name = inputType.Name
	if name == "Keyboard" or string.sub(name, 1, 5) == "Mouse" then
		return "keyboard"
	elseif string.sub(name, 1, 7) == "Gamepad" then
		return "gamepad"
	elseif name == "Touch" then
		return "touch"
	end
	return nil
end

local function keyOf(input: InputObject): string?
	local inputType = input.UserInputType.Name
	if inputType == "Keyboard" or string.sub(inputType, 1, 7) == "Gamepad" then
		return Keys.name(input.KeyCode)
	end
	return Keys.name(input.UserInputType)
end

-- Connects to a UserInputService (or anything shaped like one, in tests). Returns a function
-- that disconnects it.
function Device.connect(service: any): () -> ()
	local connections = {}

	-- gameProcessed is true while typing in a TextBox or pressing a GuiButton: no action begins.
	table.insert(
		connections,
		service.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			local key = keyOf(input)
			if key == nil or gameProcessed or Keys.isStick(key) or Keys.isDelta(key) then
				return
			end
			Core.press(key)
		end)
	)

	table.insert(
		connections,
		service.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
			local key = keyOf(input)
			if key == nil then
				return
			end
			if Keys.isStick(key) then
				-- A stick moved while UI has gamepad selection steers the UI, not the game.
				local position = input.Position
				Core.move(key, if gameProcessed then Vector2.zero else Vector2.new(position.X, position.Y))
			elseif Keys.isTrigger(key) then
				Core.move(key, if gameProcessed then 0 else input.Position.Z)
			elseif key == "MouseMovement" then
				if not gameProcessed then
					Core.move(key, Vector2.new(input.Delta.X, input.Delta.Y))
				end
			elseif key == "MouseWheel" then
				if not gameProcessed then
					Core.move(key, input.Position.Z)
				end
			end
		end)
	)

	-- Ends are handled even when processed: a key pressed before a TextBox took focus must let go.
	table.insert(
		connections,
		service.InputEnded:Connect(function(input: InputObject)
			local key = keyOf(input)
			if key == nil or Keys.isDelta(key) then
				return
			end
			if Keys.isStick(key) then
				Core.move(key, Vector2.zero)
				return
			end
			if Keys.isTrigger(key) then
				Core.move(key, 0)
			end
			Core.release(key)
		end)
	)

	table.insert(
		connections,
		service.LastInputTypeChanged:Connect(function(inputType: EnumItem)
			local device = deviceOf(inputType)
			if device then
				Core.setDevice(device)
			end
		end)
	)

	-- Alt-tabbing while holding a key can swallow its release; nothing stays stuck down.
	table.insert(
		connections,
		service.WindowFocusReleased:Connect(function()
			Core.releaseAll()
		end)
	)

	local initial: Types.Device? = deviceOf(service:GetLastInputType())
	if initial == nil and service.TouchEnabled and not service.KeyboardEnabled then
		initial = "touch"
	end
	Core.setDevice(initial or "keyboard")

	Core.engineGlyph = function(key: string): (string?, string?)
		if Keys.isDelta(key) or string.sub(key, 1, 5) == "Mouse" then
			return nil, nil
		end
		local text: string? = nil
		local image: string? = nil
		pcall(function()
			local keyCode = Keys.enum(key)
			if Keys.device(key) == "gamepad" then
				local found = service:GetImageForKeyCode(keyCode)
				if type(found) == "string" and found ~= "" then
					image = found
				end
			elseif #key == 1 then
				-- Letters follow the player's layout: KeyCode.Q is "A" on AZERTY.
				local found = service:GetStringForKeyCode(keyCode)
				if type(found) == "string" and found ~= "" then
					text = string.upper(found)
				end
			end
		end)
		return text, image
	end

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		Core.engineGlyph = nil
	end
end

-- Connects the real UserInputService once, on a client.
function Device.ensure()
	if started then
		return
	end
	local ok, client = pcall(function()
		return game:GetService("RunService"):IsClient()
	end)
	if not (ok and client) then
		return
	end
	started = true
	-- Under Lune.install({ client = true }) the service exists but has no events; tests use
	-- Input.simulate there instead.
	pcall(Device.connect, game:GetService("UserInputService"))
end

return Device
