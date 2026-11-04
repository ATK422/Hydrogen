--!strict

-- Hydrogen.Debug: network stats you can read anywhere, and a developer overlay on top of them.
-- Add it to the app on the server and the client; nothing runs until it is used.

local RunService = game:GetService("RunService")

local Stats = require("@self/Stats")
local Server = require("@self/Server")
local Overlay = require("@self/Overlay")
local Clock = require("./Clock")
local Definition = require("./Definition")
local Log = require("./Log")
local Network = require("./Network")
local Runtime = require("./Network/Runtime")
local Scope = require("./Scope")
local gt = require("../roblox_packages/gt")

export type NetStat = Stats.NetStat
export type Latency = Stats.Latency
export type Row = Server.Row
export type BootReport = Server.BootReport
export type BootSystem = Server.BootSystem
export type Warning = Server.Warning
export type View = Server.View
export type PlayerView = Server.PlayerView
export type Inspectable = Server.Inspectable

export type Options = {
	-- Client: the key that opens and closes the overlay. Default F3.
	key: Enum.KeyCode?,
	-- Server: UserIds allowed to see server data in live servers. Studio is always allowed.
	users: { number }?,
	-- Server: replaces the default check (Studio, the owner of a user-owned game, users).
	authorize: ((player: Player) -> boolean)?,
	-- Server: Data.player stores and PlayerStates to show in the overlay's Player tab.
	inspect: { Inspectable }?,
	-- Client: seconds between overlay refreshes while it is open. Default 1.
	refresh: number?,
}

-- Warnings kept for the overlay, per side.
local MAX_WARNINGS = 50
-- Server stats keep running this long after the last overlay request.
local LEASE_SECONDS = 10
local FETCH_NAME = "Hydrogen/Debug"

local settings = {
	key = nil :: Enum.KeyCode?,
	users = {} :: { number },
	authorize = nil :: ((Player) -> boolean)?,
	inspect = {} :: { Inspectable },
	refresh = 1,
}

local warnings: { Warning } = {}
local bootReport: BootReport? = nil
-- Created by the system's init on each side, so both register the same name before the network starts.
local fetchFunction: any = nil

local Debug = {}

local function onServer(): boolean
	return RunService:IsServer() or Network.activeLoopback() ~= nil
end

local function authorize(player: Player): boolean
	local custom = settings.authorize
	if custom then
		return custom(player)
	end
	return Server.defaultAuthorize(player, settings.users)
end

local function wire(): any
	if fetchFunction == nil then
		fetchFunction = Network.clientFunction(FETCH_NAME, gt.args(gt.optional(gt.number())), gt.returns(gt.optional(gt.any())))
		-- The overlay asks once a second; anything much faster is a client hammering the server.
		fetchFunction:UseRequest(Network.rateLimit({ perSecond = 4, burst = 8 }))
	end
	return fetchFunction
end

--------------------------------------------------------------------------------
-- Stats
--------------------------------------------------------------------------------

-- Starts collecting network stats on this side until disableStats().
Debug.enableStats = Stats.enable
Debug.disableStats = Stats.disable
-- Whether stats are being collected right now (enabled, or leased by an open overlay).
Debug.statsEnabled = Stats.enabled
-- Forgets what was counted; collection carries on.
Debug.resetStats = Stats.reset
-- This side's numbers per network object, by name. Empty until stats have run.
Debug.stats = Stats.snapshot
-- Estimated bytes for one message with these values, as the stats count them.
Debug.estimateBytes = Stats.estimate

--------------------------------------------------------------------------------
-- Configuration, boot timings, warnings
--------------------------------------------------------------------------------

function Debug.configure(options: Options)
	if type(options) ~= "table" then
		error(`[HYDROGEN] Debug.configure expects a table of options`, 2)
	end
	if options.key ~= nil then
		if typeof(options.key) ~= "EnumItem" then
			error(`[HYDROGEN] Debug.configure: key must be an Enum.KeyCode, e.g. Enum.KeyCode.F3`, 2)
		end
		settings.key = options.key
	end
	if options.users ~= nil then
		if type(options.users) ~= "table" then
			error(`[HYDROGEN] Debug.configure: users must be a list of UserIds`, 2)
		end
		for _, userId in options.users do
			if type(userId) ~= "number" then
				error(`[HYDROGEN] Debug.configure: users must be a list of UserIds (numbers), got {typeof(userId)}`, 2)
			end
		end
		settings.users = table.clone(options.users)
	end
	if options.authorize ~= nil then
		if type(options.authorize) ~= "function" then
			error(`[HYDROGEN] Debug.configure: authorize must be a function(player): boolean`, 2)
		end
		settings.authorize = options.authorize
	end
	if options.inspect ~= nil then
		for _, item in options.inspect do
			if type(item) ~= "table" or type((item :: any).find) ~= "function" then
				error(`[HYDROGEN] Debug.configure: inspect takes Data.player stores and PlayerStates (anything with find(player))`, 2)
			end
		end
		settings.inspect = table.clone(options.inspect)
	end
	if options.refresh ~= nil then
		if type(options.refresh) ~= "number" or options.refresh <= 0 then
			error(`[HYDROGEN] Debug.configure: refresh must be a positive number of seconds`, 2)
		end
		settings.refresh = options.refresh
	end
end

-- Server: whether this player may see server data. Runs your authorize, or the default check.
function Debug.isAuthorized(player: Player): boolean
	return Server.authorized(player, authorize)
end

local function parseBoot(message: string): BootReport?
	local total, network = string.match(message, "^%[HYDROGEN%] Booted %d+ systems in ([%d%.]+)ms %(network ([%d%.]+)ms%)")
	if not total then
		return nil
	end
	local systems = {}
	for name, init, start in string.gmatch(message, "\n  (.-): init ([%d%.]+)ms, start ([%d%.]+)ms") do
		table.insert(systems, { name = name, init = tonumber(init) :: number, start = tonumber(start) :: number })
	end
	return { total = tonumber(total) :: number, network = tonumber(network) :: number, systems = systems }
end

-- Pass as App.new's output: App.new({ debug = true, output = Hydrogen.Debug.bootOutput }).
-- Keeps the boot timings for the overlay and Debug.boot(), and still prints them.
function Debug.bootOutput(message: string)
	local report = parseBoot(message)
	if report then
		bootReport = report
	end
	print(message)
end

-- This side's last boot timings, if the app was made with output = Debug.bootOutput.
function Debug.boot(): BootReport?
	return bootReport
end

-- This side's recent [HYDROGEN] warnings, oldest first, while Hydrogen.Debug runs in the app.
function Debug.warnings(): { Warning }
	return table.clone(warnings)
end

--------------------------------------------------------------------------------
-- Server data and the overlay
--------------------------------------------------------------------------------

-- Client: asks the server for its view, and for one player's state and data if userId is
-- given. nil when this player isn't authorized. Yields.
function Debug.fetch(userId: number?): View?
	if fetchFunction == nil then
		error(`[HYDROGEN] Debug.fetch needs Hydrogen.Debug added to the app on the server and the client before app:start()`, 2)
	end
	return fetchFunction:Fire(userId)
end

-- Client: opens the overlay (after asking the server, outside Studio). Yields.
function Debug.open()
	Overlay.open()
end

function Debug.close()
	Overlay.close()
end

function Debug.toggle()
	Overlay.toggle()
end

local function answer(player: Player, userId: number?): View?
	if not Server.authorized(player, authorize) then
		return nil
	end
	Stats.lease(LEASE_SECONDS)
	return Server.view(userId, settings.inspect, warnings, bootReport)
end

local function remember(message: string): boolean?
	table.insert(warnings, { text = message, at = Clock.time() })
	if #warnings > MAX_WARNINGS then
		table.remove(warnings, 1)
	end
	return nil
end

--------------------------------------------------------------------------------
-- The system
--------------------------------------------------------------------------------

function Debug.init(self: any)
	local scope = Scope.of(self)
	scope:add(Log.capture(remember))

	if fetchFunction == nil and Runtime.Initialized then
		Log.warn(`[HYDROGEN] Hydrogen.Debug was added after the network started, so the overlay can't reach the server. Add it to the app on both sides before app:start()`)
		return
	end
	local fetch = wire()
	if onServer() then
		scope:add(fetch:On(answer))
	end
end

function Debug.start(self: any)
	if RunService:IsClient() and Network.activeLoopback() == nil then
		Scope.of(self):add(Overlay.bind({
			key = settings.key or Enum.KeyCode.F3,
			refresh = function()
				return settings.refresh
			end,
			fetch = Debug.fetch,
			warnings = Debug.warnings,
			boot = Debug.boot,
		}))
	end
end

-- For tests: stats off and forgotten, warnings and boot timings cleared. Settings stay.
function Debug._reset()
	Stats._reset()
	table.clear(warnings)
	bootReport = nil
end

-- For tests: settings back to their defaults.
function Debug._resetSettings()
	settings.key = nil
	settings.users = {}
	settings.authorize = nil
	settings.inspect = {}
	settings.refresh = 1
end

return Definition.define("Hydrogen.Debug", function()
	return Debug
end)
