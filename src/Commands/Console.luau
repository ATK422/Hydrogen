--!strict

-- The in-game console: a panel at the top of the screen with the output, an input line with
-- history (Up/Down) and autocomplete (Tab, or tap a suggestion), toggled by a key or, on touch
-- screens, a button. Built only in a real client; tested in Studio, since Lune has no GUI.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Types = require("./Types")

type CommandInfo = Types.CommandInfo
type OutputKind = Types.OutputKind
type Completion = Types.Completion
type Suggestion = Types.Suggestion

export type Host = {
	run: (text: string) -> (),
	complete: (text: string) -> Completion,
	commands: () -> { CommandInfo },
}

export type ConsoleOptions = {
	keys: { Enum.KeyCode },
	mobileButton: boolean | "auto",
}

export type Console = {
	open: (self: Console) -> (),
	close: (self: Console) -> (),
	toggle: (self: Console) -> (),
	isOpen: (self: Console) -> boolean,
	push: (self: Console, kind: OutputKind, text: string) -> (),
	setCommands: (self: Console, commands: { CommandInfo }) -> (),
	destroy: (self: Console) -> (),
}

local MAX_LINES = 200
local MAX_HISTORY = 50

local THEME = {
	panel = Color3.fromRGB(17, 18, 23),
	field = Color3.fromRGB(28, 30, 38),
	stroke = Color3.fromRGB(64, 68, 86),
	text = Color3.fromRGB(222, 224, 232),
	muted = Color3.fromRGB(128, 133, 150),
	accent = Color3.fromRGB(122, 162, 255),
	error = Color3.fromRGB(255, 110, 110),
	chip = Color3.fromRGB(36, 39, 50),
}
local MONO = Font.new("rbxasset://fonts/families/RobotoMono.json")
local SANS = Font.new("rbxasset://fonts/families/GothamSSm.json")

local function create(className: string, properties: { [string]: any }, children: { Instance }?): any
	local instance = Instance.new(className)
	for key, value in properties do
		(instance :: any)[key] = value
	end
	local list: { Instance } = children or {}
	for _, child in list do
		child.Parent = instance
	end
	return instance
end

local function corner(radius: number): Instance
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function hex(color: Color3): string
	return color:ToHex()
end

local function escape(text: string): string
	return (string.gsub(text, "[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

local Console = {}

function Console.new(host: Host, options: ConsoleOptions): Console
	local connections: { RBXScriptConnection } = {}
	local history: { string } = {}
	local historyIndex = 0
	local draft = ""
	local suggestions: { Suggestion } = {}
	local selected = 1
	local lineCount = 0
	local opened = false
	local hasRestricted = false

	local gui = create("ScreenGui", {
		Name = "HydrogenConsole",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 1000,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = true,
	})

	local panel = create("Frame", {
		Name = "Panel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 58),
		Size = UDim2.new(1, -24, 0.55, 0),
		BackgroundColor3 = THEME.panel,
		BackgroundTransparency = 0.06,
		Visible = false,
		Parent = gui,
	}, {
		corner(10),
		create("UIStroke", { Color = THEME.stroke, Transparency = 0.35, Thickness = 1 }),
		create("UISizeConstraint", { MaxSize = Vector2.new(760, 420), MinSize = Vector2.new(0, 180) }),
		create("UIPadding", {
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
	})

	local keyName = if #options.keys > 0 then options.keys[1].Name else nil
	create("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		FontFace = SANS,
		TextSize = 13,
		TextColor3 = THEME.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		RichText = true,
		Text = `<b>Console</b>   Tab completes · ↑↓ history{if keyName then ` · {keyName} closes` else ""}`,
		Parent = panel,
	})

	-- Title 16, gaps 8 + 8 + 6, input 34, hint 18, suggestions 26.
	local log = create("ScrollingFrame", {
		Name = "Log",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 24),
		Size = UDim2.new(1, 0, 1, -24 - 8 - 34 - 6 - 18 - 26),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = THEME.stroke,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Parent = panel,
	}, {
		create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim.new(0, 2) }),
	})

	local field = create("Frame", {
		Name = "Input",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, -18 - 26 - 6),
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundColor3 = THEME.field,
		Parent = panel,
	}, {
		corner(7),
		create("UIStroke", { Color = THEME.stroke, Transparency = 0.5, Thickness = 1 }),
		create("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(0, 26, 1, 0),
			FontFace = MONO,
			TextSize = 18,
			TextColor3 = THEME.accent,
			Text = "›",
		}),
	})

	local box = create("TextBox", {
		Name = "Box",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 26, 0, 0),
		Size = UDim2.new(1, -34, 1, 0),
		ClearTextOnFocus = false,
		FontFace = MONO,
		TextSize = 15,
		TextColor3 = THEME.text,
		PlaceholderText = "Type a command (try help)",
		PlaceholderColor3 = THEME.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Parent = field,
	}) :: TextBox

	local hint = create("TextLabel", {
		Name = "Hint",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 2, 1, -26),
		Size = UDim2.new(1, -4, 0, 18),
		FontFace = MONO,
		TextSize = 13,
		TextColor3 = THEME.muted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		RichText = true,
		Text = "",
		Parent = panel,
	})

	local chips = create("Frame", {
		Name = "Suggestions",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.new(1, 0, 0, 22),
		ClipsDescendants = true,
		Parent = panel,
	}, {
		create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 6),
		}),
	})

	local button = create("TextButton", {
		Name = "Toggle",
		Position = UDim2.new(0, 12, 0, 64),
		Size = UDim2.new(0, 44, 0, 44),
		BackgroundColor3 = THEME.panel,
		BackgroundTransparency = 0.15,
		FontFace = MONO,
		TextSize = 16,
		TextColor3 = THEME.accent,
		Text = ">_",
		AutoButtonColor = true,
		Visible = false,
		Parent = gui,
	}, {
		create("UICorner", { CornerRadius = UDim.new(1, 0) }),
		create("UIStroke", { Color = THEME.stroke, Transparency = 0.35 }),
	}) :: TextButton

	local console = {} :: Console

	local function scrollToEnd()
		task.defer(function()
			log.CanvasPosition = Vector2.new(0, math.max(0, log.AbsoluteCanvasSize.Y - log.AbsoluteWindowSize.Y))
		end)
	end

	local function addLine(text: string, color: Color3)
		lineCount += 1
		create("TextLabel", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			FontFace = MONO,
			TextSize = 14,
			TextColor3 = color,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
			RichText = false,
			LayoutOrder = lineCount,
			Text = text,
			Parent = log,
		})
		local labels = {}
		for _, child in log:GetChildren() do
			if child:IsA("TextLabel") then
				table.insert(labels, child)
			end
		end
		if #labels > MAX_LINES then
			table.sort(labels, function(a, b)
				return a.LayoutOrder < b.LayoutOrder
			end)
			for index = 1, #labels - MAX_LINES do
				labels[index]:Destroy()
			end
		end
		scrollToEnd()
	end

	local function renderHint(completion: Completion)
		local usage = completion.usage
		if not usage then
			hint.Text = ""
			return
		end
		local info: CommandInfo? = nil
		for _, command in host.commands() do
			if usage == command.usage then
				info = command
				break
			end
		end
		if not info then
			hint.Text = escape(usage)
			return
		end
		local parts = { escape(info.name) }
		for _, arg in info.args do
			local name = if arg.rest then `{arg.name}...` else arg.name
			local shown = escape(if arg.optional then `[{name}]` else `<{name}>`)
			if completion.arg == arg then
				shown = `<font color="#{hex(THEME.accent)}"><b>{shown}</b></font>`
			end
			table.insert(parts, shown)
		end
		local text = table.concat(parts, " ")
		if completion.arg then
			text ..= `   <font color="#{hex(THEME.muted)}">{escape(completion.arg.type)}</font>`
		elseif info.description ~= "" then
			text ..= `   <font color="#{hex(THEME.muted)}">{escape(info.description)}</font>`
		end
		hint.Text = text
	end

	local accept: (index: number) -> ()

	local function renderSuggestions()
		for _, child in chips:GetChildren() do
			if child:IsA("TextButton") then
				child:Destroy()
			end
		end
		for index, suggestion in suggestions do
			local chip = create("TextButton", {
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.new(0, 0, 1, 0),
				BackgroundColor3 = if index == selected then THEME.accent else THEME.chip,
				BackgroundTransparency = if index == selected then 0.15 else 0,
				FontFace = MONO,
				TextSize = 13,
				TextColor3 = if index == selected then THEME.panel else THEME.text,
				Text = suggestion.label,
				AutoButtonColor = true,
				LayoutOrder = index,
				Parent = chips,
			}, {
				corner(5),
				create("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }),
			}) :: TextButton
			table.insert(connections, chip.Activated:Connect(function()
				accept(index)
			end))
		end
	end

	local function refresh()
		local completion = host.complete(box.Text)
		suggestions = completion.suggestions
		selected = 1
		renderSuggestions()
		renderHint(completion)
	end

	function accept(index: number)
		local suggestion = suggestions[index]
		if not suggestion then
			return
		end
		box.Text = suggestion.text
		box.CursorPosition = #box.Text + 1
		box:CaptureFocus()
	end

	local function submit()
		local text = (string.gsub(box.Text, "\t", ""))
		box.Text = ""
		if string.match(text, "^%s*$") then
			return
		end
		if history[#history] ~= text then
			table.insert(history, text)
			if #history > MAX_HISTORY then
				table.remove(history, 1)
			end
		end
		historyIndex = 0
		draft = ""
		addLine(`› {text}`, THEME.accent)
		local ok, err = pcall(host.run, text)
		if not ok then
			addLine(tostring(err), THEME.error)
		end
	end

	local function recall(step: number)
		if #history == 0 then
			return
		end
		if historyIndex == 0 then
			draft = box.Text
		end
		historyIndex = math.clamp(historyIndex + step, 0, #history)
		box.Text = if historyIndex == 0 then draft else history[#history - historyIndex + 1]
		box.CursorPosition = #box.Text + 1
	end

	local function updateButton()
		local touch = UserInputService.TouchEnabled
		local wanted = if options.mobileButton == "auto" then hasRestricted else options.mobileButton == true
		button.Visible = touch and wanted
	end

	function console:open()
		if opened then
			return
		end
		opened = true
		panel.Visible = true
		refresh()
		scrollToEnd()
		task.defer(function()
			if opened then
				box:CaptureFocus()
			end
		end)
	end

	function console:close()
		if not opened then
			return
		end
		opened = false
		panel.Visible = false
		box:ReleaseFocus()
	end

	function console:toggle()
		if opened then
			console:close()
		else
			console:open()
		end
	end

	function console:isOpen(): boolean
		return opened
	end

	function console:push(kind: OutputKind, text: string)
		addLine(text, if kind == "error" then THEME.error else THEME.text)
	end

	function console:setCommands(commands: { CommandInfo })
		hasRestricted = false
		for _, info in commands do
			if info.restricted then
				hasRestricted = true
				break
			end
		end
		updateButton()
		if opened then
			refresh()
		end
	end

	function console:destroy()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
		gui:Destroy()
	end

	table.insert(connections, box:GetPropertyChangedSignal("Text"):Connect(function()
		if string.find(box.Text, "\t", 1, true) then
			-- Tab is handled in InputBegan; keep the character out of the line.
			box.Text = (string.gsub(box.Text, "\t", ""))
			return
		end
		refresh()
	end))

	table.insert(connections, box.FocusLost:Connect(function(enterPressed: boolean)
		if not enterPressed then
			return
		end
		submit()
		task.defer(function()
			if opened then
				box:CaptureFocus()
			end
		end)
	end))

	table.insert(connections, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if input.UserInputType ~= Enum.UserInputType.Keyboard then
			return
		end
		local key = input.KeyCode
		if table.find(options.keys, key) then
			-- Typing elsewhere (chat, another TextBox) shouldn't open it; typing here may close it.
			if not processed or box:IsFocused() then
				console:toggle()
			end
			return
		end
		if not (opened and box:IsFocused()) then
			return
		end
		if key == Enum.KeyCode.Tab then
			task.defer(accept, selected)
		elseif key == Enum.KeyCode.Up then
			recall(1)
		elseif key == Enum.KeyCode.Down then
			recall(-1)
		end
	end))

	table.insert(connections, button.Activated:Connect(function()
		console:toggle()
	end))

	updateButton()
	gui.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")

	return console
end

return Console
