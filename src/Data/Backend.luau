--!strict

local Tables = require("./Tables")

-- Which DataStore budget a request draws from.
export type RequestKind = "update" | "read" | "write"

-- Where Data keeps records. Roblox DataStores in a game, memory in tests and Studio without API access.
-- Every method may yield and may error; Data retries errors with backoff.
export type Backend = {
	-- Reads the key and replaces it with what transform returns, atomically. Returning nil from
	-- transform leaves the key unchanged. userIds tags the key for data-erasure requests.
	-- Returns the value now stored.
	update: (self: Backend, store: string, key: string, transform: (current: any) -> (any, { number }?)) -> any,
	-- Reads the latest value, bypassing any cache.
	read: (self: Backend, store: string, key: string) -> any,
	-- Writes the value, or removes the key when value is nil.
	write: (self: Backend, store: string, key: string, value: any) -> (),
	-- Requests of this kind that can be made right now without being throttled.
	budget: (self: Backend, kind: RequestKind) -> number,
}

-- The in-memory backend, with controls for tests.
export type MemoryBackend = Backend & {
	-- Seconds every request yields before it runs, to stand in for network latency.
	latency: number,
	-- Requests made so far, by kind.
	requests: { [RequestKind]: number },
	-- The next `count` requests (of `kind`, or any kind) error with `message`.
	fail: (self: MemoryBackend, count: number, kind: RequestKind?, message: string?) -> (),
	-- Limits the budget of a kind; each request uses one. nil makes it unlimited again.
	setBudget: (self: MemoryBackend, kind: RequestKind, amount: number?) -> (),
	-- A copy of what is stored under the key, as the next server to load it would see it.
	peek: (self: MemoryBackend, store: string, key: string) -> any,
}

local Backend = {}

local STUDIO_HINT = "In Studio, enable 'Studio Access to API Services' in Game Settings > Security,"
	.. " or call Hydrogen.Data.useBackend(Hydrogen.Data.memory()) to keep data in memory"

function Backend.memory(): MemoryBackend
	local stores: { [string]: { [string]: any } } = {}
	local budgets: { [RequestKind]: number } = {}
	local failures: { { kind: RequestKind?, message: string } } = {}

	local backend = {
		latency = 0,
		requests = { update = 0, read = 0, write = 0 },
	} :: MemoryBackend

	local function storeFor(name: string): { [string]: any }
		local store = stores[name]
		if not store then
			store = {}
			stores[name] = store
		end
		return store
	end

	-- Values are copied in and out, as a real store serializes them.
	local function request(kind: RequestKind)
		if backend.latency > 0 then
			task.wait(backend.latency)
		end

		backend.requests[kind] += 1
		local budget = budgets[kind]
		if budget then
			if budget <= 0 then
				error(`Memory backend: {kind} request throttled (budget exhausted)`, 0)
			end
			budgets[kind] = budget - 1
		end

		for index, failure in failures do
			if failure.kind == nil or failure.kind == kind then
				table.remove(failures, index)
				error(failure.message, 0)
			end
		end
	end

	function backend:update(store: string, key: string, transform: (any) -> (any, { number }?)): any
		request("update")
		local values = storeFor(store)
		local value = transform(Tables.copy(values[key]))
		if value == nil then
			return Tables.copy(values[key])
		end
		values[key] = Tables.copy(value)
		return Tables.copy(value)
	end

	function backend:read(store: string, key: string): any
		request("read")
		return Tables.copy(storeFor(store)[key])
	end

	function backend:write(store: string, key: string, value: any)
		request("write")
		storeFor(store)[key] = Tables.copy(value)
	end

	function backend:budget(kind: RequestKind): number
		return budgets[kind] or math.huge
	end

	function backend:fail(count: number, kind: RequestKind?, message: string?)
		for _ = 1, count do
			table.insert(failures, { kind = kind, message = message or "Memory backend: injected failure" })
		end
	end

	function backend:setBudget(kind: RequestKind, amount: number?)
		budgets[kind] = amount
	end

	function backend:peek(store: string, key: string): any
		return Tables.copy(storeFor(store)[key])
	end

	return backend
end

-- Roblox DataStores. Records go in GetDataStore(store); keys keep their UserIds and metadata.
function Backend.dataStores(service: DataStoreService?): Backend
	local dataStoreService = service or game:GetService("DataStoreService")
	local stores: { [string]: DataStore } = {}
	local hinted = false

	local function storeFor(name: string): DataStore
		local store = stores[name]
		if not store then
			store = dataStoreService:GetDataStore(name)
			stores[name] = store
		end
		return store
	end

	-- The first API-access error in Studio says how to fix it.
	local function call<T...>(fn: () -> T...): T...
		local results = table.pack(pcall(fn))
		if not results[1] then
			local message = tostring(results[2])
			if not hinted and (string.find(message, "Studio", 1, true) or string.find(message, "publish", 1, true)) then
				hinted = true
				message ..= `\n{STUDIO_HINT}`
			end
			error(message, 0)
		end
		return table.unpack(results, 2, results.n)
	end

	local backend = {} :: Backend

	function backend:update(store: string, key: string, transform: (any) -> (any, { number }?)): any
		return call(function()
			return storeFor(store):UpdateAsync(key, function(current: any, keyInfo: DataStoreKeyInfo?)
				local value, userIds = transform(current)
				if value == nil then
					return nil
				end
				-- Not passing them back would clear them.
				local keptIds = userIds or (keyInfo and keyInfo:GetUserIds())
				local metadata = keyInfo and keyInfo:GetMetadata()
				return value, keptIds, metadata
			end)
		end)
	end

	function backend:read(store: string, key: string): any
		return call(function()
			local options = Instance.new("DataStoreGetOptions")
			options.UseCache = false
			return (storeFor(store):GetAsync(key, options))
		end)
	end

	function backend:write(store: string, key: string, value: any)
		call(function()
			if value == nil then
				storeFor(store):RemoveAsync(key)
			else
				storeFor(store):SetAsync(key, value)
			end
		end)
	end

	function backend:budget(kind: RequestKind): number
		local requestType = if kind == "update"
			then Enum.DataStoreRequestType.UpdateAsync
			elseif kind == "read" then Enum.DataStoreRequestType.GetAsync
			else Enum.DataStoreRequestType.SetIncrementAsync
		return dataStoreService:GetRequestBudgetForRequestType(requestType)
	end

	return backend
end

return Backend
