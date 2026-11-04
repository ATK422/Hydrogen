--!strict

-- Live sources: where remote config values come from. A source returns a table of
-- name -> value for the names it is asked for (values and flags share one namespace); the
-- config checks every value against its schema before using it.

local Log = require("../Log")

export type Source = {
	-- Shown in warnings.
	name: string,
	-- Returns the remote values for these names; a missing name means "not set remotely". May
	-- yield. An error keeps the last good values.
	fetch: (self: Source, names: { string }) -> { [string]: any }?,
	-- Optional push: calls onUpdate when new values are ready, so they apply before the next
	-- scheduled refresh. Returns a function that stops it.
	subscribe: ((self: Source, onUpdate: () -> ()) -> () -> ())?,
}

export type MemorySource = Source & {
	-- Sets one remote value (nil removes it). Seen on the next fetch.
	set: (self: MemorySource, name: string, value: any) -> (),
	-- Replaces every remote value.
	replace: (self: MemorySource, values: { [string]: any }) -> (),
	-- Every fetch errors with message until fail(nil).
	fail: (self: MemorySource, message: string?) -> (),
	-- Tells subscribers new values are ready, like ConfigService's UpdateAvailable.
	push: (self: MemorySource) -> (),
	-- How many times fetch ran.
	fetches: (self: MemorySource) -> number,
}

export type ExperienceConfigsOptions = {
	-- Stands in for ConfigService in tests: needs GetConfigAsync() returning a snapshot with
	-- GetValue(name), Refresh(), Outdated and UpdateAvailable.
	service: any?,
}

export type DataStoreLike = {
	GetAsync: (self: any, key: string) -> any,
}

export type DataStoreOptions = {
	-- The key that holds the table of values. Defaults to "config".
	key: string?,
	-- A MessagingService topic: any message on it makes every server fetch at once.
	topic: string?,
	-- Stand-ins for tests.
	store: DataStoreLike?,
	messaging: any?,
}

local Sources = {}

-- In memory, for tests and for values set from code at runtime.
function Sources.memory(initial: { [string]: any }?): MemorySource
	local values: { [string]: any } = table.clone(initial or {})
	local failure: string? = nil
	local count = 0
	local listeners: { () -> () } = {}

	local source = { name = "memory" } :: MemorySource

	function source:fetch(names: { string }): { [string]: any }?
		count += 1
		if failure then
			error(failure, 0)
		end
		local result = {}
		for name, value in values do
			result[name] = value
		end
		return result
	end

	function source:subscribe(onUpdate: () -> ()): () -> ()
		table.insert(listeners, onUpdate)
		return function()
			local index = table.find(listeners, onUpdate)
			if index then
				table.remove(listeners, index)
			end
		end
	end

	function source:set(name: string, value: any)
		values[name] = value
	end

	function source:replace(newValues: { [string]: any })
		values = table.clone(newValues)
	end

	function source:fail(message: string?)
		failure = message
	end

	function source:push()
		for _, listener in table.clone(listeners) do
			task.spawn(listener)
		end
	end

	function source:fetches(): number
		return count
	end

	return source
end

-- Roblox Experience Configs (ConfigService), edited in Studio under File > Open Configs or on
-- the Creator Hub and published without a deploy. Each config value or flag is the config key
-- of the same name. Server only. The snapshot pushes UpdateAvailable when a new version is
-- published, so changes apply within seconds; scheduled refreshes only read the local snapshot.
function Sources.experienceConfigs(options: ExperienceConfigsOptions?): Source
	local service = options and options.service
	local snapshot: any = nil
	local connection: any = nil
	local onUpdate: (() -> ())? = nil

	local function connect()
		if snapshot and onUpdate and not connection then
			local callback = onUpdate
			connection = snapshot.UpdateAvailable:Connect(function()
				callback()
			end)
		end
	end

	local source = { name = "ExperienceConfigs" } :: Source

	function source:fetch(names: { string }): { [string]: any }?
		if not snapshot then
			local configService = service or game:GetService("ConfigService")
			-- Errors only if configs never loaded on this server; after that it serves the last
			-- values it has while reconnecting.
			snapshot = configService:GetConfigAsync()
			connect()
		elseif snapshot.Outdated then
			snapshot:Refresh()
		end
		local result = {}
		for _, name in names do
			result[name] = snapshot:GetValue(name)
		end
		return result
	end

	function source:subscribe(callback: () -> ()): () -> ()
		onUpdate = callback
		connect()
		return function()
			onUpdate = nil
			if connection then
				connection:Disconnect()
				connection = nil
			end
		end
	end

	return source
end

-- One DataStore key holding a table of values, polled on the config's refresh interval (one
-- GetAsync per server per refresh). With a topic, publishing any message to it over
-- MessagingService makes every server fetch straight away. Server only.
function Sources.dataStore(name: string, options: DataStoreOptions?): Source
	if type(name) ~= "string" or name == "" then
		error(`[HYDROGEN] Config.dataStore needs a DataStore name`, 2)
	end
	local key = (options and options.key) or "config"
	local topic = options and options.topic
	local store: DataStoreLike? = options and options.store
	local messaging = options and options.messaging

	local source = { name = `DataStore {name}` } :: Source

	function source:fetch(_names: { string }): { [string]: any }?
		if not store then
			store = game:GetService("DataStoreService"):GetDataStore(name)
		end
		local value = (store :: DataStoreLike):GetAsync(key)
		if value ~= nil and type(value) ~= "table" then
			error(`key {key} holds a {typeof(value)}, not a table of values`, 0)
		end
		return value
	end

	if topic then
		function source:subscribe(onUpdate: () -> ()): () -> ()
			local service = messaging or game:GetService("MessagingService")
			local ok, connection = pcall(function()
				return service:SubscribeAsync(topic, function()
					onUpdate()
				end)
			end)
			if not ok then
				Log.warn(`[HYDROGEN] Config source DataStore {name} could not subscribe to topic {topic}: {connection}; values still refresh on schedule`)
				return function() end
			end
			return function()
				connection:Disconnect()
			end
		end
	end

	return source
end

return Sources
