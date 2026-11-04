--!strict

-- The client's debug panel. It is built the first time it opens; while closed, nothing runs but
-- one key listener. While open it refreshes about once a second (Debug.configure refresh), never
-- per frame. Headless tests can't draw it, so it is verified in Studio.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Clock = require("../Clock")
local Stats = require("./Stats")
local Server = require("./Server")

export type Source = {
	key: Enum.KeyCode,
	refresh: () -> number,
	fetch: (userId: number?) -> Server.View?,
	warnings: () -> { Server.Warning },
	boot: () -> Server.BootReport?,
}

type View = Server.View
type Lines = { string }

local TABS = { "Network", "Boot", "State", "Player", "Warnings" }
local KINDS = { ClientEvent = "CE", ServerEvent = "SE", ClientFunction = "CF", ServerFunction = "SF" }
-- Client stats keep running this long after the overlay closes.
local LEASE_SECONDS = 3

local BACKGROUND = Color3.fromRGB(18, 18, 22)
local SURFACE = Color3.fromRGB(34, 34, 42)
local ACCENT = Color3.fromRGB(88, 140, 255)
local TEXT = Color3.fromRGB(225, 225, 232)

local Overlay = {}

local source: Source? = nil
local gui: ScreenGui? = nil
local body: TextLabel = nil :: any
local content: ScrollingFrame = nil :: any
local picker: ScrollingFrame = nil :: any
local tabButtons: { [string]: TextButton } = {}
local tab = "Network"
local isOpen = false
local opening = false
-- Bumped on every open and close, so a refresh loop from an earlier open stops.
local generation = 0
local selected: number? = nil
local lastView: View? = nil
local serverNote: string? = nil

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

local function escape(text: string): string
	return (string.gsub(text, "[&<>\"']", {
		["&"] = "&amp;",
		["<"] = "&lt;",
		[">"] = "&gt;",
		['"'] = "&quot;",
		["'"] = "&apos;",
	}))
end

local function heading(text: string): string
	return `<font color="#7FB3FF"><b>{escape(text)}</b></font>`
end

local function dim(text: string): string
	return `<font color="#8A8A99">{escape(text)}</font>`
end

local function pad(text: string, width: number): string
	if #text > width then
		return string.sub(text, 1, width - 1) .. "~"
	end
	return text .. string.rep(" ", width - #text)
end

local function right(text: string, width: number): string
	return string.rep(" ", math.max(width - #text, 0)) .. text
end

local function amount(value: number): string
	if value >= 10000 then
		return string.format("%.1fk", value / 1000)
	elseif value % 1 == 0 then
		return tostring(value)
	end
	return string.format("%.1f", value)
end

local function networkLines(lines: Lines, title: string, stats: { [string]: Stats.NetStat }?)
	table.insert(lines, heading(title))
	if stats == nil then
		table.insert(lines, dim(`  {serverNote or "waiting for the server"}`))
		table.insert(lines, "")
		return
	end

	local list = {}
	for _, stat in stats do
		table.insert(list, stat)
	end
	table.sort(list, function(a, b)
		local aBytes = a.inBytesPerSecond + a.outBytesPerSecond
		local bBytes = b.inBytesPerSecond + b.outBytesPerSecond
		if aBytes ~= bBytes then
			return aBytes > bBytes
		end
		return a.name < b.name
	end)

	table.insert(lines, dim(`{pad("name", 26)} {pad("", 2)} {right("in/s", 6)} {right("out/s", 6)} {right("B/s in", 8)} {right("B/s out", 8)} {right("drop", 5)} {right("ms", 7)}`))
	for _, stat in list do
		local timing = stat.latency or stat.handler
		local ms = if timing then string.format("%.1f", timing.average * 1000) else ""
		local drop = right(tostring(stat.dropped), 5)
		if stat.dropped > 0 then
			drop = `<font color="#FF6B6B">{drop}</font>`
		end
		table.insert(lines, `{escape(pad(stat.name, 26))} {KINDS[stat.kind] or "??"} {right(amount(stat.inPerSecond), 6)} {right(amount(stat.outPerSecond), 6)} {right(amount(stat.inBytesPerSecond), 8)} {right(amount(stat.outBytesPerSecond), 8)} {drop} {right(ms, 7)}`)
	end
	if #list == 0 then
		table.insert(lines, dim("  no traffic yet"))
	end
	table.insert(lines, "")
end

local function bootLines(lines: Lines, title: string, report: Server.BootReport?)
	table.insert(lines, heading(title))
	if report == nil then
		table.insert(lines, dim("  not recorded: App.new({ debug = true, output = Hydrogen.Debug.bootOutput })"))
		table.insert(lines, "")
		return
	end
	table.insert(lines, `  {#report.systems} systems in {string.format("%.2f", report.total)}ms (network {string.format("%.2f", report.network)}ms)`)
	table.insert(lines, dim(`  {pad("system", 40)} {right("init ms", 9)} {right("start ms", 9)}`))
	for _, system in report.systems do
		table.insert(lines, `  {escape(pad(system.name, 40))} {right(string.format("%.2f", system.init), 9)} {right(string.format("%.2f", system.start), 9)}`)
	end
	table.insert(lines, "")
end

local function rowLines(lines: Lines, rows: { Server.Row }, empty: string)
	for _, row in rows do
		table.insert(lines, `  {escape(row.name)} = {escape(row.value)}`)
	end
	if #rows == 0 then
		table.insert(lines, dim(`  {empty}`))
	end
end

local function warningLines(lines: Lines, title: string, list: { Server.Warning }?)
	table.insert(lines, heading(title))
	if list == nil then
		table.insert(lines, dim(`  {serverNote or "waiting for the server"}`))
	elseif #list == 0 then
		table.insert(lines, dim("  none"))
	else
		for index = #list, 1, -1 do
			local warning = list[index]
			table.insert(lines, `{dim(os.date("%H:%M:%S", warning.at) :: string)} <font color="{if warning.level == "error" then "#FF6B6B" else "#FFB86B"}">{escape(warning.text)}</font>`)
		end
	end
	table.insert(lines, "")
end

local function render()
	local src = source
	if not gui or not src then
		return
	end
	local view = lastView
	local lines: Lines = {}

	if tab == "Network" then
		networkLines(lines, "Server", if view then view.stats else nil)
		networkLines(lines, "Client", Stats.snapshot())
		table.insert(lines, dim("CE clientEvent  SE serverEvent  CF clientFunction  SF serverFunction; bytes are estimates"))
	elseif tab == "Boot" then
		bootLines(lines, "Server", if view then view.boot else nil)
		bootLines(lines, "Client", src.boot())
	elseif tab == "State" then
		table.insert(lines, heading("Global state (server)"))
		if view then
			rowLines(lines, view.state, "no Hydrogen.State defined")
		else
			table.insert(lines, dim(`  {serverNote or "waiting for the server"}`))
		end
	elseif tab == "Player" then
		local player = view and view.player
		if player then
			table.insert(lines, heading(`{player.name} ({player.userId})`))
			table.insert(lines, heading("Per-player state"))
			rowLines(lines, player.state, "no per-player Hydrogen.State defined")
			for _, store in player.data do
				table.insert(lines, "")
				table.insert(lines, heading(store.name))
				rowLines(lines, store.fields, "empty")
			end
			if #player.data == 0 then
				table.insert(lines, "")
				table.insert(lines, dim("No Data stores or PlayerStates to show: Debug.configure({ inspect = { PlayerData, Session } })"))
			end
		else
			table.insert(lines, dim(if view then "Pick a player above." else serverNote or "waiting for the server"))
		end
	elseif tab == "Warnings" then
		warningLines(lines, "Server", if view then view.warnings else nil)
		warningLines(lines, "Client", src.warnings())
	end

	body.Text = table.concat(lines, "\n")

	-- Player buttons: rebuilt only when the list changes.
	picker.Visible = tab == "Player"
	content.Position = UDim2.new(0, 0, 0, if picker.Visible then 70 else 36)
	content.Size = UDim2.new(1, 0, 1, if picker.Visible then -70 else -36)
	if picker.Visible and view then
		local names = {}
		for _, entry in view.players do
			table.insert(names, `{entry.userId}`)
		end
		local key = table.concat(names, ",") .. `|{selected}`
		if picker:GetAttribute("Players") ~= key then
			picker:SetAttribute("Players", key)
			for _, child in picker:GetChildren() do
				if child:IsA("TextButton") then
					child:Destroy()
				end
			end
			for order, entry in view.players do
				local button = Instance.new("TextButton")
				button.LayoutOrder = order
				button.AutomaticSize = Enum.AutomaticSize.X
				button.Size = UDim2.new(0, 0, 1, -6)
				button.BackgroundColor3 = if entry.userId == selected then ACCENT else SURFACE
				button.TextColor3 = TEXT
				button.Font = Enum.Font.GothamMedium
				button.TextSize = 13
				button.Text = `  {entry.name}  `
				button.AutoButtonColor = true
				button.Parent = picker
				Instance.new("UICorner").Parent = button
				button.Activated:Connect(function()
					selected = entry.userId
					picker:SetAttribute("Players", nil)
					task.spawn(Overlay.refresh)
				end)
			end
		end
	end

	for name, button in tabButtons do
		button.BackgroundColor3 = if name == tab then ACCENT else SURFACE
	end
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local function corner(parent: Instance, radius: number)
	local item = Instance.new("UICorner")
	item.CornerRadius = UDim.new(0, radius)
	item.Parent = parent
end

local function build(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "HydrogenDebug"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true
	screen.DisplayOrder = 10000
	screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(1, 0)
	panel.Position = UDim2.new(1, -12, 0, 12)
	panel.Size = UDim2.new(0.6, 0, 1, -24)
	panel.BackgroundColor3 = BACKGROUND
	panel.BackgroundTransparency = 0.06
	panel.BorderSizePixel = 0
	panel.Parent = screen
	corner(panel, 8)

	local limits = Instance.new("UISizeConstraint")
	limits.MinSize = Vector2.new(300, 200)
	limits.MaxSize = Vector2.new(680, 760)
	limits.Parent = panel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 10)
	padding.PaddingBottom = UDim.new(0, 10)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = panel

	local header = Instance.new("Frame")
	header.Name = "Header"
	header.BackgroundTransparency = 1
	header.Size = UDim2.new(1, 0, 0, 28)
	header.Parent = panel

	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.Padding = UDim.new(0, 6)
	row.SortOrder = Enum.SortOrder.LayoutOrder
	row.VerticalAlignment = Enum.VerticalAlignment.Center
	row.Parent = header

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.AutomaticSize = Enum.AutomaticSize.X
	title.Size = UDim2.new(0, 0, 1, 0)
	title.Font = Enum.Font.GothamBold
	title.TextSize = 14
	title.TextColor3 = TEXT
	title.Text = "Hydrogen  "
	title.LayoutOrder = 0
	title.Parent = header

	for order, name in TABS do
		local button = Instance.new("TextButton")
		button.LayoutOrder = order
		button.AutomaticSize = Enum.AutomaticSize.X
		button.Size = UDim2.new(0, 0, 1, 0)
		button.BackgroundColor3 = SURFACE
		button.TextColor3 = TEXT
		button.Font = Enum.Font.GothamMedium
		button.TextSize = 13
		button.Text = `  {name}  `
		button.Parent = header
		corner(button, 6)
		button.Activated:Connect(function()
			tab = name
			render()
		end)
		tabButtons[name] = button
	end

	local close = Instance.new("TextButton")
	close.LayoutOrder = #TABS + 1
	close.Size = UDim2.new(0, 28, 1, 0)
	close.BackgroundColor3 = SURFACE
	close.TextColor3 = TEXT
	close.Font = Enum.Font.GothamBold
	close.TextSize = 14
	close.Text = "X"
	close.Parent = header
	corner(close, 6)
	close.Activated:Connect(function()
		Overlay.close()
	end)

	picker = Instance.new("ScrollingFrame")
	picker.Name = "Players"
	picker.BackgroundTransparency = 1
	picker.BorderSizePixel = 0
	picker.Position = UDim2.new(0, 0, 0, 36)
	picker.Size = UDim2.new(1, 0, 0, 30)
	picker.AutomaticCanvasSize = Enum.AutomaticSize.X
	picker.CanvasSize = UDim2.new()
	picker.ScrollingDirection = Enum.ScrollingDirection.X
	picker.ScrollBarThickness = 3
	picker.Visible = false
	picker.Parent = panel

	local pickerRow = Instance.new("UIListLayout")
	pickerRow.FillDirection = Enum.FillDirection.Horizontal
	pickerRow.Padding = UDim.new(0, 6)
	pickerRow.SortOrder = Enum.SortOrder.LayoutOrder
	pickerRow.Parent = picker

	content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundColor3 = SURFACE
	content.BackgroundTransparency = 0.5
	content.BorderSizePixel = 0
	content.Position = UDim2.new(0, 0, 0, 36)
	content.Size = UDim2.new(1, 0, 1, -36)
	content.AutomaticCanvasSize = Enum.AutomaticSize.XY
	content.CanvasSize = UDim2.new()
	content.ScrollBarThickness = 6
	content.Parent = panel
	corner(content, 6)

	body = Instance.new("TextLabel")
	body.Name = "Text"
	body.BackgroundTransparency = 1
	body.AutomaticSize = Enum.AutomaticSize.XY
	body.Size = UDim2.new()
	body.Position = UDim2.new(0, 8, 0, 6)
	body.Font = Enum.Font.RobotoMono
	body.TextSize = 13
	body.TextColor3 = TEXT
	body.TextXAlignment = Enum.TextXAlignment.Left
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.RichText = true
	body.Text = ""
	body.Parent = content

	screen.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")
	return screen
end

--------------------------------------------------------------------------------
-- Opening and refreshing
--------------------------------------------------------------------------------

-- Fetches the server's view (and the selected player's) and redraws. Yields.
function Overlay.refresh()
	local src = source
	if not src or not isOpen then
		return
	end
	Stats.lease(LEASE_SECONDS)
	local ok, view = pcall(src.fetch, selected)
	if not isOpen then
		return
	end
	if not ok then
		serverNote = `server unavailable: {view}`
		lastView = nil
	elseif view == nil then
		serverNote = "not authorized for server data"
		lastView = nil
	else
		serverNote = nil
		lastView = view
	end
	render()
end

local function refreshLoop(mine: number)
	while generation == mine do
		Overlay.refresh()
		Clock.wait(if source then (source :: Source).refresh() else 1)
	end
end

-- Outside Studio the server decides: the panel opens only if it answers this player. Yields.
function Overlay.open()
	local src = source
	if isOpen or opening or not src then
		return
	end
	opening = true
	selected = selected or (Players.LocalPlayer :: Player).UserId
	if not RunService:IsStudio() then
		local ok, view = pcall(src.fetch, selected)
		if not ok or view == nil or source ~= src then
			opening = false
			return
		end
		lastView = view
	end
	opening = false

	isOpen = true
	generation += 1
	if not gui then
		gui = build()
	end
	(gui :: ScreenGui).Enabled = true
	render()
	task.spawn(refreshLoop, generation)
end

function Overlay.close()
	if not isOpen then
		return
	end
	isOpen = false
	generation += 1
	if gui then
		gui.Enabled = false
	end
end

function Overlay.toggle()
	if isOpen then
		Overlay.close()
	else
		Overlay.open()
	end
end

-- Listens for the key until the returned function is called, which also removes the panel.
function Overlay.bind(newSource: Source): () -> ()
	source = newSource
	local connection = game:GetService("UserInputService").InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == newSource.key then
			task.spawn(Overlay.toggle)
		end
	end)

	return function()
		connection:Disconnect()
		Overlay.close()
		if gui then
			gui:Destroy()
			gui = nil
		end
		table.clear(tabButtons)
		if source == newSource then
			source = nil
		end
		lastView = nil
	end
end

return Overlay
