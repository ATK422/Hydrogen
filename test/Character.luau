--!strict

-- characterAdded / characterRemoving hooks, per-character scopes, the fake characters the
-- harness gives loopback players, and the Definition.hooks extension point under them.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Definition = require("../src/Definition")

local Scope = Hydrogen.Scope
local Clock = Hydrogen.Clock

-- Systems that log every player and character hook as "<id>:<hook>:<who>".
local function recorder(events: { string }, id: string, deps: { any }?)
	return Hydrogen.define(id, function(use)
		for _, dependency in deps or {} do
			use(dependency)
		end
		return {
			playerAdded = function(_, player: Player)
				table.insert(events, `{id}:playerAdded:{player.Name}`)
			end,
			playerRemoving = function(_, player: Player)
				table.insert(events, `{id}:playerRemoving:{player.Name}`)
			end,
			characterAdded = function(_, player: Player, character: Model)
				table.insert(events, `{id}:characterAdded:{character.Name}`)
			end,
			characterRemoving = function(_, player: Player, character: Model)
				table.insert(events, `{id}:characterRemoving:{character.Name}`)
			end,
		}
	end)
end

local function list(events: { string }): string
	return table.concat(events, ", ")
end

return function()
	test.suite("Character", function()
		test.case("character hooks run in dependency order, removal in reverse", function()
			local events = {}
			local Data = recorder(events, "Data")
			local Combat = recorder(events, "Combat", { Data })
			local seen: { any } = {}

			local Spy = Hydrogen.define("Spy", function()
				return {
					characterAdded = function(_, player: Player, character: Model)
						seen = { player, character }
					end,
				}
			end)

			Hydrogen.test({ systems = { Combat, Data, Spy }, players = { "alice" } }, function(t, alice)
				table.clear(events)
				local character = t:spawnCharacter(alice)

				check.equal(alice.Character, character)
				check.equal(character.Name, "alice")
				check.not_nil(character:FindFirstChildOfClass("Humanoid"))
				check.equal(seen[1], alice)
				check.equal(seen[2], character)
				check.equal(list(events), "Data:characterAdded:alice, Combat:characterAdded:alice")

				table.clear(events)
				t:removeCharacter(alice)
				check.equal(list(events), "Combat:characterRemoving:alice, Data:characterRemoving:alice")
				check.equal(alice.Character, nil)
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("a respawn removes the old character before adding the new one", function()
			local events = {}
			local Data = recorder(events, "Data")
			local removedFirst: Model? = nil
			local addedSecond: Model? = nil

			local Track = Hydrogen.define("Track", function(use)
				use(Data)
				return {
					characterAdded = function(_, _player: Player, character: Model)
						addedSecond = character
					end,
					characterRemoving = function(_, _player: Player, character: Model)
						removedFirst = character
					end,
				}
			end)

			Hydrogen.test({ systems = { Track }, players = { "alice" } }, function(t, alice)
				local first = t:spawnCharacter(alice)
				table.clear(events)
				local second = t:spawnCharacter(alice)

				check.equal(removedFirst, first)
				check.equal(addedSecond, second)
				check.equal(list(events), "Data:characterRemoving:alice, Data:characterAdded:alice")
				-- Like Roblox, the old character is destroyed.
				check.equal(first.Parent, nil)
				check.equal(second.Parent, workspace)
			end)
			return nil
		end)

		test.case("the next character's characterAdded waits for a yielding characterRemoving", function()
			local events = {}
			local Saver = Hydrogen.define("Saver", function()
				return {
					characterAdded = function(_, _player: Player, character: Model)
						table.insert(events, `added:{character.Name}`)
					end,
					characterRemoving = function(_, _player: Player, character: Model)
						Clock.wait(1)
						table.insert(events, `removed:{character.Name}`)
					end,
				}
			end)

			Hydrogen.test({ systems = { Saver }, players = { "alice" } }, function(t, alice)
				local first = Instance.new("Model")
				first.Name = "first"
				local second = Instance.new("Model")
				second.Name = "second"
				t:spawnCharacter(alice, first)
				t:spawnCharacter(alice, second)
				check.equal(list(events), "added:first")
				t:advance(1)
				check.equal(list(events), "added:first, removed:first, added:second")
			end)
			return nil
		end)

		test.case("characters that exist at start are added after playerAdded", function()
			local events = {}
			local Data = recorder(events, "Data")

			Hydrogen.test({ systems = { Data }, players = { "alice" }, start = false }, function(t, alice)
				t:spawnCharacter(alice)
				check.equal(#events, 0)
				t:start()
				check.equal(list(events), "Data:playerAdded:alice, Data:characterAdded:alice")
			end)
			return nil
		end)

		test.case("characterAdded waits for a yielding playerAdded", function()
			local events = {}
			local Profiles = Hydrogen.define("Profiles", function()
				return {
					playerAdded = function(_, player: Player)
						Clock.wait(2) -- a DataStore load
						table.insert(events, "loaded")
					end,
				}
			end)
			local Combat = recorder(events, "Combat", { Profiles })

			Hydrogen.test({ systems = { Combat }, players = { "alice" } }, function(t, alice)
				t:spawnCharacter(alice)
				check.equal(#events, 0)
				t:advance(2)
				check.equal(list(events), "loaded, Combat:playerAdded:alice, Combat:characterAdded:alice")
			end)
			return nil
		end)

		test.case("a character removed before playerAdded finished gets no hooks", function()
			local events = {}
			local Profiles = Hydrogen.define("Profiles", function()
				return {
					playerAdded = function()
						Clock.wait(2)
					end,
				}
			end)
			local Combat = recorder(events, "Combat", { Profiles })

			Hydrogen.test({ systems = { Combat }, players = { "alice" } }, function(t, alice)
				t:spawnCharacter(alice)
				t:removeCharacter(alice)
				local second = t:spawnCharacter(alice)
				t:spawnCharacter(alice)
				t:removeCharacter(alice)
				t:advance(2)
				check.equal(list(events), "Combat:playerAdded:alice")

				-- One still waiting while a later one is queued: only the last runs.
				table.clear(events)
				second = t:spawnCharacter(alice)
				check.equal(list(events), "Combat:characterAdded:alice")
				check.equal(alice.Character, second)
			end)
			return nil
		end)

		test.case("leaving with a character runs characterRemoving before any playerRemoving", function()
			local events = {}
			local Data = recorder(events, "Data")
			local Combat = recorder(events, "Combat", { Data })
			local character: Model? = nil

			Hydrogen.test({ systems = { Combat }, players = { "alice" } }, function(t, alice)
				character = t:spawnCharacter(alice)
				table.clear(events)
				t:leave(alice)
				check.equal(
					list(events),
					"Combat:characterRemoving:alice, Data:characterRemoving:alice, Combat:playerRemoving:alice, Data:playerRemoving:alice"
				)
			end)
			check.equal((character :: Model).Parent, nil)
			return nil
		end)

		test.case("leaving while characterAdded yields waits for it, then removes in order", function()
			local events = {}
			local Slow = Hydrogen.define("Slow", function()
				return {
					characterAdded = function()
						Clock.wait(1)
						table.insert(events, "added")
					end,
					characterRemoving = function()
						table.insert(events, "characterRemoving")
					end,
					playerRemoving = function()
						table.insert(events, "playerRemoving")
					end,
				}
			end)

			Hydrogen.test({ systems = { Slow }, players = { "alice" } }, function(t, alice)
				t:spawnCharacter(alice)
				t:leave(alice)
				check.equal(#events, 0)
				t:advance(1)
				check.equal(list(events), "added, characterRemoving, playerRemoving")
			end)
			return nil
		end)

		test.case("the app stopping removes characters before players", function()
			local events = {}
			local Data = recorder(events, "Data")

			Hydrogen.test({ systems = { Data }, players = { "alice", "bob" } }, function(t, alice, bob)
				t:spawnCharacter(alice)
				t:spawnCharacter(bob)
				table.clear(events)
			end)

			local aliceCharacter = table.find(events, "Data:characterRemoving:alice") :: number
			local alicePlayer = table.find(events, "Data:playerRemoving:alice") :: number
			local bobCharacter = table.find(events, "Data:characterRemoving:bob") :: number
			local bobPlayer = table.find(events, "Data:playerRemoving:bob") :: number
			check.equal(#events, 4)
			check.is_true(aliceCharacter < alicePlayer)
			check.is_true(bobCharacter < bobPlayer)
			return nil
		end)

		test.case("an error in one system's character hook is warned and the rest still run", function()
			local events = {}
			local Data = recorder(events, "Data")
			local Broken = Hydrogen.define("Broken", function(use)
				use(Data)
				return {
					characterAdded = function()
						error("added boom")
					end,
					characterRemoving = function()
						error("removing boom")
					end,
				}
			end)
			local After = recorder(events, "After", { Broken })

			Hydrogen.test({ systems = { After }, players = { "alice" } }, function(t, alice)
				table.clear(events)
				t:spawnCharacter(alice)
				t:removeCharacter(alice)
				check.equal(
					list(events),
					"Data:characterAdded:alice, After:characterAdded:alice, After:characterRemoving:alice, Data:characterRemoving:alice"
				)
				t:expectWarning("characterAdded failed in system Broken")
				t:expectWarning("characterRemoving failed in system Broken")
				t:expectNoWarnings()
			end)
			return nil
		end)

		test.case("each character gets a scope, destroyed right after the system's characterRemoving", function()
			local scopes: { Hydrogen.Scope } = {}
			local aliveInRemoving: boolean? = nil
			local playerScope: Hydrogen.Scope? = nil

			local Combat = Hydrogen.define("Combat", function()
				local Combat = {}
				function Combat:characterAdded(player: Player, character: Model)
					local scope = Scope.of(self, character)
					table.insert(scopes, scope)
					playerScope = Scope.of(self, player)
					local part = scope:add(Instance.new("Part"))
					part.Parent = character
				end
				function Combat:characterRemoving(_player: Player, character: Model)
					aliveInRemoving = Scope.of(self, character).alive
				end
				return Combat
			end)

			Hydrogen.test({ systems = { Combat }, players = { "alice" } }, function(t, alice)
				local first = t:spawnCharacter(alice)
				check.equal(scopes[1], Scope.of(Combat, first))
				check.equal(scopes[1].name, "Combat for character alice")
				check.is_true(scopes[1] ~= playerScope)

				t:spawnCharacter(alice)
				check.equal(aliveInRemoving, true)
				check.equal(scopes[1].alive, false)
				check.equal(scopes[2].alive, true)
				check.is_true(scopes[1] ~= scopes[2])
				check.equal((playerScope :: Hydrogen.Scope).alive, true)

				-- After removal Scope.of hands out a destroyed scope, which cleans at once.
				local late = Scope.of(Combat, first)
				check.equal(late.alive, false)

				local stranger = Instance.new("Model")
				local ok, err = pcall(Scope.of, Combat, stranger)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "isn't a character", 1, true))
			end)
			check.equal(scopes[2].alive, false)
			return nil
		end)

		test.case("client apps get every player's character hooks", function()
			local net = Hydrogen.loopback()
			local seen: { [string]: { string } } = { server = {}, client = {} }

			local function watcher(side: string)
				return Hydrogen.define(`Watcher_{side}`, function()
					return {
						characterAdded = function(_, player: Player)
							table.insert(seen[side], `+{player.Name}`)
						end,
						characterRemoving = function(_, player: Player)
							table.insert(seen[side], `-{player.Name}`)
						end,
					}
				end)
			end

			local server = Hydrogen.App.new()
			server:addSystem(watcher("server"))
			local client = Hydrogen.App.new()
			client:addSystem(watcher("client"))

			local ok, err = pcall(function()
				server:start()
				client:start()
				local alice = net:join("alice")
				local bob = net:join("bob")
				Hydrogen.Character.spawnFake(alice)
				Hydrogen.Character.spawnFake(bob)
				Hydrogen.Character.removeFake(alice)

				check.equal(list(seen.server), "+alice, +bob, -alice")
				check.equal(list(seen.client), "+alice, +bob, -alice")
			end)
			client:stop()
			server:stop()
			net:close()
			Hydrogen.Character._reset()
			if not ok then
				error(err, 0)
			end
			return nil
		end)

		test.case("a character streaming out is removed, and added again when it streams back in", function()
			local events = {}
			local Nametags = recorder(events, "Nametags")
			local tags: { Hydrogen.Scope } = {}
			local Tagger = Hydrogen.define("Tagger", function()
				local Tagger = {}
				function Tagger:characterAdded(_player: Player, character: Model)
					table.insert(tags, Scope.of(self, character))
				end
				return Tagger
			end)

			Hydrogen.test({ systems = { Nametags, Tagger }, players = { "alice" } }, function(t, alice)
				local character = t:spawnCharacter(alice)
				table.clear(events)

				t:streamCharacter(alice, false)
				check.equal(list(events), "Nametags:characterRemoving:alice")
				check.equal(tags[1].alive, false)
				check.equal(alice.Character, character)

				table.clear(events)
				t:streamCharacter(alice, true)
				check.equal(list(events), "Nametags:characterAdded:alice")
				check.equal(tags[2].alive, true)
				check.equal(Scope.of(Tagger, character), tags[2])

				-- A respawn while streamed out removes nothing twice.
				t:streamCharacter(alice, false)
				table.clear(events)
				t:spawnCharacter(alice)
				check.equal(list(events), "Nametags:characterAdded:alice")
			end)
			return nil
		end)

		test.case("a system added after start gets characterAdded for existing characters", function()
			local events = {}
			Hydrogen.test({ players = { "alice" } }, function(t, alice)
				t:spawnCharacter(alice)
				t:add(recorder(events, "Late"))
				check.equal(list(events), "Late:playerAdded:alice, Late:characterAdded:alice")

				table.clear(events)
				t:spawnCharacter(alice)
				check.equal(list(events), "Late:characterRemoving:alice, Late:characterAdded:alice")
			end)
			return nil
		end)

		test.case("apps without character hooks attach nothing", function()
			local Plain = Hydrogen.define("Plain", function()
				return {
					playerAdded = function() end,
				}
			end)

			Hydrogen.test({ systems = { Plain }, players = { "alice" } }, function(t, alice)
				check.equal(#(t.app :: any)._attached, 0)
				-- Spawning still works; nobody listens.
				t:spawnCharacter(alice)
				check.equal(#(t.app :: any)._attached, 0)
			end)
			return nil
		end)

		test.case("character helpers check their arguments", function()
			Hydrogen.test({ players = { "alice" } }, function(t, alice)
				local ok, err = pcall(function()
					t:spawnCharacter({ Name = "nobody" } :: any)
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "t:spawnCharacter expects a player", 1, true))

				ok, err = pcall(function()
					t:spawnCharacter(alice, Instance.new("Part") :: any)
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "expects a Model", 1, true))

				ok, err = pcall(function()
					t:streamCharacter(alice, false)
				end)
				check.equal(ok, false)
				check.not_nil(string.find(tostring(err), "has no character", 1, true))

				-- A model of your own is used as is.
				local mine = Instance.new("Model")
				check.equal(t:spawnCharacter(alice, mine), mine)
			end)
			return nil
		end)
	end)

	test.suite("Hook extension point", function()
		-- One registered pair for these tests: "round" subjects, driven by hand through the feed.
		local feeds: { Definition.Feed } = {}
		local detached = 0
		local watched: { string } = {}

		Definition.hooks({
			name = "round",
			added = "roundStarted",
			removing = "roundEnded",
			attach = function(feed)
				table.insert(feeds, feed)
				return function()
					detached += 1
				end
			end,
			player = function(_feed, player)
				table.insert(watched, `+{player.Name}`)
				return function()
					table.insert(watched, `-{player.Name}`)
				end
			end,
		})

		test.on_test_leave(function()
			table.clear(feeds)
			table.clear(watched)
			detached = 0
		end)

		local function rounds(events: { string }, id: string, deps: { any }?)
			return Hydrogen.define(id, function(use)
				for _, dependency in deps or {} do
					use(dependency)
				end
				return {
					roundStarted = function(_, name: string)
						table.insert(events, `{id}:started:{name}`)
					end,
					roundEnded = function(_, name: string)
						table.insert(events, `{id}:ended:{name}`)
					end,
				}
			end)
		end

		test.case("registered hooks run in dependency order with the same guarantees", function()
			local events = {}
			local A = rounds(events, "A")
			local B = rounds(events, "B", { A })
			local subject = { Name = "r1" }

			Hydrogen.test({ systems = { B }, players = { "alice" } }, function(t)
				check.equal(#feeds, 1)
				local feed = feeds[1]
				check.equal(list(watched), "+alice")

				check.equal(feed:add(subject, { "r1" }), true)
				check.equal(feed:add(subject, { "r1" }), false)
				check.equal(feed:has(subject), true)
				check.equal(list(events), "A:started:r1, B:started:r1")

				local scope = Scope.of(A, subject :: any)
				check.equal(scope.name, "A for round r1")

				table.clear(events)
				feed:remove(subject)
				feed:remove(subject)
				check.equal(list(events), "B:ended:r1, A:ended:r1")
				check.equal(feed:has(subject), false)
				check.equal(scope.alive, false)
			end)
			check.equal(detached, 1)
			check.equal(list(watched), "+alice, -alice")
			return nil
		end)

		test.case("removal waits for a yielding added hook, and errors don't stop the rest", function()
			local events = {}
			local Slow = Hydrogen.define("Slow", function()
				return {
					roundStarted = function()
						Clock.wait(1)
						error("start boom")
					end,
					roundEnded = function()
						table.insert(events, "slow ended")
					end,
				}
			end)
			local After = rounds(events, "After", { Slow })

			Hydrogen.test({ systems = { After } }, function(t)
				local feed = feeds[1]
				local subject = { Name = "r" }
				task.spawn(feed.add, feed, subject, { "r" })
				local removed = false
				task.spawn(function()
					feed:remove(subject)
					removed = true
				end)
				check.equal(removed, false)
				check.equal(#events, 0)

				t:advance(1)
				check.equal(removed, true)
				check.equal(list(events), "After:started:r, After:ended:r, slow ended")
				t:expectWarning("roundStarted failed in system Slow")
			end)
			return nil
		end)

		test.case("a subject with a parent waits for it and goes before it", function()
			local events = {}
			local Profiles = Hydrogen.define("Profiles", function()
				return {
					playerAdded = function(_, player: Player)
						Clock.wait(1)
						table.insert(events, `loaded:{player.Name}`)
					end,
					playerRemoving = function(_, player: Player)
						table.insert(events, `saved:{player.Name}`)
					end,
				}
			end)
			local R = rounds(events, "R", { Profiles })

			Hydrogen.test({ systems = { R }, players = { "alice" } }, function(t, alice)
				local feed = feeds[1]
				local subject = { Name = "duel" }
				local result: boolean? = nil
				task.spawn(function()
					result = feed:add(subject, { "duel" }, alice)
				end)
				check.equal(#events, 0)
				t:advance(1)
				check.equal(result, true)
				check.equal(list(events), "loaded:alice, R:started:duel")

				table.clear(events)
				t:leave(alice)
				check.equal(list(events), "R:ended:duel, saved:alice")

				-- A parent that's gone, or a stopped app, adds nothing.
				check.equal(feed:add({ Name = "late" }, { "late" }, alice), false)
			end)
			return nil
		end)

		test.case("one Instance can be a subject of two hook pairs with separate scopes", function()
			local events = {}
			local Both = Hydrogen.define("Both", function()
				return {
					characterAdded = function(_, _player: Player, character: Model)
						table.insert(events, `character+{character.Name}`)
					end,
					characterRemoving = function(_, _player: Player, character: Model)
						table.insert(events, `character-{character.Name}`)
					end,
					roundStarted = function(_, name: string)
						table.insert(events, `round+{name}`)
					end,
					roundEnded = function(_, name: string)
						table.insert(events, `round-{name}`)
					end,
				}
			end)

			Hydrogen.test({ systems = { Both }, players = { "alice" } }, function(t, alice)
				local feed = feeds[1]
				local character = t:spawnCharacter(alice)
				check.equal(feed:add(character, { "alice" }), true)

				local characterScope = Scope.of(Both, character)
				local roundScope = feed:scope(Both, character)
				check.is_true(characterScope ~= roundScope)
				check.equal(roundScope.name, "Both for round alice")

				feed:remove(character)
				check.equal(roundScope.alive, false)
				check.equal(characterScope.alive, true)
				check.equal(list(events), "character+alice, round+alice, round-alice")
			end)
			return nil
		end)

		test.case("Definition.hooks rejects bad and duplicate hook names", function()
			for _, spec in {
				{ name = "x", added = "playerAdded", removing = "xRemoved" },
				{ name = "x", added = "roundStarted", removing = "xRemoved" },
				{ name = "x", added = "same", removing = "same" },
				{ name = "x", added = "" , removing = "xRemoved" },
			} :: { any } do
				local ok = pcall(Definition.hooks, spec)
				check.equal(ok, false)
			end
			return nil
		end)
	end)

	test.suite("Used systems", function()
		test.case("a system that's used but wasn't added is added and boots first", function()
			local events = {}
			local Store = Hydrogen.define("UsedStore", function()
				return {
					init = function()
						table.insert(events, "store:init")
					end,
					playerAdded = function()
						table.insert(events, "store:playerAdded")
					end,
				}
			end)
			local Shop = Hydrogen.define("UsedShop", function(use)
				use(Store)
				return {
					init = function()
						table.insert(events, "shop:init")
					end,
					playerAdded = function()
						table.insert(events, "shop:playerAdded")
					end,
				}
			end)

			local output: { string } = {}
			Hydrogen.test({
				systems = { Shop },
				players = 1,
				app = {
					debug = true,
					output = function(message: string)
						table.insert(output, message)
					end,
				},
			}, function(t)
				check.equal(list(events), "store:init, shop:init, store:playerAdded, shop:playerAdded")
				t:expectNoWarnings()
			end)
			check.not_nil(string.find(output[1], "Added UsedStore: UsedShop uses it", 1, true))
			return nil
		end)

		test.case("a replaced system's dependencies aren't added", function()
			local booted = false
			local Backend = Hydrogen.define("UsedBackend", function()
				return {
					init = function()
						booted = true
					end,
				}
			end)
			local Store = Hydrogen.define("ReplacedStore", function(use)
				use(Backend)
				return {
					get = function()
						return "real"
					end,
				}
			end)

			Hydrogen.test({ replace = { [Store] = { get = function()
				return "fake"
			end } } }, function(t)
				check.equal(booted, false)
				check.equal(Store.get(), "fake")
				t:expectWarning("depends on system UsedBackend which was not added")
			end)
			return nil
		end)

		test.case("a system added after start brings what it uses", function()
			local events = {}
			local Dep = Hydrogen.define("LateDep", function()
				return {
					start = function()
						table.insert(events, "dep:start")
					end,
				}
			end)
			local Late = Hydrogen.define("LateUser", function(use)
				use(Dep)
				return {
					start = function()
						table.insert(events, "late:start")
					end,
				}
			end)

			Hydrogen.test(function(t)
				t:add(Late)
				t:add(Late)
				check.equal(list(events), "dep:start, late:start")
			end)
			return nil
		end)
	end)
end
