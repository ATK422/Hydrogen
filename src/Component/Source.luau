--!strict

-- Where a component hears about tagged instances. In a game that is CollectionService and the
-- instances' own signals, so an idle component does no work at all. Under a fake clock (tests)
-- the same questions are answered by polling the DataModel at the end of every t:advance, which
-- also works under Lune, whose Instances have tags and attributes but no signals.

local Clock = require("../Clock")

export type Needs = {
	ancestry: boolean,
	children: boolean,
	attributes: boolean,
}

export type Source = {
	-- What "in the game" means: the DataModel.
	root: Instance,
	-- Tagged instances in the DataModel right now.
	tagged: (tag: string) -> { Instance },
	-- Calls changed(instance) whenever an instance may have gained or lost the tag, or entered
	-- or left the DataModel. The caller checks which. Returns a function that stops it.
	listen: (tag: string, changed: (instance: Instance) -> ()) -> () -> (),
	-- Calls changed() when what needs asks about may have changed. Returns a function that stops it.
	watch: (instance: Instance, needs: Needs, changed: () -> ()) -> () -> (),
	-- The Instance value the source handed out for this instance, so lookups by an Instance the
	-- caller got elsewhere find it. Identity in a game; under Lune each read makes a new userdata.
	key: (instance: Instance) -> Instance,
}

local Source = {}

local function collectionService(): any
	return game:GetService("CollectionService")
end

-- The DataModel. Under Lune, game is a table standing in for it, so go through a service.
local function dataModel(): Instance
	return (game:GetService("Workspace") :: Instance).Parent :: Instance
end

-- True in a game. Lune's CollectionService has no signals.
function Source.hasSignals(): boolean
	local ok = pcall(function()
		local service = collectionService()
		service:GetInstanceAddedSignal("Hydrogen.Component")
		service:GetTagged("Hydrogen.Component")
	end)
	return ok
end

local function disconnectAll(connections: { RBXScriptConnection }): () -> ()
	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		table.clear(connections)
	end
end

-- service is CollectionService unless a test passes a stand-in.
function Source.signals(service: any?): Source
	service = service or collectionService()

	local function listen(tag: string, changed: (Instance) -> ()): () -> ()
		return disconnectAll({
			service:GetInstanceAddedSignal(tag):Connect(changed),
			service:GetInstanceRemovedSignal(tag):Connect(changed),
		})
	end

	local function watch(instance: Instance, needs: Needs, changed: () -> ()): () -> ()
		local connections = {}
		if needs.ancestry then
			table.insert(connections, instance.AncestryChanged:Connect(changed))
		end
		if needs.children then
			table.insert(connections, instance.ChildAdded:Connect(changed))
			table.insert(connections, instance.ChildRemoved:Connect(changed))
		end
		if needs.attributes then
			table.insert(connections, instance.AttributeChanged:Connect(changed))
		end
		return disconnectAll(connections)
	end

	return {
		-- A real CollectionService is an Instance and errors on members it lacks, so only a test
		-- stand-in (a table) is asked for its own DataModel.
		root = if typeof(service) ~= "Instance" and service.root then service.root else game,
		tagged = function(tag: string): { Instance }
			return service:GetTagged(tag)
		end,
		listen = listen,
		watch = watch,
		key = function(instance: Instance): Instance
			return instance
		end,
	}
end

-- Polling ------------------------------------------------------------------------------------

type Poller = {
	-- Tag -> listeners.
	listeners: { [string]: { (Instance) -> () } },
	-- Tag -> instances seen tagged in the last poll.
	seen: { [string]: { Instance } },
	watchers: { () -> () },
	stopHeartbeat: (() -> ())?,
}

local poller: Poller = {
	listeners = {},
	seen = {},
	watchers = {},
	stopHeartbeat = nil,
}

local function tryHasTag(instance: Instance, tag: string): boolean
	local ok, has = pcall(instance.HasTag, instance, tag)
	return ok and has == true
end

-- Every instance in the DataModel with the tag. GetTagged in Studio; Lune doesn't have it.
local function scan(tag: string): { Instance }
	local ok, tagged = pcall(function()
		return collectionService():GetTagged(tag)
	end)
	if ok then
		return tagged
	end

	local found = {}
	for _, instance in dataModel():GetDescendants() do
		if tryHasTag(instance, tag) then
			table.insert(found, instance)
		end
	end
	return found
end

-- The value already handed out for instance, compared with ==, which Lune defines for Instances.
local function canonical(instance: Instance): Instance?
	for _, seen in poller.seen do
		for _, known in seen do
			if rawequal(known, instance) then
				return known
			end
		end
	end
	for _, seen in poller.seen do
		for _, known in seen do
			if known == instance then
				return known
			end
		end
	end
	return nil
end

local function poll()
	for tag, listeners in poller.listeners do
		local before = poller.seen[tag] or {}
		local now = {}
		for _, instance in scan(tag) do
			table.insert(now, canonical(instance) or instance)
		end
		poller.seen[tag] = now

		local changed = {}
		for _, instance in now do
			if not table.find(before, instance) then
				table.insert(changed, instance)
			end
		end
		for _, instance in before do
			if not table.find(now, instance) then
				table.insert(changed, instance)
			end
		end
		for _, instance in changed do
			for _, listener in table.clone(listeners) do
				listener(instance)
			end
		end
	end

	-- Ancestry, children and attributes: no signals to say when, so every watcher checks.
	for _, watcher in table.clone(poller.watchers) do
		if table.find(poller.watchers, watcher) then
			watcher()
		end
	end
end

local function remove<T>(list: { T }, value: T)
	local index = table.find(list, value)
	if index then
		table.remove(list, index)
	end
end

local function idle(): boolean
	return next(poller.listeners) == nil and #poller.watchers == 0
end

local function stopIfIdle()
	if idle() and poller.stopHeartbeat then
		poller.stopHeartbeat()
		poller.stopHeartbeat = nil
		table.clear(poller.seen)
	end
end

local function ensureHeartbeat()
	if poller.stopHeartbeat == nil then
		poller.stopHeartbeat = Clock.heartbeat(function()
			poll()
		end)
	end
end

function Source.polled(): Source
	local function listen(tag: string, changed: (Instance) -> ()): () -> ()
		local listeners = poller.listeners[tag]
		if listeners == nil then
			listeners = {}
			poller.listeners[tag] = listeners
			-- What is already there isn't a change; the caller binds it through tagged().
			local seen = {}
			for _, instance in scan(tag) do
				table.insert(seen, canonical(instance) or instance)
			end
			poller.seen[tag] = seen
		end
		table.insert(listeners, changed)
		ensureHeartbeat()

		return function()
			local current = poller.listeners[tag]
			if current then
				remove(current, changed)
				if #current == 0 then
					poller.listeners[tag] = nil
					poller.seen[tag] = nil
				end
			end
			stopIfIdle()
		end
	end

	local function watch(_instance: Instance, needs: Needs, changed: () -> ()): () -> ()
		if not (needs.ancestry or needs.children or needs.attributes) then
			return function() end
		end
		local watcher = function()
			changed()
		end
		table.insert(poller.watchers, watcher)
		ensureHeartbeat()
		return function()
			remove(poller.watchers, watcher)
			stopIfIdle()
		end
	end

	return {
		root = dataModel(),
		tagged = function(tag: string): { Instance }
			local seen = poller.seen[tag]
			if seen then
				return table.clone(seen)
			end
			local found = {}
			for _, instance in scan(tag) do
				table.insert(found, canonical(instance) or instance)
			end
			return found
		end,
		listen = listen,
		watch = watch,
		key = function(instance: Instance): Instance
			return canonical(instance) or instance
		end,
	}
end

return Source
