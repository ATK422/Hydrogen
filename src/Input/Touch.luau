--!strict

-- On-screen buttons for touch actions. Nothing is made until the player first uses touch, so a
-- keyboard or gamepad player never pays for them. Any GuiButton can drive an action through
-- Touch.bind; the default buttons use the same function.

local Core = require("./Core")
local Types = require("./Types")

type ActionState = Core.ActionState

local Touch = {}

local gui: ScreenGui? = nil
local grid: Frame? = nil
local buttons: { [ActionState]: GuiButton } = {}
local unbinds: { [ActionState]: () -> () } = {}
local waitingForPlayerGui = false

-- Presses the action while a finger (or the mouse, for testing in Studio) is down on the button.
function Touch.bind(action: ActionState, button: any): () -> ()
	local source = Core.source(action)
	-- Input -> the connection watching it end, or true if it can't be watched.
	local touching: { [any]: any } = {}

	local function finish(input: any)
		local watcher = touching[input]
		if watcher == nil then
			return
		end
		touching[input] = nil
		if watcher ~= true then
			watcher:Disconnect()
		end
		if next(touching) == nil then
			source:release()
		end
	end

	local began = button.InputBegan:Connect(function(input: any)
		local kind = input.UserInputType
		if kind ~= Enum.UserInputType.Touch and kind ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if touching[input] ~= nil then
			return
		end
		touching[input] = true
		-- A finger can slide off the button before it lifts; its InputObject still reports the end.
		local ok, signal = pcall(function()
			return input:GetPropertyChangedSignal("UserInputState")
		end)
		if ok and signal then
			touching[input] = signal:Connect(function()
				local state = input.UserInputState
				if state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
					finish(input)
				end
			end)
		end
		source:press()
	end)
	local ended = button.InputEnded:Connect(finish)

	local bound = true
	return function()
		if not bound then
			return
		end
		bound = false
		began:Disconnect()
		ended:Disconnect()
		for input in table.clone(touching) do
			finish(input)
		end
		source:destroy()
	end
end

local function parent(): Instance?
	local configured = Core.config.touchParent
	if configured then
		return configured
	end
	-- Lune's Players has no LocalPlayer, and the server has none either.
	local found, player = pcall(function(): Player?
		return game:GetService("Players").LocalPlayer
	end)
	if not found or player == nil then
		return nil
	end
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui == nil and not waitingForPlayerGui then
		waitingForPlayerGui = true
		task.spawn(function()
			player:WaitForChild("PlayerGui")
			waitingForPlayerGui = false
			Touch.update()
		end)
	end
	return playerGui
end

local function build(at: Instance)
	local screen = Instance.new("ScreenGui")
	screen.Name = "HydrogenTouch"
	screen.ResetOnSpawn = false
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Above and left of Roblox's jump button, filling from the bottom right.
	local frame = Instance.new("Frame")
	frame.Name = "Buttons"
	frame.AnchorPoint = Vector2.new(1, 1)
	frame.Position = UDim2.new(1, -16, 1, -170)
	frame.Size = UDim2.fromOffset(216, 216)
	frame.BackgroundTransparency = 1
	frame.Parent = screen

	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(64, 64)
	layout.CellPadding = UDim2.fromOffset(12, 12)
	layout.StartCorner = Enum.StartCorner.BottomRight
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame

	screen.Parent = at
	gui = screen
	grid = frame
end

local function makeButton(action: ActionState): GuiButton
	local options: Types.TouchOptions = action._touch or {}
	local button: GuiButton
	if options.image then
		local image = Instance.new("ImageButton")
		image.Image = options.image
		image.ScaleType = Enum.ScaleType.Fit
		button = image
	else
		local text = Instance.new("TextButton")
		text.Text = options.text or action.name
		text.TextScaled = true
		text.TextColor3 = Color3.new(1, 1, 1)
		button = text
	end
	button.Name = action.name
	button.BackgroundColor3 = Color3.new(0, 0, 0)
	button.BackgroundTransparency = 0.45
	button.LayoutOrder = action._order

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = button

	if options.position or options.size then
		button.AnchorPoint = Vector2.new(0.5, 0.5)
		button.Position = options.position or UDim2.new(1, -120, 1, -260)
		button.Size = options.size or UDim2.fromOffset(64, 64)
		button.Parent = gui
	else
		button.Parent = grid
	end

	-- Lune's Instances have no events; the buttons are still made, so tests can inspect them.
	local ok, unbind = pcall(Touch.bind, action, button)
	if ok then
		unbinds[action] = unbind
	end
	return button
end

-- Shows the buttons while the player uses touch, each only while its action's context is enabled.
function Touch.update()
	local usingTouch = Core.device() == "touch"
	if gui == nil and not usingTouch then
		return
	end
	local touchActions = Core.touchActions()
	if #touchActions == 0 then
		return
	end
	if gui == nil then
		local at = parent()
		if at == nil then
			return
		end
		build(at)
	end
	(gui :: ScreenGui).Enabled = usingTouch
	for _, action in touchActions do
		local button = buttons[action]
		if button == nil then
			button = makeButton(action)
			buttons[action] = button
		end
		button.Visible = action.context._active
	end
end

function Touch.button(action: ActionState): GuiButton?
	return buttons[action]
end

function Touch.reset()
	for _, unbind in unbinds do
		unbind()
	end
	table.clear(unbinds)
	table.clear(buttons)
	local screen = gui
	gui = nil
	grid = nil
	if screen then
		screen:Destroy()
	end
end

return Touch
