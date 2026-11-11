--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local FakeWorld = require("./Fixtures/FakeWorld")

local Component = Hydrogen.Component
-- Internal: the CollectionService stand-in hook.
local internal = Component :: any
local Clock = Hydrogen.Clock
local gt = Hydrogen.gt

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Each test tags its own name, so components from earlier tests never see its instances.
local tagCount = 0
local function newTag(): string
	tagCount += 1
	return `ComponentTest{tagCount}`
end

local function part(name: string, tag: string?, parent: Instance?): Instance
	local instance = Instance.new("Part")
	instance.Name = name
	if tag then
		instance:AddTag(tag)
	end
	instance.Parent = parent
	return instance
end

local function count(list: { any }): number
	return #list
end

return function()
	-- Instances a test parented into the game, destroyed after it even if it failed.
	local folders: { Instance } = {}

	local function folder(parent: Instance?): Instance
		local instance = Instance.new("Folder")
		instance.Name = "ComponentTest"
		instance.Parent = parent or Workspace
		table.insert(folders, instance)
		return instance
	end

	test.on_test_leave(function()
		for _, instance in folders do
			pcall(instance.Destroy, instance)
		end
		table.clear(folders)
	end)

	test.suite("Component", function()
		test.case("binds instances tagged before the app starts, one object and scope each", function()
			local tag = newTag()
			local root = folder()
			local a = part("A", tag, root)
			local b = part("B", tag, root)
			part("Untagged", nil, root)

			local scopes: { Hydrogen.Scope } = {}
			local Spinner = Component.new(tag, {
				construct = function(instance: Instance, scope: Hydrogen.Scope)
					table.insert(scopes, scope)
					return { name = instance.Name }
				end,
			})

			Hydrogen.test({ systems = { Spinner } }, function(t)
				check.equal(#scopes, 2)
				check.equal(count(Spinner:all()), 2)
				check.equal(count(Spinner:instances()), 2)
				check.equal((Spinner:get(a) :: any).name, "A")
				check.equal((Spinner:get(b) :: any).name, "B")
				check.equal(Spinner:has(a), true)
				check.equal(Spinner.tag, tag)
				t:expectNoWarnings()
			end)

			-- app:stop() destroyed every object and its scope.
			check.equal(scopes[1].alive, false)
			check.equal(scopes[2].alive, false)
			check.equal(Spinner:get(a), nil)
			check.equal(count(Spinner:all()), 0)
			return nil
		end)

		test.case("follows tags added and removed repeatedly", function()
			local tag = newTag()
			local root = folder()
			local coin = part("Coin", nil, root)

			local constructed, destroyed = 0, 0
			local cleaned = 0
			local Coin = Component.new(tag, {
				construct = function(_instance: Instance, scope: Hydrogen.Scope)
					constructed += 1
					scope:add(function()
						cleaned += 1
					end)
					return { generation = constructed }
				end,
				destroy = function(_object, _instance)
					destroyed += 1
				end,
			})

			Hydrogen.test({ systems = { Coin } }, function(t)
				check.equal(Coin:has(coin), false)

				for round = 1, 5 do
					coin:AddTag(tag)
					t:advance(0)
					check.equal(constructed, round)
					check.equal((Coin:get(coin) :: any).generation, round)

					coin:RemoveTag(tag)
					t:advance(0)
					check.equal(destroyed, round)
					check.equal(cleaned, round)
					check.equal(Coin:get(coin), nil)
				end

				-- Added and removed between two frames: never constructed.
				coin:AddTag(tag)
				coin:RemoveTag(tag)
				t:advance(0)
				check.equal(constructed, 5)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("destroys the object when the instance is destroyed", function()
			local tag = newTag()
			local root = folder()
			local coin = part("Coin", tag, root)
			local destroyedFor: Instance? = nil
			local scope: Hydrogen.Scope? = nil

			local Coin = Component.new(tag, {
				construct = function(_instance: Instance, s: Hydrogen.Scope)
					scope = s
				end,
				destroy = function(object: any, instance: Instance)
					check.equal(object == instance, true)
					destroyedFor = instance
				end,
			})

			Hydrogen.test({ systems = { Coin } }, function(t)
				-- construct returned nothing, so the instance is the object.
				check.equal(Coin:get(coin) == coin, true)
				coin:Destroy()
				t:advance(0)
				check.equal(destroyedFor ~= nil, true)
				check.equal((scope :: Hydrogen.Scope).alive, false)
				check.equal(count(Coin:all()), 0)
			end)
			return nil
		end)

		test.case("streaming out and back in constructs a new object", function()
			local tag = newTag()
			local root = folder()
			local door = part("Door", tag, root)
			local objects: { any } = {}

			local Door = Component.new(tag, {
				construct = function(instance: Instance)
					local object = { instance = instance }
					table.insert(objects, object)
					return object
				end,
			})

			Hydrogen.test({ systems = { Door } }, function(t)
				local first = Door:get(door)
				check.equal(first ~= nil, true)

				-- What StreamingEnabled does: parent to nil, then back.
				door.Parent = nil
				t:advance(0)
				check.equal(Door:get(door), nil)

				door.Parent = root
				t:advance(0)
				local second = Door:get(door)
				check.equal(second ~= nil, true)
				check.equal(second ~= first, true)
				check.equal(#objects, 2)

				-- Out and in within one frame: the object stays.
				door.Parent = nil
				door.Parent = root
				t:advance(0)
				check.equal(Door:get(door) == second, true)
			end)
			return nil
		end)

		test.case("binds only under the given ancestors, and follows reparenting", function()
			local tag = newTag()
			local templates = folder(ReplicatedStorage)
			local world = folder(Workspace)
			local template = part("Template", tag, templates)

			local Lamp = Component.new(tag, {
				ancestors = { Workspace },
				construct = function(instance: Instance)
					return instance.Name
				end,
			})

			Hydrogen.test({ systems = { Lamp } }, function(t)
				check.equal(Lamp:has(template), false)

				local clone = template:Clone()
				clone.Name = "Lamp"
				clone.Parent = world
				t:advance(0)
				check.equal(Lamp:get(clone), "Lamp")
				check.equal(Lamp:has(template), false)

				clone.Parent = templates
				t:advance(0)
				check.equal(Lamp:has(clone), false)

				clone.Parent = world
				t:advance(0)
				check.equal(Lamp:has(clone), true)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("waits for required children, warns after the timeout, and constructs when they arrive", function()
			local tag = newTag()
			local root = folder()
			local door = part("Door", tag, root)
			local hinges: { Instance } = {}

			local Door = Component.new(tag, {
				children = { Hinge = "BasePart" },
				timeout = 3,
				construct = function(instance: Instance)
					table.insert(hinges, instance:FindFirstChild("Hinge") :: Instance)
				end,
			})

			Hydrogen.test({ systems = { Door } }, function(t)
				check.equal(Door:has(door), false)
				t:advance(2)
				check.equal(#t:warnings(), 0)
				t:advance(1)
				t:expectWarning(`has waited 3s for child "Hinge"`)

				-- The wrong class doesn't count.
				local folderHinge = Instance.new("Folder")
				folderHinge.Name = "Hinge"
				folderHinge.Parent = door
				t:advance(0)
				check.equal(Door:has(door), false)
				folderHinge:Destroy()

				-- Waiting goes on after the warning.
				part("Hinge", nil, door)
				t:advance(0)
				check.equal(Door:has(door), true)
				check.equal(#hinges, 1)

				-- Losing it destroys the object until it is back.
				local hinge = door:FindFirstChild("Hinge") :: Instance
				hinge.Parent = nil
				t:advance(0)
				check.equal(Door:has(door), false)
				t:expectWarning(`no longer has child "Hinge"`)
				hinge.Parent = door
				t:advance(0)
				check.equal(Door:has(door), true)
				check.equal(#hinges, 2)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("validates attributes, passes them typed and keeps them current", function()
			local tag = newTag()
			local root = folder()
			local coin = part("Coin", tag, root)
			local seen: { [string]: any }? = nil

			local Coin = Component.new(tag, {
				attributes = gt.table({ Value = gt.number(), Label = gt.optional(gt.string()) }),
				construct = function(_instance: Instance, _scope, attributes)
					seen = attributes
					return { value = attributes.Value }
				end,
			})

			Hydrogen.test({ systems = { Coin } }, function(t)
				check.equal(Coin:has(coin), false)
				coin:SetAttribute("Value", "ten")
				t:advance(5)
				check.equal(Coin:has(coin), false)
				t:expectWarning("attributes matching the schema")

				coin:SetAttribute("Value", 10)
				t:advance(0)
				check.equal((Coin:get(coin) :: any).value, 10)
				local attributes = seen :: { [string]: any }
				check.equal(attributes.Value, 10)

				-- Valid changes update the same table.
				coin:SetAttribute("Value", 25)
				t:advance(0)
				check.equal(attributes.Value, 25)
				check.equal(seen == attributes, true)

				-- An invalid change destroys the object until it is valid again.
				coin:SetAttribute("Label", 3)
				t:advance(0)
				check.equal(Coin:has(coin), false)
				t:expectWarning("no longer has attributes matching the schema")
				coin:SetAttribute("Label", "gold")
				t:advance(0)
				check.equal(Coin:has(coin), true)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("an error in one construct or destroy doesn't break the others", function()
			local tag = newTag()
			local root = folder()
			local good = part("Good", tag, root)
			local bad = part("Bad", tag, root)
			local cleanedBad = false
			local attempts = 0

			local Crate = Component.new(tag, {
				construct = function(instance: Instance, scope: Hydrogen.Scope)
					if instance.Name == "Bad" then
						attempts += 1
						scope:add(function()
							cleanedBad = true
						end)
						error("crate exploded")
					end
					return instance.Name
				end,
				destroy = function(object: any)
					if object == "Good" then
						error("destroy exploded")
					end
				end,
			})

			Hydrogen.test({ systems = { Crate } }, function(t)
				check.equal(Crate:get(good), "Good")
				check.equal(Crate:has(bad), false)
				check.equal(cleanedBad, true)
				t:expectWarning("failed to construct for Workspace.ComponentTest.Bad")
				t:expectWarning("crate exploded")

				-- Not retried while nothing changes; retried after it is tagged again.
				t:advance(1)
				check.equal(attempts, 1)
				bad:RemoveTag(tag)
				t:advance(0)
				bad:AddTag(tag)
				t:advance(0)
				check.equal(attempts, 2)
				t:expectWarning("crate exploded")

				good:RemoveTag(tag)
				t:advance(0)
				check.equal(Crate:has(good), false)
				t:expectWarning("destroy exploded")
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("a construct that yields is cancelled if the instance leaves first", function()
			local tag = newTag()
			local root = folder()
			local chest = part("Chest", tag, root)
			local finished, destroyed = 0, 0
			local scope: Hydrogen.Scope? = nil

			local Chest = Component.new(tag, {
				construct = function(_instance: Instance, s: Hydrogen.Scope)
					scope = s
					Clock.wait(2) -- stands in for a load
					finished += 1
					return finished
				end,
				destroy = function()
					destroyed += 1
				end,
			})

			Hydrogen.test({ systems = { Chest } }, function(t)
				check.equal(Chest:has(chest), false)
				chest:RemoveTag(tag)
				t:advance(0)
				check.equal((scope :: Hydrogen.Scope).alive, false)
				t:advance(5)
				check.equal(finished, 0)
				check.equal(destroyed, 0)

				chest:AddTag(tag)
				t:advance(0)
				check.equal(Chest:has(chest), false)
				t:advance(2)
				check.equal(Chest:get(chest), 1)
			end)
			return nil
		end)

		test.case("app:stop() destroys every object and stops listening", function()
			local tag = newTag()
			local root = folder()
			local a = part("A", tag, root)
			local destroyed = 0

			local Orb = Component.new(tag, {
				construct = function() end,
				destroy = function()
					destroyed += 1
				end,
			})

			local t = Hydrogen.harness({ systems = { Orb } })
			part("B", tag, root)
			t:advance(0)
			check.equal(count(Orb:all()), 2)

			t.app:stop()
			check.equal(destroyed, 2)
			check.equal(Orb:has(a), false)

			part("C", tag, root)
			t:advance(0)
			check.equal(count(Orb:all()), 0)
			t:close()

			-- The same component runs again in the next app.
			Hydrogen.test({ systems = { Orb } }, function()
				check.equal(count(Orb:all()), 3)
			end)
			check.equal(destroyed, 5)
			return nil
		end)

		test.case("app:stop() cancels a construct that is still yielding", function()
			local tag = newTag()
			local root = folder()
			part("Slow", tag, root)
			local finished, destroyed = false, 0
			local Slow = Component.new(tag, {
				construct = function()
					Clock.wait(10)
					finished = true
				end,
				destroy = function()
					destroyed += 1
				end,
			})

			Hydrogen.test({ systems = { Slow } }, function(t)
				t:advance(1)
			end)
			check.equal(finished, false)
			check.equal(destroyed, 0)
			check.equal(count(Slow:all()), 0)
			return nil
		end)

		test.case("a failed boot still destroys what components constructed", function()
			local tag = newTag()
			local root = folder()
			part("A", tag, root)
			local destroyed = 0
			local Lamp = Component.new(tag, {
				construct = function() end,
				destroy = function()
					destroyed += 1
				end,
			})
			local Broken = Hydrogen.define("ComponentTestBroken", function(use)
				use(Lamp)
				return {
					start = function()
						error("boot broke")
					end,
				}
			end)

			local ok, err = pcall(Hydrogen.test, { systems = { Lamp, Broken } }, function() end)
			check.equal(ok, false)
			check.equal(string.find(tostring(err), "boot broke", 1, true) ~= nil, true)
			check.equal(destroyed, 1)

			-- Nothing left running, so the next app starts it without a warning.
			Hydrogen.test({ systems = { Lamp } }, function(t)
				check.equal(count(Lamp:all()), 1)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("uses other systems, which start first", function()
			local tag = newTag()
			local root = folder()
			local pad = part("Pad", tag, root)
			local log: { string } = {}

			local Wallet = Hydrogen.define("ComponentTestWallet", function()
				local wallet = { started = false }
				function wallet.start()
					wallet.started = true
					table.insert(log, "wallet started")
				end
				return wallet
			end)

			local Pad = Component.new(tag, function(use)
				local wallet = use(Wallet)
				return {
					construct = function(_instance: Instance)
						table.insert(log, `pad constructed, wallet started: {wallet.started}`)
					end,
				}
			end)

			-- Listed first, but it uses Wallet, so Wallet starts first.
			Hydrogen.test({ systems = { Pad, Wallet } }, function()
				check.equal(log[1], "wallet started")
				check.equal(log[2], "pad constructed, wallet started: true")
				check.equal(Pad:has(pad), true)
			end)
			return nil
		end)

		test.case("wait yields until the object is constructed, or times out", function()
			local tag = newTag()
			local root = folder()
			local gate = part("Gate", nil, root)
			local Gate = Component.new(tag, {
				construct = function()
					return "open"
				end,
			})

			Hydrogen.test({ systems = { Gate } }, function(t)
				local result: string? = nil
				local done = false
				task.spawn(function()
					result = Gate:wait(gate, 10)
					done = true
				end)
				check.equal(done, false)
				gate:AddTag(tag)
				t:advance(0)
				check.equal(done, true)
				check.equal(result, "open")
				check.equal(Gate:wait(gate), "open")

				local other = part("Other", nil, root)
				local timedOut = false
				task.spawn(function()
					timedOut = Gate:wait(other, 3) == nil
				end)
				t:advance(3)
				check.equal(timedOut, true)

				-- No timeout: warns and keeps waiting.
				local late: string? = nil
				task.spawn(function()
					late = Gate:wait(other)
				end)
				t:advance(5)
				t:expectWarning("still waiting for Workspace.ComponentTest.Other")
				other:AddTag(tag)
				t:advance(0)
				check.equal(late, "open")
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("components on the same tag are independent", function()
			local tag = newTag()
			local root = folder()
			local thing = part("Thing", tag, root)
			local Visual = Component.new(tag, {
				construct = function()
					return "visual"
				end,
			})
			local Logic = Component.new(tag, {
				construct = function()
					error("logic broke")
				end,
			})

			Hydrogen.test({ systems = { Visual, Logic } }, function(t)
				check.equal(Visual:get(thing), "visual")
				check.equal(Logic:has(thing), false)
				t:expectWarning("logic broke")
			end)
			return nil
		end)

		test.case("the testing example in docs/ai/component.md runs", function()
			local tag = newTag()
			local Gems = Component.new(tag, {
				ancestors = { workspace },
				attributes = { Value = gt.number() },
				construct = function(_gem: BasePart, _scope, attributes)
					return { value = attributes.Value }
				end,
			})

			Hydrogen.test({ systems = { Gems } }, function(t)
				local gem = Instance.new("Part")
				gem:AddTag(tag)
				gem.Parent = workspace
				t:advance(0)
				check.equal(Gems:has(gem), false)
				gem:SetAttribute("Value", 10)
				t:advance(0)
				check.equal((Gems:get(gem) :: any).value, 10)

				gem.Parent = nil
				t:advance(0)
				check.equal(Gems:has(gem), false)
				gem.Parent = workspace
				t:advance(0)
				check.equal(Gems:has(gem), true)

				gem:RemoveTag(tag)
				t:advance(0)
				check.equal(#Gems:all(), 0)
				t:expectNoWarnings()
				gem:Destroy()
			end)
			return nil
		end)

		test.case("bad options fail at definition with a clear message", function()
			local function message(fn: () -> ()): string
				local ok, err = pcall(fn)
				check.equal(ok, false)
				return tostring(err)
			end

			local function has(text: string, part: string)
				check.equal(string.find(text, part, 1, true) ~= nil, true)
			end

			has(message(function()
				Component.new("", { construct = function() end })
			end), "Component.new needs a tag")
			has(message(function()
				Component.new("X", {} :: any)
			end), "X component needs a construct function")
			has(message(function()
				Component.new("X", { ancestors = { "Workspace" } :: any, construct = function() end })
			end), "ancestors must be a list of Instances")
			has(message(function()
				Component.new("X", { children = { 1 } :: any, construct = function() end })
			end), "children must be a list of names")
			has(message(function()
				Component.new("X", { attributes = 5 :: any, construct = function() end })
			end), "attributes must be a GreenTea schema")
			has(message(function()
				Component.new("X", { timeout = -1, construct = function() end })
			end), "timeout must be a number of seconds")
			has(message(function()
				Component.new("X", function()
					return {} :: any
				end)
			end), "X component needs a construct function")
			return nil
		end)
	end)

	test.suite("Component with CollectionService signals", function()
		-- A real CollectionService is an Instance, which errors on members it doesn't have.
		test.case("the signal source accepts a real Instance as the service", function()
			local Source = require("../src/Component/Source")
			local service = game:GetService("CollectionService")
			check.equal(typeof(service), "Instance")
			check.is_false(pcall(function()
				return (service :: any).root
			end))
			local source = Source.signals(service)
			check.equal(source.root, game)
			return nil
		end)

		-- frktest hooks run around every test, so each case installs the world itself.
		local function useWorld(): any
			local world = FakeWorld()
			internal._collectionService = world.service
			return world
		end
		test.on_test_leave(function()
			internal._collectionService = nil
		end)

		test.case("binds existing instances, follows tags, and costs nothing per instance without filters", function()
			local world = useWorld()
			local tag = newTag()
			local a = world.new("Part", "A", tag, world.workspace)
			local constructed, destroyed = 0, 0
			local Coin = Component.new(tag, {
				construct = function(instance: any)
					constructed += 1
					return instance.Name
				end,
				destroy = function()
					destroyed += 1
				end,
			})

			Hydrogen.test({ systems = { Coin } }, function(t)
				check.equal(Coin:get(a), "A")
				-- No ancestors, children or attributes: no per-instance connections.
				check.equal(a.AncestryChanged:count() + a.ChildAdded:count() + a.AttributeChanged:count(), 0)
				check.equal(world.listeners(tag), 2)

				local b = world.new("Part", "B", tag, world.workspace)
				check.equal(Coin:get(b), "B")
				for _ = 1, 3 do
					b:RemoveTag(tag)
					check.equal(Coin:has(b), false)
					b:AddTag(tag)
					check.equal(Coin:has(b), true)
				end
				check.equal(constructed, 5)
				check.equal(destroyed, 3)

				-- Streaming out and in.
				b:setParent(nil)
				check.equal(Coin:has(b), false)
				b:setParent(world.workspace)
				check.equal(Coin:has(b), true)

				-- Tagged outside the game: nothing until it is parented in.
				local c = world.new("Part", "C", tag, nil)
				check.equal(Coin:has(c), false)
				c:setParent(world.workspace)
				check.equal(Coin:has(c), true)
				c:Destroy()
				check.equal(Coin:has(c), false)
				t:expectNoWarnings()
			end)

			-- Stopped: every connection is gone.
			check.equal(world.listeners(tag), 0)
			check.equal(destroyed, 7)
			return nil
		end)

		test.case("deferred signals in any order end in the right state", function()
			local world = useWorld()
			local tag = newTag()
			local Coin = Component.new(tag, {
				ancestors = { world.workspace },
				construct = function(instance: any)
					return instance.Name
				end,
			})

			Hydrogen.test({ systems = { Coin } }, function()
				world.setDeferred(true)
				local coin = world.new("Part", "Coin", tag, world.workspace)
				coin:RemoveTag(tag)
				coin:AddTag(tag)
				coin:setParent(world.storage)
				coin:setParent(world.workspace)
				coin:setParent(nil)
				coin:setParent(world.workspace)
				check.equal(Coin:has(coin), false)
				world.flush()
				check.equal(Coin:get(coin), "Coin")

				coin:RemoveTag(tag)
				coin:AddTag(tag)
				coin:RemoveTag(tag)
				world.flush()
				check.equal(Coin:has(coin), false)

				coin:AddTag(tag)
				coin:setParent(world.storage)
				world.flush()
				check.equal(Coin:has(coin), false)
				coin:setParent(world.workspace)
				world.flush()
				check.equal(Coin:has(coin), true)
				world.setDeferred(false)
			end)
			return nil
		end)

		test.case("ancestors, children and attributes follow the instance's signals", function()
			local world = useWorld()
			local tag = newTag()
			local door = world.new("Part", "Door", tag, world.storage)
			local Door = Component.new(tag, {
				ancestors = { world.workspace },
				children = { "Hinge" },
				attributes = { Locked = gt.boolean() }, -- a plain table of schemas works too
				construct = function(_instance: any, _scope, attributes)
					return attributes
				end,
			})

			Hydrogen.test({ systems = { Door } }, function(t)
				check.equal(Door:has(door), false)
				door:setParent(world.workspace)
				check.equal(Door:has(door), false)
				local hinge = world.new("Part", "Hinge", nil, door)
				check.equal(Door:has(door), false)
				door:SetAttribute("Locked", true)
				local attributes = Door:get(door) :: any
				check.equal(attributes.Locked, true)
				door:SetAttribute("Locked", false)
				check.equal(attributes.Locked, false)

				hinge:setParent(nil)
				check.equal(Door:has(door), false)
				t:expectWarning(`no longer has child "Hinge"`)
				hinge:setParent(door)
				check.equal(Door:has(door), true)

				door:setParent(world.storage)
				check.equal(Door:has(door), false)
				t:expectNoWarnings()
			end)

			-- Untracked after stop: no connections left on the instance.
			check.equal(door.AncestryChanged:count() + door.ChildAdded:count() + door.AttributeChanged:count(), 0)
			return nil
		end)
	end)
end
