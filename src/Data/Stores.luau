--!strict

-- Session-locked DataStore persistence. Data.player loads each player in playerAdded and
-- saves in playerRemoving, so systems that use it see loaded data in their own playerAdded.

local RunService = game:GetService("RunService")

local Backend = require("./Backend")
local Clock = require("./Clock")
local Store = require("./Store")
local Definition = require("../Definition")
local Network = require("../Network")

export type Backend = Backend.Backend
export type MemoryBackend = Backend.MemoryBackend
export type RequestKind = Backend.RequestKind
export type Migration = Store.Migration
export type UpdateOnceResult = Store.UpdateOnceResult

export type StoreOptions<T> = {
	-- Data for a key that was never saved. Missing fields of saved data are filled from it.
	template: T,
	-- A GreenTea schema, e.g. gt.table({ coins = gt.number() }). Derived from the template if omitted.
	schema: T?,
	-- Run in order on data saved before they existed. A migration is a function from old to new
	-- data, or { migrate = fn, backwardsCompatible = true } when servers without it can still read the result.
	migrations: { Migration }?,
	-- Where records go. Defaults to Hydrogen.Data.useBackend's, else DataStores on a server and memory otherwise.
	backend: Backend?,
	-- Seconds between autosaves of changed data. Default 120.
	autosave: number?,
	-- Seconds after which another server's lock counts as abandoned. Default 600.
	lockTimeout: number?,
	-- Seconds a load waits for another server to release its lock. Default 30.
	loadTimeout: number?,
	-- Attempts per DataStore request before giving up. Default 5.
	retries: number?,
}

export type PlayerOptions<T> = {
	-- Data for a key that was never saved. Missing fields of saved data are filled from it.
	template: T,
	-- A GreenTea schema, e.g. gt.table({ coins = gt.number() }). Derived from the template if omitted.
	schema: T?,
	-- Run in order on data saved before they existed. A migration is a function from old to new
	-- data, or { migrate = fn, backwardsCompatible = true } when servers without it can still read the result.
	migrations: { Migration }?,
	-- Where records go. Defaults to Hydrogen.Data.useBackend's, else DataStores on a server and memory otherwise.
	backend: Backend?,
	-- Seconds between autosaves of changed data. Default 120.
	autosave: number?,
	-- Seconds after which another server's lock counts as abandoned. Default 600.
	lockTimeout: number?,
	-- Seconds a load waits for another server to release its lock. Default 30.
	loadTimeout: number?,
	-- Attempts per DataStore request before giving up. Default 5.
	retries: number?,
	-- The record key for a UserId. Defaults to tostring(userId).
	key: ((userId: number) -> string)?,
	-- Called when a player's data can't be loaded. Defaults to kicking them with a message.
	-- Until they're gone, get returns the template and nothing is saved.
	onLoadFailed: ((player: Player, message: string) -> ())?,
}

-- Methods shared by player and key stores. K is a Player or a string key.
type Methods<K, T> = {
	read name: string,
	-- The loaded data, deep-frozen: change it with update. Errors if the key isn't loaded.
	get: (self: any, key: K) -> T,
	-- Like get, but nil when the key isn't loaded.
	find: (self: any, key: K) -> T?,
	-- Whether the key loaded successfully and is still held.
	isLoaded: (self: any, key: K) -> boolean,
	-- Waits for the key's load to finish and returns whether it loaded. For a player whose load
	-- hasn't started, waits while they're in the game. Yields.
	waitForLoad: (self: any, key: K, timeout: number?) -> boolean,
	-- Runs fn on a copy of the data; return false to abort. The result is checked against the
	-- schema and committed in one step. Returns whether it committed. fn must not yield.
	-- Called inside another update's fn for the same key, it changes that copy instead.
	update: (self: any, key: K, fn: (data: T) -> ...any) -> boolean,
	-- Like update, but runs once per id, and returns after a save holding both the change and
	-- the id succeeded. "applied" or "duplicate" mean the change is stored. Yields.
	updateOnce: (self: any, key: K, id: string, fn: (data: T) -> ...any) -> UpdateOnceResult,
	-- Changes several keys all-or-nothing, e.g. a trade. Saved with a two-phase commit.
	transaction: (self: any, keys: { K }, fn: (data: { [K]: T }) -> ...any) -> boolean,
	-- Saves now and waits. Returns whether the data as of this call is stored.
	save: (self: any, key: K) -> (boolean, string?),
	-- Calls fn after every committed change.
	changed: (self: any, fn: (key: K, data: T, old: T) -> ()) -> () -> (),
}

export type PlayerStore<T> = Methods<Player, T> & {
	-- Reads a player's saved data without locking it, e.g. for an offline profile. nil if never saved. Yields.
	view: (self: any, userId: number) -> T?,
}

export type KeyStore<T> = Methods<string, T> & {
	-- Loads and session-locks a key. Waits up to loadTimeout for another server's lock. Yields.
	load: (self: any, key: string) -> (boolean, string?),
	-- Saves, releases the lock and forgets the key. Yields.
	unload: (self: any, key: string) -> (),
	-- Reads a key without locking it. nil if never saved. Yields.
	view: (self: any, key: string) -> T?,
}

local Data = {}

local chosenBackend: Backend? = nil
local dataStores: Backend? = nil
local memory: MemoryBackend? = nil

local function resolveBackend(explicit: Backend?): Backend
	if explicit then
		return explicit
	elseif chosenBackend then
		return chosenBackend
	elseif RunService:IsServer() and not Network.activeLoopback() then
		dataStores = dataStores or Backend.dataStores()
		return dataStores :: Backend
	end
	memory = memory or Backend.memory()
	return memory :: MemoryBackend
end

-- Clients never touch DataStores; their copy of a store does nothing.
local function onServer(): boolean
	return not RunService:IsClient()
end

local function bindToClose(store: Store.Store)
	if RunService:IsServer() and not Network.activeLoopback() then
		game:BindToClose(function()
			store:markClosing()
		end)
	end
end

local function config(name: string, options: StoreOptions<any>, keyOf: (any) -> string): Store.Config
	return {
		name = name,
		template = options.template,
		schema = options.schema,
		migrations = options.migrations,
		backend = function()
			return resolveBackend(options.backend)
		end,
		autosave = options.autosave,
		lockTimeout = options.lockTimeout,
		loadTimeout = options.loadTimeout,
		retries = options.retries,
		keyOf = keyOf,
	}
end

local function kick(player: Player, message: string)
	warn(`[HYDROGEN] {message}`)
	pcall(function()
		player:Kick("Your data couldn't be loaded. Please rejoin in a moment.")
	end)
end

--[=[
	A store with one record per player, as a system. Add it to the app; systems that `use` it get
	the player's data in their own playerAdded:

	local PlayerData = Hydrogen.Data.player("PlayerData", { template = { coins = 0 } })
]=]
function Data.player<T>(name: string, options: PlayerOptions<T>): Definition.Defined<PlayerStore<T>>
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] Data.player needs a store name`, 2)
	end

	local keyFor = options.key or tostring
	local function keyOf(key: any): string
		if type(key) == "number" then
			return keyFor(key)
		elseif type(key) == "string" then
			return key
		end
		return keyFor(key.UserId)
	end

	local storeConfig = config(name, options :: any, keyOf)
	storeConfig.userIdsOf = function(player: any): { number }?
		local userId = player.UserId
		return if type(userId) == "number" and userId > 0 then { userId } else nil
	end
	storeConfig.onLost = function(player: any)
		pcall(function()
			player:Kick("Your data was opened on another server.")
		end)
	end

	local store = Store.new(storeConfig) :: any
	local onLoadFailed = options.onLoadFailed or kick

	return Definition.define(name, function()
		store.init = function(self)
			store:reopen()
		end

		store.start = function(self)
			if onServer() then
				bindToClose(store)
			end
		end

		store.playerAdded = function(self, player: Player)
			if not onServer() then
				return
			end
			local ok, err = store:load(player, function()
				return player.Parent == nil
			end)
			if not ok then
				store:placeholder(player)
				if player.Parent ~= nil then
					onLoadFailed(player, `{name} couldn't load {player.Name}: {err}`)
				end
			end
		end

		store.playerRemoving = function(self, player: Player)
			if onServer() then
				store:unload(player)
			end
		end

		store.stop = function(self)
			if onServer() then
				store:close()
			end
		end

		return store
	end) :: any
end

--[=[
	A store of arbitrary keys (guilds, a global leaderboard, server config), as a system. Load a
	key before using it; everything still loaded is saved and released when the app stops.
]=]
function Data.store<T>(name: string, options: StoreOptions<T>): Definition.Defined<KeyStore<T>>
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] Data.store needs a store name`, 2)
	end

	local store = Store.new(config(name, options, function(key: any): string
		if type(key) ~= "string" then
			error(`[HYDROGEN] {name} keys are strings, got {typeof(key)}`, 4)
		end
		return key
	end)) :: any

	return Definition.define(name, function()
		store.init = function(self)
			store:reopen()
		end

		store.start = function(self)
			if onServer() then
				bindToClose(store)
			end
		end

		store.stop = function(self)
			if onServer() then
				store:close()
			end
		end

		return store
	end) :: any
end

-- An in-memory backend: for tests, Lune, and Studio without API access.
Data.memory = Backend.memory

-- The Roblox DataStore backend, optionally over another DataStoreService-shaped object.
Data.dataStores = Backend.dataStores

-- Sets the backend every store without its own `backend` option uses. nil goes back to the default.
function Data.useBackend(backend: Backend?)
	chosenBackend = backend
end

-- Time sources, swappable by tests and fake clocks.
Data.Clock = Clock

return Data
