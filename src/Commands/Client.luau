--!strict

-- The client half of Commands: sends typed lines to the server, keeps the command list and the
-- output it sends back, and (in a real client) builds the console and the chat commands.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Definition = require("../Definition")
local Log = require("../Log")
local Network = require("../Network")
local Scope = require("../Scope")
local Complete = require("./Complete")
local Console = require("./Console")
local TextChat = require("./TextChat")
local Types = require("./Types")
local Wire = require("./Wire")

type CommandInfo = Types.CommandInfo
type OutputKind = Types.OutputKind
type OutputLine = Types.OutputLine
type ClientOptions = Types.ClientOptions
type Completion = Types.Completion

local MAX_LINES = 200

type View = {
	catalog: { CommandInfo },
	output: { OutputLine },
}

-- One view per client. A real client has one; under Hydrogen.test every fake client has its own.
local views: { [any]: View } = {}
local LOCAL = {}

local outputListeners: { (OutputKind, string) -> () } = {}
local catalogListeners: { ({ CommandInfo }) -> () } = {}
local options: ClientOptions = {}
local started = false

local console: Console.Console? = nil
local chat: TextChat.Binding? = nil

local function view(): View
	local key: any = LOCAL
	local loopback = Network.activeLoopback()
	if loopback then
		-- The client receiving or sending; with one fake client, that one.
		local players = loopback:players()
		key = loopback:client() or (if #players == 1 then players[1] else LOCAL)
	end
	local current = views[key]
	if not current then
		current = { catalog = {}, output = {} }
		views[key] = current
	end
	return current
end

local function notify<T...>(listeners: { (T...) -> () }, ...: T...)
	for _, listener in table.clone(listeners) do
		local ok, err = pcall(listener, ...)
		if not ok then
			Log.warn(`[HYDROGEN] Commands.Client listener failed: {err}`)
		end
	end
end

local function connect<T>(list: { T }, listener: T): () -> ()
	table.insert(list, listener)
	return function()
		local index = table.find(list, listener)
		if index then
			table.remove(list, index)
		end
	end
end

local function onOutput(kind: string, text: string)
	local line: OutputLine = { kind = if kind == "error" then "error" else "info", text = text }
	local output = view().output
	table.insert(output, line)
	if #output > MAX_LINES then
		table.remove(output, 1)
	end
	notify(outputListeners, line.kind, line.text)
end

local function onCatalog(catalog: { CommandInfo })
	view().catalog = catalog
	notify(catalogListeners, catalog)
end

local function playerNames(): { string }
	local names = {}
	local ok, list = pcall(function()
		return Players:GetPlayers()
	end)
	if ok then
		for _, player in list do
			table.insert(names, player.Name)
		end
	end
	return names
end

local Client = {}

-- Replaces the options. Call before the app starts (the console is built in start).
function Client.configure(newOptions: ClientOptions)
	if type(newOptions) ~= "table" then
		error(`[HYDROGEN] Commands.Client.configure expects an options table`, 2)
	end
	if started then
		error(`[HYDROGEN] Commands.Client.configure must be called before the app starts`, 2)
	end
	options = table.clone(newOptions)
end

-- Sends a line to the server to run, as if typed in the console. Output arrives through onOutput.
function Client.run(text: string)
	if type(text) ~= "string" then
		error(`[HYDROGEN] Commands.Client.run expects a line of text`, 2)
	end
	local wire = Wire.peek()
	if not wire then
		error(`[HYDROGEN] Commands.Client.run needs Hydrogen.Commands.Client added to the client app before app:start()`, 2)
	end
	if string.match(text, "^%s*/?%s*$") then
		return
	end
	wire.run:Fire(text)
end

-- The commands this player may run, as the server last sent them.
function Client.commands(): { CommandInfo }
	return view().catalog
end

-- The output received so far, oldest first (the last 200 lines).
function Client.output(): { OutputLine }
	return view().output
end

-- Calls listener(kind, text) for each line of output from the server. Returns a disconnect function.
function Client.onOutput(listener: (kind: OutputKind, text: string) -> ()): () -> ()
	return connect(outputListeners, listener)
end

-- Calls listener(commands) whenever the server sends a new command list.
function Client.onCommandsChanged(listener: (commands: { CommandInfo }) -> ()): () -> ()
	return connect(catalogListeners, listener)
end

-- Suggestions and the usage hint for a partly typed line.
function Client.complete(text: string): Completion
	return Complete.complete(text, view().catalog, playerNames())
end

function Client.open()
	if console then
		console:open()
	end
end

function Client.close()
	if console then
		console:close()
	end
end

function Client.toggle()
	if console then
		console:toggle()
	end
end

function Client.isOpen(): boolean
	return console ~= nil and console:isOpen()
end

-- A real client with a player and a GUI, not a test VM.
local function isRealClient(): boolean
	return RunService:IsClient() and Network.activeLoopback() == nil and Players.LocalPlayer ~= nil
end

return Definition.define("Hydrogen.Commands.Client", function()
	local System = Client :: any
	local disconnects: { () -> () } = {}

	function System:init()
		started = true
		table.clear(views)
		local wire = Wire.get()
		if not wire then
			Log.warn(`[HYDROGEN] Commands.Client was added after the network started, so this client can't send commands; add Hydrogen.Commands.Client to the app before app:start()`)
			return
		end
		table.insert(disconnects, wire.output:On(onOutput))
		table.insert(disconnects, wire.catalog:On(onCatalog))
	end

	function System:start()
		if not isRealClient() then
			return
		end
		local scope = Scope.of(self)
		local host = {
			run = Client.run,
			complete = Client.complete,
			commands = Client.commands,
		}

		if options.textChat ~= false then
			chat = TextChat.bind(Client.run)
			if chat then
				local binding = chat :: TextChat.Binding
				scope:add(binding)
				binding:update(Client.commands())
				scope:add(Client.onCommandsChanged(function(catalog)
					binding:update(catalog)
				end))
			end
		end

		if options.console ~= false then
			local built = Console.new(host, {
				keys = options.keys or { Enum.KeyCode.F2 },
				mobileButton = if options.mobileButton == nil then "auto" else options.mobileButton,
			})
			console = built
			scope:add(built)
			for _, line in Client.output() do
				built:push(line.kind, line.text)
			end
			built:setCommands(Client.commands())
			scope:add(Client.onCommandsChanged(function(catalog)
				built:setCommands(catalog)
			end))
		end

		scope:add(Client.onOutput(function(kind, text)
			if console then
				console:push(kind, text)
			end
			-- Output for a command typed in chat, or while the console is closed, shows in chat.
			if chat and options.chatOutput ~= false and not Client.isOpen() then
				chat:display(kind, text)
			end
		end))
		scope:add(function()
			console = nil
			chat = nil
		end)
	end

	function System:stop()
		started = false
		for _, disconnect in disconnects do
			disconnect()
		end
		table.clear(disconnects)
	end

	return Client
end)
