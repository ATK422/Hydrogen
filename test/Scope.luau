--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")

local Scope = Hydrogen.Scope
local gt = Hydrogen.gt

-- A signal like GoodSignal's: Connect returns an object with Disconnect.
local function fakeSignal()
	local signal = { listeners = {} :: { [any]: (...any) -> () } }

	function signal:Connect(callback: (...any) -> ())
		local connection = {}
		self.listeners[connection] = callback
		function connection.Disconnect()
			self.listeners[connection] = nil
		end
		return connection
	end

	function signal:count(): number
		local count = 0
		for _ in self.listeners do
			count += 1
		end
		return count
	end

	return signal
end

local function trackedCount(scope: any): number
	local count = 0
	for _ in scope._tasks or {} do
		count += 1
	end
	return count
end

return function()
	-- Apps and loopbacks a test opened, so a failing test can't leak into the next one.
	local apps: { Hydrogen.App } = {}
	local loopbacks: { Hydrogen.Loopback } = {}

	-- Every app gets a loopback, so each test starts the network fresh.
	local function newApp(): (Hydrogen.App, Hydrogen.Loopback)
		local loopback = Hydrogen.loopback()
		table.insert(loopbacks, loopback)
		local app = Hydrogen.App.new()
		table.insert(apps, app)
		return app, loopback
	end

	test.on_test_leave(function()
		for _, app in apps do
			app:stop()
		end
		for _, loopback in loopbacks do
			loopback:close()
		end
		table.clear(apps)
		table.clear(loopbacks)
	end)

	test.suite("Scope", function()
		test.case("destroy cleans every kind of task, newest first", function()
			local events = {}
			local scope = Scope.new()

			scope:add(function()
				table.insert(events, "function")
			end)
			scope:add({
				Destroy = function()
					table.insert(events, "Destroy")
				end,
			})
			scope:add({
				Disconnect = function()
					table.insert(events, "Disconnect")
				end,
			})
			scope:add({
				destroy = function()
					table.insert(events, "destroy")
				end,
			})
			-- Shaped like a promise.
			scope:add({
				cancel = function()
					table.insert(events, "cancel")
				end,
			})
			local child = scope:child()
			child:add(function()
				table.insert(events, "child")
			end)

			scope:destroy()

			check.equal(scope.alive, false)
			check.equal(child.alive, false)
			check.equal(#events, 6)
			check.equal(events[1], "child")
			check.equal(events[2], "cancel")
			check.equal(events[3], "destroy")
			check.equal(events[4], "Disconnect")
			check.equal(events[5], "Destroy")
			check.equal(events[6], "function")
			return nil
		end)

		test.case("add returns the task and Instances are destroyed", function()
			local folder = Instance.new("Folder")
			local scope = Scope.new()
			local part = scope:add(Instance.new("Part"))
			part.Parent = folder

			check.equal(#folder:GetChildren(), 1)
			scope:destroy()
			check.equal(#folder:GetChildren(), 0)
			return nil
		end)

		test.case("connect tracks the connection", function()
			local signal = fakeSignal()
			local scope = Scope.new()
			scope:connect(signal :: any, function() end)

			check.equal(signal:count(), 1)
			scope:destroy()
			check.equal(signal:count(), 0)
			return nil
		end)

		test.case("connect points network objects at add", function()
			local scope = Scope.new()
			local ok, err = pcall(function()
				scope:connect({ On = function() end } :: any, function() end)
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "scope:add(object:On(callback))", 1, true))
			return nil
		end)

		test.case("a failing cleanup task doesn't stop the others", function()
			local cleaned = {}
			local scope = Scope.new("Round")
			scope:add(function()
				table.insert(cleaned, "first")
			end)
			scope:add(function()
				error("boom")
			end)
			scope:add(function()
				table.insert(cleaned, "last")
			end)

			check.should_not_error(function()
				scope:destroy()
				return nil
			end)
			check.equal(#cleaned, 2)
			check.equal(cleaned[1], "last")
			check.equal(cleaned[2], "first")
			return nil
		end)

		test.case("a yielding cleanup task delays the next one", function()
			local events = {}
			local scope = Scope.new()
			scope:add(function()
				table.insert(events, "second")
			end)
			scope:add(function()
				task.wait()
				table.insert(events, "first")
			end)

			scope:destroy()
			check.equal(events[1], "first")
			check.equal(events[2], "second")
			return nil
		end)

		test.case("adding to a destroyed scope cleans the task right away", function()
			local scope = Scope.new()
			scope:destroy()
			scope:destroy()

			local cleaned = false
			scope:add(function()
				cleaned = true
			end)
			check.equal(cleaned, true)

			local ran = false
			scope:spawn(function()
				ran = true
			end)
			check.equal(ran, false)

			local child = scope:child()
			check.equal(child.alive, false)
			return nil
		end)

		test.case("adding something that can't be cleaned errors", function()
			local scope = Scope.new()
			check.should_error(function()
				scope:add(5 :: any)
				return nil
			end)
			check.should_error(function()
				scope:add({ value = 1 } :: any)
				return nil
			end)
			check.should_error(function()
				scope:add(scope)
				return nil
			end)
			return nil
		end)

		test.case("a child destroyed early is no longer held by its parent", function()
			local parent = Scope.new()
			local count = 0
			local child = parent:child()
			child:add(function()
				count += 1
			end)

			check.equal(trackedCount(parent), 1)
			child:destroy()
			check.equal(count, 1)
			check.equal(trackedCount(parent), 0)

			parent:destroy()
			check.equal(count, 1)
			return nil
		end)

		test.case("remove cleans one task and stops tracking it", function()
			local scope = Scope.new()
			local count = 0
			local function cleanup()
				count += 1
			end
			scope:add(cleanup)
			scope:add(cleanup)

			scope:remove(cleanup)
			check.equal(count, 1)
			scope:remove(cleanup)
			scope:destroy()
			check.equal(count, 1)
			return nil
		end)

		test.case("spawned threads are cancelled, and forgotten once they finish", function()
			local scope = Scope.new()
			local finished = false
			scope:spawn(function()
				finished = true
			end)
			check.equal(finished, true)
			check.equal(trackedCount(scope), 0)

			local resumed = false
			scope:spawn(function()
				task.wait()
				resumed = true
			end)
			check.equal(trackedCount(scope), 1)
			scope:destroy()
			task.wait()
			task.wait()
			check.equal(resumed, false)
			return nil
		end)

		test.case("delayed callbacks are cancelled, and forgotten once they run", function()
			local scope = Scope.new()
			local fired = 0
			scope:delay(0, function(amount: number)
				fired += amount
			end, 2)
			check.equal(trackedCount(scope), 1)
			task.wait(0.05)
			check.equal(fired, 2)
			check.equal(trackedCount(scope), 0)

			scope:delay(0, function()
				fired += 10
			end)
			scope:destroy()
			task.wait(0.05)
			check.equal(fired, 2)
			return nil
		end)

		test.case("a spawned thread can destroy its own scope", function()
			local scope = Scope.new()
			local after = false
			local cleaned = false
			scope:add(function()
				cleaned = true
			end)
			scope:spawn(function()
				task.wait()
				scope:destroy()
				after = true
			end)

			task.wait()
			task.wait()
			check.equal(cleaned, true)
			check.equal(after, true)
			return nil
		end)

		test.case("Scope.of returns the same scopes from every hook, and only when asked", function()
			local seen = {}
			local Combat = Hydrogen.define("Combat", function()
				local Combat = {}

				function Combat:init(...)
					seen.initArgs = select("#", ...)
					seen.init = Scope.of(self)
				end

				function Combat:start()
					seen.start = Scope.of(self)
				end

				function Combat:playerAdded(player: Player, ...)
					seen.addedArgs = select("#", ...)
					seen.added = Scope.of(self, player)
				end

				function Combat:playerRemoving(player: Player)
					seen.removing = Scope.of(self, player)
					seen.aliveInRemoving = seen.removing.alive
				end

				return Combat
			end)

			local Plain = Hydrogen.define("Plain", function()
				return {
					start = function() end,
					playerAdded = function(_, _player) end,
				}
			end)

			local app = newApp()
			app:addSystems({ Combat, Plain })
			app:start()

			local player = { Name = "P" } :: any
			app:_addPlayer(player)

			-- Hooks are called exactly as before: no extra arguments.
			check.equal(seen.initArgs, 0)
			check.equal(seen.addedArgs, 0)
			check.equal(seen.init, seen.start)
			check.equal(seen.init, Scope.of(Combat))
			check.equal(seen.added, Scope.of(Combat, player))
			check.equal(seen.init.alive, true)
			check.equal(seen.added.alive, true)
			check.equal(seen.added.name, "Combat for P")

			-- Plain never asked, so nothing was created for it.
			check.equal((app :: any)._scopes[Plain], nil)
			check.equal((app :: any)._players[player].scopes[Plain], nil)

			app:_removePlayer(player)
			check.equal(seen.removing, seen.added)
			check.equal(seen.aliveInRemoving, true)
			check.equal(seen.added.alive, false)
			check.equal(seen.init.alive, true)

			app:stop()
			check.equal(seen.init.alive, false)
			return nil
		end)

		test.case("player scopes close in reverse dependency order, after each playerRemoving", function()
			local events = {}

			local Data = Hydrogen.define("Data", function()
				local Data = {}
				function Data:playerAdded(player: Player)
					Scope.of(self, player):add(function()
						table.insert(events, "Data scope")
					end)
				end
				function Data:playerRemoving(player: Player)
					table.insert(events, "Data playerRemoving")
				end
				return Data
			end)

			local Shop = Hydrogen.define("Shop", function(use)
				use(Data)
				local Shop = {}
				function Shop:playerAdded(player: Player)
					Scope.of(self, player):add(function()
						table.insert(events, "Shop scope")
					end)
				end
				function Shop:playerRemoving(player: Player)
					table.insert(events, "Shop playerRemoving")
					-- Shop's playerRemoving runs before Data's, so Data's scope is still open.
					table.insert(events, if Scope.of(Data, player).alive then "Data open" else "Data closed")
				end
				return Shop
			end)

			local app = newApp()
			app:addSystems({ Shop, Data })
			app:start()

			local player = { Name = "P" } :: any
			app:_addPlayer(player)
			app:_removePlayer(player)

			check.equal(#events, 5)
			check.equal(events[1], "Shop playerRemoving")
			check.equal(events[2], "Data open")
			check.equal(events[3], "Shop scope")
			check.equal(events[4], "Data playerRemoving")
			check.equal(events[5], "Data scope")
			return nil
		end)

		test.case("system scopes close after each stop hook, in reverse dependency order", function()
			local events = {}

			local Data = Hydrogen.define("Data", function()
				local Data = {}
				function Data:start()
					Scope.of(self):add(function()
						table.insert(events, "Data scope")
					end)
				end
				function Data:stop()
					table.insert(events, "Data stop")
				end
				return Data
			end)

			local Shop = Hydrogen.define("Shop", function(use)
				use(Data)
				local Shop = {}
				function Shop:start()
					-- Any system's scope can be reached through its table, not only self.
					Scope.of(Shop):add(function()
						table.insert(events, "Shop scope")
					end)
				end
				function Shop:stop()
					table.insert(events, "Shop stop")
				end
				return Shop
			end)

			local app = newApp()
			app:addSystems({ Shop, Data })
			app:start()
			app:stop()

			check.equal(#events, 4)
			check.equal(events[1], "Shop stop")
			check.equal(events[2], "Shop scope")
			check.equal(events[3], "Data stop")
			check.equal(events[4], "Data scope")

			-- Too late: a closed scope cleans what it's given at once.
			local cleaned = false
			Scope.of(Shop):add(function()
				cleaned = true
			end)
			check.equal(cleaned, true)
			return nil
		end)

		test.case("stop closes the scopes of players still in the game", function()
			local cleaned = {}
			local Lobby = Hydrogen.define("Lobby", function()
				local Lobby = {}
				function Lobby:playerAdded(player: Player)
					Scope.of(self, player):add(function()
						table.insert(cleaned, player.Name)
					end)
				end
				return Lobby
			end)

			local app = newApp()
			app:addSystem(Lobby)
			app:start()
			app:_addPlayer({ Name = "A" } :: any)
			app:_addPlayer({ Name = "B" } :: any)
			app:stop()

			check.equal(#cleaned, 2)
			return nil
		end)

		test.case("a player who leaves during a yielding playerAdded is cleaned up", function()
			local events = {}
			local loaded: Hydrogen.Scope? = nil

			local Data = Hydrogen.define("Data", function()
				local Data = {}
				function Data:playerAdded(player: Player)
					local scope = Scope.of(self, player)
					-- Still running when the player leaves, and finishes after cleanup.
					scope:spawn(function()
						task.wait(0.05)
						table.insert(events, "late load finished")
					end)
					task.wait()
					scope:add(function()
						table.insert(events, "added before leaving")
					end)
					loaded = scope
				end
				return Data
			end)

			local app = newApp()
			app:addSystem(Data)
			app:start()

			local player = { Name = "P" } :: any
			task.spawn(app._addPlayer, app, player)
			app:_removePlayer(player)

			check.equal(events[1], "added before leaving")
			check.equal((loaded :: any).alive, false)

			-- Work finishing after the player left gets a closed scope.
			local late = Scope.of(Data, player)
			check.equal(late.alive, false)
			local cleaned = false
			late:add(function()
				cleaned = true
			end)
			check.equal(cleaned, true)

			task.wait(0.1)
			check.equal(#events, 1)
			return nil
		end)

		test.case("an error in a player scope's cleanup doesn't stop other systems", function()
			local saved = false

			local Data = Hydrogen.define("Data", function()
				local Data = {}
				function Data:playerRemoving()
					saved = true
				end
				return Data
			end)

			local Broken = Hydrogen.define("Broken", function(use)
				use(Data)
				local Broken = {}
				function Broken:playerAdded(player: Player)
					Scope.of(self, player):add(function()
						error("cleanup boom")
					end)
				end
				return Broken
			end)

			local app = newApp()
			app:addSystems({ Broken, Data })
			app:start()

			local player = { Name = "P" } :: any
			app:_addPlayer(player)
			check.should_not_error(function()
				app:_removePlayer(player)
				return nil
			end)
			check.equal(saved, true)
			return nil
		end)

		test.case("Scope.of errors for systems and players the app doesn't know", function()
			local Lonely = Hydrogen.define("Lonely", function()
				return {}
			end)

			local ok, err = pcall(Scope.of, Lonely)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "Lonely isn't running in an app", 1, true))

			local app = newApp()
			app:addSystem(Lonely)
			app:start()

			ok, err = pcall(Scope.of, Lonely, { Name = "Stranger" } :: any)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "Stranger hasn't been added", 1, true))
			return nil
		end)

		test.case("a failed boot closes the scopes systems opened in init", function()
			local cleaned = false
			local Opens = Hydrogen.define("Opens", function()
				local Opens = {}
				function Opens:init()
					Scope.of(self):add(function()
						cleaned = true
					end)
				end
				return Opens
			end)
			local Fails = Hydrogen.define("Fails", function(use)
				use(Opens)
				return {
					start = function()
						error("boom")
					end,
				}
			end)

			local app = newApp()
			app:addSystems({ Fails, Opens })
			check.should_error(function()
				app:start()
				return nil
			end)
			check.equal(cleaned, true)
			return nil
		end)

		test.case("a fake from app:replace shares the original's scopes", function()
			local app, net = newApp()
			local alice = net:join("Alice")

			local Data = Hydrogen.define("Data", function()
				return {}
			end)

			local fakeScopes = {}
			local fake = {
				start = function(self)
					fakeScopes.system = Scope.of(self)
				end,
				playerAdded = function(self, player: Player)
					fakeScopes.player = Scope.of(self, player)
				end,
			}

			app:replace(Data, fake)
			app:start()

			check.equal(fakeScopes.system, Scope.of(Data))
			check.equal(fakeScopes.system, Scope.of(fake))
			check.equal(fakeScopes.player, Scope.of(Data, alice))
			check.equal(fakeScopes.system.name, "Data (replaced)")

			app:stop()
			check.equal(fakeScopes.system.alive, false)
			check.equal(fakeScopes.player.alive, false)
			check.equal(Scope.of(Data).alive, false)
			return nil
		end)

		test.case("network listeners added to a player scope stop when the player leaves", function()
			local app, net = newApp()
			local alice = net:join("Alice")

			local Ping = Hydrogen.namespace("ScopeTest").clientEvent("Ping", gt.string())
			local heard = {}

			local Pings = Hydrogen.define("Pings", function()
				local Pings = {}
				function Pings:playerAdded(player: Player)
					Scope.of(self, player):add(Ping:On(function(from, text)
						if from == player then
							table.insert(heard, text)
						end
					end))
				end
				return Pings
			end)

			app:addSystem(Pings)
			app:start()

			net:as(alice, function()
				Ping:Fire("hello")
			end)
			check.equal(#heard, 1)
			check.equal(#(Ping :: any)._listeners, 1)

			net:leave(alice)
			check.equal(#(Ping :: any)._listeners, 0)
			return nil
		end)
		return nil
	end)
	return nil
end
