local Definition = require("./Definition")

type System<T> = Definition.Defined<T>

local App = {
	_systems = {} :: { System<any> },
	_started = false,
}

local function collectSystems(folder: Folder): { System<any> }
	local systems = {}

	for _, child in folder:GetDescendants() do
		if child:IsA("ModuleScript") then
			local system = require(child) :: System<any>
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

function App:addSystem(system: System<any>)
	table.insert(self._systems, system)

	if self._started then
		system.init()
		system.start()
	end
end

function App:addSystems(systems: { System<any> })
	for _, system in systems do
		self:addsystem(system)
	end
end

function App:addSystemsFolders(...: Folder)
	for _, folder in { ... } do
		local systems = collectSystems(folder)
		self:addsystems(systems)
	end
end

function App:start()
	self._started = true

	local systems = Definition.order(self._systems)

	for _, system in systems do
		if system.init then
			system.init()
		end
	end

	for _, system in systems do
		if system.start then
			system.start()
		end
	end
end

return App
