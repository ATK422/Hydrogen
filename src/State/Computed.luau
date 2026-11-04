--!strict

-- State derived from other state. Nothing is replicated: each side computes it from its own copy,
-- so a client's computed state follows its replicas. Dependencies are the states the function read,
-- including through other computed state, which reads them on its behalf.

local Store = require("./Store")

export type Computed<T> = {
	-- The current value, computed now.
	get: (self: Computed<T>) -> T,
	-- Calls observer with the value now and again whenever it changes. Returns a disconnect function.
	observe: (self: Computed<T>, observer: (value: T, previous: T?) -> ()) -> () -> (),
}

type Inner = {
	compute: () -> any,
	-- Per context, since under loopback the server and each fake client have their own values.
	observers: { [any]: { (...any) -> () } },
	last: { [any]: any },
	-- Sources watched while observed; dropped when the last observer disconnects.
	deps: { [Store.Source]: boolean },
	watch: (ctx: any) -> (),
	reset: (self: Inner) -> (),
}

local NAME = "(computed)"

local Computed = {}

local function unwatchAll(self: Inner)
	for dep in self.deps do
		dep.watchers[self.watch] = nil
	end
	table.clear(self.deps)
end

-- Runs the function and, while anything observes this, watches every source it read.
local function evaluate(self: Inner): any
	local deps, value = Store.collect(self.compute)
	if next(self.observers) ~= nil then
		for dep in deps do
			if not self.deps[dep] then
				self.deps[dep] = true
				dep.watchers[self.watch] = true
			end
		end
	end
	return value
end

local function recompute(self: Inner, ctx: any)
	local observers = self.observers[ctx]
	if not observers then
		return
	end

	local ok, value = pcall(evaluate, self)
	if not ok then
		warn(`[HYDROGEN] Computed state failed: {value}`)
		return
	end

	local previous = self.last[ctx]
	if value == previous and type(value) ~= "table" then
		return
	end
	self.last[ctx] = value
	Store.notify(NAME, observers, value, previous)
end

function Computed.new<T>(compute: () -> T): Computed<T>
	if type(compute) ~= "function" then
		error(`[HYDROGEN] State.computed expects a function`, 3)
	end

	local self = {
		compute = compute,
		observers = {},
		last = {},
		deps = {},
	} :: Inner

	self.watch = function(ctx: any)
		Store.within(ctx, recompute, self, ctx)
	end

	function self.reset(inner: Inner)
		unwatchAll(inner)
		table.clear(inner.observers)
		table.clear(inner.last)
	end

	local computed = {}

	-- Not cached: computing it reads the states it depends on, so a computed state that reads this
	-- one depends on them directly.
	function computed.get(_: any): T
		return compute()
	end

	function computed.observe(_: any, observer: (value: T, previous: T?) -> ()): () -> ()
		local ctx = Store.context()
		local observers = self.observers[ctx] or {}
		self.observers[ctx] = observers
		table.insert(observers, observer :: any)

		local value = evaluate(self)
		self.last[ctx] = value
		Store.within(ctx, Store.call, NAME, observer :: any, value, nil)

		return function()
			local index = table.find(observers, observer :: any)
			if not index then
				return
			end
			table.remove(observers, index)
			if #observers == 0 and self.observers[ctx] == observers then
				self.observers[ctx] = nil
				self.last[ctx] = nil
				if next(self.observers) == nil then
					unwatchAll(self)
				end
			end
		end
	end

	table.insert(Store.computeds, self :: any)
	return computed :: any
end

return Computed
