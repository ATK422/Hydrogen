--!strict

-- A tiny DataModel whose instances have the signals a game has, and a CollectionService that
-- fires for them, so the path components take in a game runs under Lune. With deferred on,
-- signals queue until flush(), like Roblox's deferred signal behavior.

export type FakeSignal = {
	Connect: (self: FakeSignal, fn: (...any) -> ()) -> { Disconnect: (any) -> () },
	Fire: (self: FakeSignal, ...any) -> (),
	count: (self: FakeSignal) -> number,
}

return function()
	local state = { deferred = false, queue = {} :: { () -> () } }

	local function signal(): FakeSignal
		local connections: { { fn: (...any) -> (), connected: boolean } } = {}
		local s = {} :: any
		function s:Connect(fn: (...any) -> ())
			local connection = { fn = fn, connected = true }
			table.insert(connections, connection)
			return {
				Disconnect = function()
					connection.connected = false
					local index = table.find(connections, connection)
					if index then
						table.remove(connections, index)
					end
				end,
			}
		end
		function s:Fire(...: any)
			local args = table.pack(...)
			for _, connection in table.clone(connections) do
				local run = function()
					if connection.connected then
						connection.fn(table.unpack(args, 1, args.n))
					end
				end
				if state.deferred then
					table.insert(state.queue, run)
				else
					run()
				end
			end
		end
		function s:count(): number
			return #connections
		end
		return s
	end

	local tagSignals: { [string]: { added: FakeSignal, removed: FakeSignal } } = {}
	local function signalsFor(tag: string)
		local signals = tagSignals[tag]
		if signals == nil then
			signals = { added = signal(), removed = signal() }
			tagSignals[tag] = signals
		end
		return signals
	end

	local Methods = {}
	local metatable = { __index = Methods }
	local root: any

	local function new(className: string, name: string?): any
		return setmetatable({
			ClassName = className,
			Name = name or className,
			Parent = nil,
			children = {},
			tags = {},
			attributes = {},
			AncestryChanged = signal(),
			ChildAdded = signal(),
			ChildRemoved = signal(),
			AttributeChanged = signal(),
		}, metatable)
	end

	local function descendants(instance: any, into: { any }): { any }
		table.insert(into, instance)
		for _, child in instance.children do
			descendants(child, into)
		end
		return into
	end

	function Methods.IsDescendantOf(self: any, ancestor: any): boolean
		local current = self.Parent
		while current do
			if current == ancestor then
				return true
			end
			current = current.Parent
		end
		return false
	end

	function Methods.GetFullName(self: any): string
		if self.Parent == nil or self.Parent == root then
			return self.Name
		end
		return `{self.Parent:GetFullName()}.{self.Name}`
	end

	function Methods.FindFirstChild(self: any, name: string): any
		for _, child in self.children do
			if child.Name == name then
				return child
			end
		end
		return nil
	end

	function Methods.IsA(self: any, className: string): boolean
		return className == "Instance"
			or className == self.ClassName
			or (className == "BasePart" and self.ClassName == "Part")
	end

	function Methods.HasTag(self: any, tag: string): boolean
		return self.tags[tag] == true
	end

	function Methods.AddTag(self: any, tag: string)
		if self.tags[tag] then
			return
		end
		self.tags[tag] = true
		if self:IsDescendantOf(root) then
			signalsFor(tag).added:Fire(self)
		end
	end

	function Methods.RemoveTag(self: any, tag: string)
		if not self.tags[tag] then
			return
		end
		self.tags[tag] = nil
		if self:IsDescendantOf(root) then
			signalsFor(tag).removed:Fire(self)
		end
	end

	function Methods.GetAttributes(self: any): { [string]: any }
		return table.clone(self.attributes)
	end

	function Methods.SetAttribute(self: any, name: string, value: any)
		self.attributes[name] = value
		self.AttributeChanged:Fire(name)
	end

	-- Instance.Parent = parent, with the signals Roblox fires for it.
	function Methods.setParent(self: any, parent: any)
		local moving = descendants(self, {})
		local wasIn = {}
		for index, instance in moving do
			wasIn[index] = instance:IsDescendantOf(root)
		end

		local old = self.Parent
		if old then
			table.remove(old.children, table.find(old.children, self) :: number)
		end
		self.Parent = parent
		if parent then
			table.insert(parent.children, self)
		end
		if old then
			old.ChildRemoved:Fire(self)
		end
		if parent then
			parent.ChildAdded:Fire(self)
		end

		for index, instance in moving do
			instance.AncestryChanged:Fire(self, parent)
			local isIn = instance:IsDescendantOf(root)
			if isIn ~= wasIn[index] then
				for tag in instance.tags do
					local signals = signalsFor(tag)
					if isIn then
						signals.added:Fire(instance)
					else
						signals.removed:Fire(instance)
					end
				end
			end
		end
	end

	function Methods.Destroy(self: any)
		self:setParent(nil)
	end

	root = new("DataModel", "game")
	local workspace = new("Workspace")
	workspace:setParent(root)
	local storage = new("ReplicatedStorage")
	storage:setParent(root)

	local service = {
		-- Read by Component in place of game.
		root = root,
		GetInstanceAddedSignal = function(_: any, tag: string): FakeSignal
			return signalsFor(tag).added
		end,
		GetInstanceRemovedSignal = function(_: any, tag: string): FakeSignal
			return signalsFor(tag).removed
		end,
		GetTagged = function(_: any, tag: string): { any }
			local found = {}
			for _, instance in descendants(root, {}) do
				if instance.tags[tag] then
					table.insert(found, instance)
				end
			end
			return found
		end,
	}

	return {
		service = service,
		workspace = workspace,
		storage = storage,
		new = function(className: string, name: string?, tag: string?, parent: any?): any
			local instance = new(className, name)
			if tag then
				instance:AddTag(tag)
			end
			if parent then
				instance:setParent(parent)
			end
			return instance
		end,
		-- Runs queued signals, including ones they queue, like the end of a Roblox frame.
		flush = function()
			while #state.queue > 0 do
				local queue = state.queue
				state.queue = {}
				for _, run in queue do
					run()
				end
			end
		end,
		setDeferred = function(deferred: boolean)
			state.deferred = deferred
		end,
		-- Connections to the tag's added and removed signals.
		listeners = function(tag: string): number
			local signals = signalsFor(tag)
			return signals.added:count() + signals.removed:count()
		end,
	}
end
