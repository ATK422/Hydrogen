local Network = require("./Network")
local Definition = require("./Definition")

type System = Definition.Lifecycle

local App = {
	_systems = {} :: { System },
	_started = false,
}

local function collectSystems(folder: Folder): { System }
	local systems = {}

	for _, child in folder:GetDescendants() do
		if child:IsA("ModuleScript") then
			local system = require(child) :: System
			if system.id then
				table.insert(systems, system)
			else
				warn('Tried to collect "system" but it was not a valid system: ' .. tostring(child:GetFullName()))
			end
		end
	end

	return systems
end

function App.new(): typeof(App)
	local app = table.clone(App)
	app._systems = {}
	app._started = false
	return app
end

function App:addSystem(system: System)
	table.insert(self._systems, system)

	if self._started then
		if system.init then
			system:init()
		end
		if system.start then
			system:start()
		end
	end
end

function App:addSystems(systems: { System })
	for _, system in systems do
		self:addSystem(system)
	end
end

function App:addSystemsFolders(...: Folder)
	for _, folder in { ... } do
		local systems = collectSystems(folder)
		self:addSystems(systems)
	end
end

function App:addNetwork(folder: Folder)
	for _, child in folder:GetDescendants() do
		if child:IsA("ModuleScript") then
			local _ = require(child) :: any
		end
	end
end

function App:start()
	self._started = true

	local systems = Definition.order(self._systems)

	for _, system in systems do
		if system.init then
			system:init()
		end
	end

	-- Listeners register during init; the client then requests any queued events.
	Network.init()

	for _, system in systems do
		if system.start then
			system:start()
		end
	end
end

return App
