--!strict

-- Guards: cooldowns, roles and permissions, range checks and predicates, as middleware on real
-- network objects under Hydrogen.test (loopback players, fake clock).

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")

local Clock = Hydrogen.Clock
local Guards = Hydrogen.Guards
local Receipts = Hydrogen.Receipts
local gt = Hydrogen.gt

-- Network objects are made per test case, as other suites reset the registry between them.
local made = 0
local Cast: Hydrogen.ClientEvent<number>
local Hit: Hydrogen.ClientEvent<Vector3>
local Ask: Hydrogen.ClientFunction<(number), (string)>
local Notify: Hydrogen.ServerEvent<string>

local function remotes()
	made += 1
	Cast = Hydrogen.clientEvent(`guards-Cast{made}`, gt.number())
	Hit = Hydrogen.clientEvent(`guards-Hit{made}`, gt.Vector3())
	Ask = Hydrogen.clientFunction(`guards-Ask{made}`, gt.args(gt.number()), gt.returns(gt.string()))
	Notify = Hydrogen.serverEvent(`guards-Notify{made}`, gt.string())
end

local GROUP = 4242
local PASS = 777

-- Roles are defined once, at module level, as a game would. Tests change what they resolve from.
local ranks: { [Player]: number } = {}
local testers: { [Player]: boolean } = {}
local flaky: { [Player]: boolean } = {}
local slowCalls = 0
-- While true, g-slow takes a second to answer.
local slowWait = false
local countedCalls = 0
local unsure = 0
local owners: { number } = {}

-- Fake players have no GetRankInGroup; give them one that reads ranks.
local function inGroup(player: Player, rank: number)
	ranks[player] = rank
	;(player :: any).GetRankInGroup = function(self: Player, groupId: number): number
		assert(groupId == GROUP, "wrong group")
		return ranks[self] or 0
	end
end

Guards.defineRole("g-owner", function(player: Player): boolean?
	return table.find(owners, player.UserId) ~= nil
end)
Guards.defineRole("g-staff", Guards.groupRank(GROUP, 100), "g-owner")
Guards.defineRole("g-vip", Guards.gamePass(PASS))
Guards.defineRole("g-tester", function(player: Player): boolean?
	return testers[player] == true
end)
Guards.defineRole("g-flaky", function(player: Player): boolean?
	if flaky[player] then
		error("resolver exploded")
	end
	return false
end)
Guards.defineRole("g-slow", function(_player: Player): boolean?
	slowCalls += 1
	if slowWait then
		Clock.wait(1)
	end
	return true
end)
Guards.defineRole("g-counted", function(_player: Player): boolean?
	countedCalls += 1
	return true
end)
Guards.defineRole("g-unsure", function(_player: Player): boolean?
	unsure += 1
	return nil
end)
Guards.definePermission("g-ban", { "g-owner", "g-staff" })

local function noop(...: any) end

local function count(map: any): number
	local total = 0
	for _ in map do
		total += 1
	end
	return total
end

-- Every rejection a hook saw, as "name: reason".
local function recorder(): ({ string }, (context: Hydrogen.MiddlewareContext, reason: string) -> ())
	local seen: { string } = {}
	return seen, function(context: Hydrogen.MiddlewareContext, reason: string)
		table.insert(seen, `{context.name}: {reason}`)
	end
end

return function()
	test.suite("Guards cooldowns", function()
		test.case("a cooldown guard drops events until it is ready again", function()
			remotes()
			local fireball = Guards.cooldown(5, { name = "Fireball" })
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				local rejections, onReject = recorder()
				Cast:On(noop)
				Cast:Use(fireball:guard({ onReject = onReject }))

				Cast:Fire(1)
				Cast:Fire(2)
				t:expect(Cast):firedBy(alice, 1):firedTimes(1)
				check.equal(fireball:ready(alice), false)
				check.equal(fireball:remaining(alice), 5)
				check.equal(rejections[1], `guards-Cast{made}: Fireball is on cooldown (5.0s left)`)

				t:advance(4.9)
				Cast:Fire(3)
				t:expect(Cast):firedTimes(1)

				t:advance(0.1)
				check.equal(fireball:ready(alice), true)
				Cast:Fire(4)
				t:expect(Cast):firedBy(alice, 4):firedTimes(2)
			end)
		end)

		test.case("charges are used up and come back one at a time", function()
			remotes()
			local dash = Guards.cooldown(6, { charges = 3 })
			Hydrogen.test({ players = { "Alice" } }, function(t, alice)
				Cast:On(noop)
				Cast:Use(dash:guard())

				for index = 1, 4 do
					Cast:Fire(index)
				end
				t:expect(Cast):firedTimes(3)
				check.equal(dash:charges(alice), 0)
				check.equal(dash:remaining(alice), 6)

				t:advance(6)
				check.equal(dash:charges(alice), 1)
				Cast:Fire(5)
				Cast:Fire(6)
				t:expect(Cast):firedTimes(4)

				t:advance(18)
				check.equal(dash:charges(alice), 3)
				check.equal(dash:remaining(alice), 0)
			end)
		end)

		test.case("a gap spaces uses out even with charges left", function()
			remotes()
			local blink = Guards.cooldown(10, { charges = 2, gap = 1 })
			Hydrogen.test({ players = 1 }, function(t, alice)
				check.equal(blink:use(alice), true)
				check.equal(blink:use(alice), false)
				check.equal(blink:charges(alice), 1)
				check.equal(blink:remaining(alice), 1)
				t:advance(1)
				check.equal(blink:use(alice), true)
				check.equal(blink:use(alice), false)
				check.equal(blink:remaining(alice), 9)
			end)
		end)

		test.case("cooldowns in a group share it", function()
			remotes()
			local global = Guards.cooldown(1, { name = "Global" })
			local fireball = Guards.cooldown(5, { group = { global } })
			local frost = Guards.cooldown(3, { group = { global } })
			Hydrogen.test({ players = 1 }, function(t, alice)
				check.equal(fireball:use(alice), true)
				check.equal(global:ready(alice), false)
				check.equal(frost:use(alice), false)
				check.equal(frost:remaining(alice), 1)
				-- A refused use changes nothing.
				check.equal(frost:charges(alice), 1)

				t:advance(1)
				check.equal(frost:use(alice), true)
				check.equal(fireball:use(alice), false)
				check.equal(fireball:remaining(alice), 4)
			end)
		end)

		test.case("a shared cooldown is used once even when two guards share it", function()
			remotes()
			local global = Guards.cooldown(1)
			local fireball = Guards.cooldown(5, { group = { global } })
			local frost = Guards.cooldown(3, { group = { global } })
			Hydrogen.test({ players = 1 }, function(t, alice)
				Cast:On(noop)
				Cast:Use(Guards.all(fireball:guard(), frost:guard()))
				Cast:Fire(1)
				t:expect(Cast):firedTimes(1)
				check.equal(global:remaining(alice), 1)
				check.equal(fireball:remaining(alice), 5)
				check.equal(frost:remaining(alice), 3)
			end)
		end)

		test.case("reset gives charges back", function()
			remotes()
			local potion = Guards.cooldown(30)
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(_t, alice, bob)
				potion:use(alice)
				potion:use(bob)
				potion:reset(alice)
				check.equal(potion:ready(alice), true)
				check.equal(potion:ready(bob), false)
				potion:reset()
				check.equal(potion:ready(bob), true)
			end)
		end)

		test.case("a player's cooldowns are cleared when they leave", function()
			remotes()
			local potion = Guards.cooldown(30, { gap = 2 })
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				potion:use(alice)
				potion:use(bob)
				local internal = potion :: any
				check.equal(count(internal._full), 2)
				check.equal(count(internal._last), 2)

				t:leave(alice)
				check.equal(count(internal._full), 1)
				check.equal(count(internal._last), 1)
				check.equal(potion:ready(alice), true)

				-- Nothing is kept for a player who already left.
				potion:use(alice)
				check.equal(count(internal._full), 1)
			end)
		end)

		test.case("bad options are rejected with a clear error", function()
			remotes()
			local function message(fn: () -> ()): string
				local ok, err = pcall(fn)
				check.equal(ok, false)
				return tostring(err)
			end
			check.not_nil(string.find(message(function()
				Guards.cooldown(0)
			end), "Guards.cooldown expects a positive number of seconds", 1, true))
			check.not_nil(string.find(message(function()
				Guards.cooldown(1, { charges = 1.5 })
			end), "charges must be a whole number", 1, true))
			check.not_nil(string.find(message(function()
				Guards.cooldown(1, { group = { {} :: any } })
			end), "group must hold cooldowns", 1, true))
		end)
	end)

	test.suite("Guards roles", function()
		test.case("roles resolve from user ids, group rank, game passes, functions and other roles", function()
			remotes()
			local market = Receipts.fakeMarketplace()
			Receipts.configure({ marketplace = market })
			Guards.invalidate()

			Hydrogen.test({ players = { "Alice", "Bob", "Carol", "Dave" } }, function(_t, alice, bob, carol, dave)
				owners = { alice.UserId }
				inGroup(alice, 0)
				inGroup(bob, 150)
				inGroup(carol, 50)
				inGroup(dave, 0)
				market:setOwnsGamePass(carol, PASS, true)
				testers[dave] = true

				check.equal(Guards.hasRole(alice, "g-owner"), true)
				check.equal(Guards.hasRole(alice, "g-staff"), true) -- through g-owner
				check.equal(Guards.hasRole(bob, "g-owner"), false)
				check.equal(Guards.hasRole(bob, "g-staff"), true)
				check.equal(Guards.hasRole(carol, "g-staff"), false)
				check.equal(Guards.hasRole(carol, "g-vip"), true)
				check.equal(Guards.hasRole(dave, "g-tester"), true)
				check.equal(Guards.hasRole(dave, "g-vip"), false)

				check.equal(Guards.can(alice, "g-ban"), true)
				check.equal(Guards.can(bob, "g-ban"), true)
				check.equal(Guards.can(dave, "g-ban"), false)

				local roles = Guards.rolesOf(alice)
				check.not_nil(table.find(roles, "g-owner"))
				check.not_nil(table.find(roles, "g-staff"))
				check.falsy(table.find(roles, "g-tester"))
			end)
			owners = {}
			table.clear(testers)
		end)

		test.case("answers are cached per player until invalidated", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(_t, alice, bob)
				countedCalls = 0
				Guards.invalidate()
				check.equal(Guards.hasRole(alice, "g-counted"), true)
				check.equal(Guards.hasRole(alice, "g-counted"), true)
				check.equal(Guards.hasRole(bob, "g-counted"), true)
				check.equal(countedCalls, 2)

				Guards.invalidate(alice)
				Guards.hasRole(alice, "g-counted")
				Guards.hasRole(bob, "g-counted")
				check.equal(countedCalls, 3)

				Guards.invalidate()
				Guards.hasRole(alice, "g-counted")
				Guards.hasRole(bob, "g-counted")
				check.equal(countedCalls, 5)

				-- nil means "not now": never cached.
				unsure = 0
				check.equal(Guards.hasRole(alice, "g-unsure"), false)
				check.equal(Guards.hasRole(alice, "g-unsure"), false)
				check.equal(unsure, 2)
			end)
		end)

		test.case("a game pass bought in game counts without invalidating", function()
			remotes()
			local market = Receipts.fakeMarketplace()
			Receipts.configure({ marketplace = market })
			Hydrogen.test({ players = 1 }, function(_t, alice)
				check.equal(Guards.hasRole(alice, "g-vip"), false)
				market:setOwnsGamePass(alice, PASS, true)
				check.equal(Guards.hasRole(alice, "g-vip"), true)
			end)
		end)

		test.case("a failing resolver warns, denies and is asked again", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				flaky[alice] = true
				check.equal(Guards.hasRole(alice, "g-flaky"), false)
				t:expectWarning(`Role "g-flaky" resolver failed for Alice`)

				flaky[alice] = nil
				check.equal(Guards.hasRole(alice, "g-flaky"), false)

				;(bob :: any).GetRankInGroup = function()
					error("HTTP 500")
				end
				check.equal(Guards.hasRole(bob, "g-staff"), false)
				t:expectWarning(`Couldn't get Bob's rank in group {GROUP}`)
				inGroup(bob, 200)
				check.equal(Guards.hasRole(bob, "g-staff"), true)
			end)
		end)

		test.case("checks made while a role resolves wait for the same answer", function()
			remotes()
			slowWait = true
			Hydrogen.test({ players = 1 }, function(t, alice)
				slowCalls = 0
				Guards.invalidate()
				local answers: { boolean } = {}
				for _ = 1, 3 do
					task.spawn(function()
						table.insert(answers, Guards.hasRole(alice, "g-slow"))
					end)
				end
				check.equal(slowCalls, 1)
				check.equal(#answers, 0)

				t:advance(1)
				check.equal(#answers, 3)
				check.equal(answers[1] and answers[2] and answers[3], true)
				Guards.hasRole(alice, "g-slow")
				check.equal(slowCalls, 1)
			end)
			slowWait = false
		end)

		test.case("an answer that arrives after the player left is not kept", function()
			remotes()
			slowWait = true
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice)
				slowCalls = 0
				Guards.invalidate()
				local answer: boolean? = nil
				task.spawn(function()
					answer = Guards.hasRole(alice, "g-slow")
				end)
				t:leave(alice)
				t:advance(1)
				check.equal(answer, true)

				-- Not cached for a player who left, so asking again resolves again.
				task.spawn(Guards.hasRole, alice, "g-slow")
				check.equal(slowCalls, 2)
				t:advance(1)
			end)
			slowWait = false
		end)

		test.case("a player's cached roles are cleared when they leave", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice)
				countedCalls = 0
				Guards.invalidate()
				Guards.hasRole(alice, "g-counted")
				Guards.hasRole(alice, "g-counted")
				check.equal(countedCalls, 1)

				t:leave(alice)
				Guards.hasRole(alice, "g-counted")
				check.equal(countedCalls, 2)
			end)
		end)

		test.case("mistakes in role definitions get clear errors", function()
			remotes()
			local function message(fn: () -> ()): string
				local ok, err = pcall(fn)
				check.equal(ok, false)
				return tostring(err)
			end

			Hydrogen.test({ players = 1 }, function(_t, alice)
				check.not_nil(string.find(message(function()
					Guards.hasRole(alice, "g-nope")
				end), `Unknown role "g-nope"`, 1, true))
				check.not_nil(string.find(message(function()
					Guards.can(alice, "g-nope")
				end), `Unknown permission "g-nope"`, 1, true))
				check.not_nil(string.find(message(function()
					Guards.defineRole("g-owner", Guards.userIds({ 1 }))
				end), `Role "g-owner" is already defined`, 1, true))

				local removeA = Guards.defineRole("g-cycle-a", "g-cycle-b")
				local removeB = Guards.defineRole("g-cycle-b", "g-cycle-a")
				check.not_nil(string.find(message(function()
					Guards.hasRole(alice, "g-cycle-a")
				end), "includes itself through other roles", 1, true))
				removeA()
				removeB()
				check.not_nil(string.find(message(function()
					Guards.hasRole(alice, "g-cycle-a")
				end), `Unknown role "g-cycle-a"`, 1, true))
			end)
		end)

		test.case("a role guard rejects a function request with the reason", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				owners = { alice.UserId }
				Guards.invalidate()
				local rejections, onReject = recorder()
				local contexts: { Hydrogen.MiddlewareContext } = {}
				Ask:On(function(_player: Player, value: number): string
					return `ok {value}`
				end)
				Ask:UseRequest(Guards.role("g-owner", {
					onReject = function(context, reason)
						table.insert(contexts, context)
						onReject(context, reason)
					end,
				}))

				local answer = t:as(alice, function()
					return Ask:Fire(1)
				end)
				check.equal(answer, "ok 1")

				local ok, err = t:as(bob, function()
					return pcall(Ask.Fire, Ask, 2)
				end)
				check.equal(ok, false)
				check.equal(tostring(err), `[HYDROGEN] guards-Ask{made} request rejected: missing role "g-owner"`)
				check.equal(rejections[1], `guards-Ask{made}: missing role "g-owner"`)
				check.equal(contexts[1].player, bob)
				check.equal(contexts[1].payload, "request")
				t:expect(Ask):calledTimes(1)
			end)
			owners = {}
		end)

		test.case("a permission guard drops events and can send its own reason", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				inGroup(alice, 254)
				inGroup(bob, 10)
				Guards.invalidate()
				local rejections, onReject = recorder()
				Cast:On(noop)
				Cast:Use(Guards.permission("g-ban", { reason = "Staff only", onReject = onReject }))

				t:as(alice, function()
					Cast:Fire(1)
				end)
				t:as(bob, function()
					Cast:Fire(2)
				end)
				t:expect(Cast):firedBy(alice, 1):notFired(bob)
				check.equal(rejections[1], `guards-Cast{made}: Staff only`)
			end)
		end)
	end)

	test.suite("Guards range", function()
		test.case("targets within range plus slack pass", function()
			remotes()
			local positions: { [Player]: Vector3 } = {}
			Guards.configure({
				position = function(player: Player): Vector3?
					return positions[player]
				end,
			})
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				positions[alice] = Vector3.new(0, 0, 0)
				local rejections, onReject = recorder()
				Hit:On(noop)
				Hit:Use(Guards.range(10, { onReject = onReject }))

				t:as(alice, function()
					Hit:Fire(Vector3.new(13, 0, 0)) -- 10 + 4 slack
					Hit:Fire(Vector3.new(15, 0, 0))
					Hit:Fire(Vector3.new(0 / 0, 0, 0))
				end)
				t:as(bob, function()
					Hit:Fire(Vector3.new(1, 0, 0)) -- no character
				end)
				-- Under Lune, Vector3s are userdata the harness compares by identity; compare by value here.
				t:expect(Hit):firedBy(alice, t.any):firedTimes(1)
				check.equal(t:deliveries(Hit)[1].args[1], Vector3.new(13, 0, 0))
				check.equal(rejections[1], `guards-Hit{made}: target out of range (15.0 studs, at most 10)`)
				check.equal(rejections[2], `guards-Hit{made}: invalid target`)
				check.equal(rejections[3], `guards-Hit{made}: no character`)
			end)
			Guards.resetConfiguration()
		end)

		test.case("slack can be set per guard, and arg picks the target", function()
			remotes()
			local positions: { [Player]: Vector3 } = {}
			Guards.configure({
				position = function(player: Player): Vector3?
					return positions[player]
				end,
			})
			Hydrogen.test({ players = 1 }, function(_t, alice)
				positions[alice] = Vector3.new(0, 0, 0)
				check.equal(Guards.inRange(alice, Vector3.new(11, 0, 0), 10, 0), false)
				check.equal(Guards.inRange(alice, Vector3.new(11, 0, 0), 10), true)
				check.equal(Guards.inRange(alice, "nowhere", 1000), false)

				local strict = Guards.range(10, { slack = 0, arg = 2 })
				local context = { name = "x", kind = "ClientEvent", direction = "incoming", payload = "event", player = alice } :: any
				check.equal(strict(context, "label", Vector3.new(10, 0, 0)), "label")
				check.equal(strict(context, "label", Vector3.new(11, 0, 0)), Hydrogen.DROP)
			end)
			Guards.resetConfiguration()
		end)

		test.case("the default lookup reads the character's HumanoidRootPart", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(_t, alice, bob)
				local function character(at: Vector3): Model
					local model = Instance.new("Model")
					local root = Instance.new("Part")
					root.Name = "HumanoidRootPart"
					root.CFrame = CFrame.new(at)
					root.Parent = model
					return model
				end
				;(alice :: any).Character = character(Vector3.new(10, 0, 0))
				;(bob :: any).Character = character(Vector3.new(10, 0, 20))

				check.equal(Guards.distance(alice, Vector3.new(13, 0, 0)), 3)
				check.equal(Guards.distance(alice, CFrame.new(10, 4, 0)), 4)
				check.equal(Guards.distance(alice, bob), 20)

				local part = Instance.new("Part")
				part.CFrame = CFrame.new(10, 0, 5)
				check.equal(Guards.distance(alice, part), 5)

				-- Lune's Models have no GetPivot and its Attachments no WorldPosition.
				local model = Instance.new("Model")
				local primary = Instance.new("Part")
				primary.CFrame = CFrame.new(10, 0, 7)
				primary.Parent = model
				model.PrimaryPart = primary
				check.equal(Guards.distance(alice, model), 7)
				local attachment = Instance.new("Attachment")
				attachment.CFrame = CFrame.new(0, 0, 2)
				attachment.Parent = part
				check.equal(Guards.distance(alice, attachment), 7)

				local none, why = Guards.distance(alice, { 1, 2, 3 })
				check.falsy(none)
				check.equal(why, "invalid target")
			end)
		end)
	end)

	test.suite("Guards timestamps", function()
		test.case("stamps within ping plus tolerance pass; old and future ones are dropped", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob", "Cara" } }, function(t, alice, bob, cara)
				local clock = t.clock :: Hydrogen.FakeClock
				local rejections, onReject = recorder()
				Cast:On(noop)
				Cast:Use(Guards.timestamp({ onReject = onReject }))

				clock:setServerOffset(-0.15, alice) -- behind by less than the 0.2 s tolerance
				clock:setServerOffset(-0.5, bob) -- backdating
				clock:setServerOffset(0.3, cara) -- ahead of the server
				for _, player in { alice, bob, cara } do
					t:as(player, function()
						Cast:Fire(Clock.serverNow())
					end)
				end

				t:expect(Cast):firedBy(alice, t.any):firedTimes(1)
				check.equal(rejections[1], `guards-Cast{made}: timestamp too old (0.50s, at most 0.20s)`)
				check.equal(rejections[2], `guards-Cast{made}: timestamp from the future (0.30s ahead)`)
			end)
		end)

		test.case("the window grows with the player's ping, up to maxPing", function()
			remotes()
			local pings: { [Player]: number } = {}
			Guards.configure({
				ping = function(player: Player): number?
					return pings[player]
				end,
			})
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				local clock = t.clock :: Hydrogen.FakeClock
				pings[alice] = 0.4
				pings[bob] = 5 -- lag-switching: capped at maxPing
				check.equal(Guards.ping(alice), 0.4)
				local rejections, onReject = recorder()
				Cast:On(noop)
				Cast:Use(Guards.timestamp({ maxPing = 1, onReject = onReject }))

				clock:setServerOffset(-0.5)
				t:as(alice, function()
					Cast:Fire(Clock.serverNow()) -- 0.5 old, at most 0.6
				end)
				clock:setServerOffset(-2)
				t:as(bob, function()
					Cast:Fire(Clock.serverNow()) -- 2 old, at most 1.2
				end)

				t:expect(Cast):firedBy(alice, t.any):firedTimes(1)
				check.equal(rejections[1], `guards-Cast{made}: timestamp too old (2.00s, at most 1.20s)`)
			end)
			Guards.resetConfiguration()
		end)

		test.case("configure sets the default cap; a guard's own maxPing wins", function()
			remotes()
			Guards.configure({
				ping = function(_player: Player): number?
					return 5
				end,
				maxPing = 2,
			})
			Hydrogen.test({ players = 1 }, function(_t, alice)
				local context = { name = "x", kind = "ClientEvent", direction = "incoming", payload = "event", player = alice } :: any
				local stamp = Clock.serverNow() - 2
				check.equal(Guards.timestamp()(context, stamp), stamp) -- 2 old, at most 2.2
				check.equal(Guards.timestamp({ maxPing = 1 })(context, stamp), Hydrogen.DROP) -- at most 1.2
				Guards.resetConfiguration()
				Guards.configure({
					ping = function(_player: Player): number?
						return 5
					end,
				})
				check.equal(Guards.timestamp()(context, stamp), Hydrogen.DROP) -- back to the 1 s default
			end)
			Guards.resetConfiguration()
		end)

		test.case("ping reads GetNetworkPing, and an unknown or broken ping counts as 0", function()
			remotes()
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(_t, alice, bob)
				check.equal(Guards.ping(alice), 0) -- fake players have no GetNetworkPing
				;(bob :: any).GetNetworkPing = function(): number
					return 0.12
				end
				check.equal(Guards.ping(bob), 0.12)

				Guards.configure({
					ping = function(_player: Player): number?
						error("ping exploded")
					end,
				})
				check.equal(Guards.ping(bob), 0)
				Guards.configure({
					ping = function(_player: Player): number?
						return 0 / 0
					end,
				})
				check.equal(Guards.ping(bob), 0)
			end)
			Guards.resetConfiguration()
		end)

		test.case("arg and timestamp pick the stamp; anything but a finite number is invalid", function()
			remotes()
			Hydrogen.test({ players = 1 }, function(_t, alice)
				local context = { name = "x", kind = "ClientEvent", direction = "incoming", payload = "event", player = alice } :: any
				local now = Clock.serverNow()

				local second = Guards.timestamp({ arg = 2 })
				check.equal(second(context, "label", now), "label")
				check.equal(second(context, "label", now - 1), Hydrogen.DROP)
				check.equal(second(context, "label", 0 / 0), Hydrogen.DROP)
				check.equal(second(context, "label", math.huge), Hydrogen.DROP)
				check.equal(second(context, "label", "soon"), Hydrogen.DROP)

				local field = Guards.timestamp({
					timestamp = function(_player: Player, action: any): any
						return action.at
					end,
				})
				local action = { at = now }
				check.equal(field(context, action), action)
				check.equal(field(context, { at = now + 1 }), Hydrogen.DROP)
			end)
		end)

		test.case("bad options error at the call", function()
			check.is_false(pcall(Guards.timestamp, { arg = 0 } :: any))
			check.is_false(pcall(Guards.timestamp, { tolerance = -1 } :: any))
			check.is_false(pcall(Guards.timestamp, { maxPing = 0 / 0 } :: any))
			check.is_false(pcall(Guards.timestamp, { future = math.huge } :: any))
			check.is_false(pcall(Guards.timestamp, { timestamp = 5 } :: any))
			check.is_false(pcall(Guards.configure, { ping = 0.1 } :: any))
			check.is_false(pcall(Guards.configure, { maxPing = -1 } :: any))
			return nil
		end)
	end)

	test.suite("Guards predicates and composition", function()
		test.case("check gets the raw arguments and can give a reason", function()
			remotes()
			Hydrogen.test({ players = 1 }, function(t, alice)
				local rejections, onReject = recorder()
				Cast:On(noop)
				Cast:Use(Guards.check(function(_player: Player, amount: any): (boolean, string?)
					if type(amount) ~= "number" then
						return false, "amount must be a number"
					end
					return amount <= 100, "too much"
				end, { onReject = onReject }))

				Cast:Fire(50)
				Cast:Fire(500)
				t:expect(Cast):firedBy(alice, 50):firedTimes(1)
				check.equal(rejections[1], `guards-Cast{made}: too much`)
			end)
		end)

		test.case("a predicate that errors rejects and warns", function()
			remotes()
			Hydrogen.test({ players = 1 }, function(t)
				Cast:On(noop)
				Cast:Use(Guards.check(function(): (boolean, string?)
					error("boom")
				end))
				Cast:Fire(1)
				t:expect(Cast):notFired()
				t:expectWarning(`Guards.check predicate failed on guards-Cast{made}`)
			end)
		end)

		test.case("all uses no cooldown when another guard rejects", function()
			remotes()
			local fireball = Guards.cooldown(5)
			Hydrogen.test({ players = 1 }, function(t, alice)
				Guards.invalidate()
				Cast:On(noop)
				-- The cooldown comes first, the failing guard after it: still no charge is spent.
				Cast:Use(Guards.all(fireball:guard(), Guards.role("g-owner")))
				Cast:Fire(1)
				t:expect(Cast):notFired()
				check.equal(fireball:ready(alice), true)
			end)
		end)

		test.case("any lets staff skip a cooldown", function()
			remotes()
			local fireball = Guards.cooldown(5, { name = "Fireball" })
			Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
				owners = { alice.UserId }
				Guards.invalidate()
				local rejections, onReject = recorder()
				Cast:On(noop)
				Cast:Use(Guards.any(Guards.role("g-owner"), fireball:guard({ onReject = onReject })))

				t:as(alice, function()
					Cast:Fire(1)
					Cast:Fire(2)
				end)
				t:as(bob, function()
					Cast:Fire(3)
					Cast:Fire(4)
				end)
				t:expect(Cast):firedTimes(3):firedBy(bob, 3)
				check.equal(fireball:ready(alice), true)
				check.equal(fireball:ready(bob), false)
				-- The last guard's reason is the one sent.
				check.equal(rejections[1], `guards-Cast{made}: Fireball is on cooldown (5.0s left)`)
			end)
			owners = {}
		end)

		test.case("guards only look at what the server receives from players", function()
			remotes()
			Hydrogen.test({ players = 1 }, function(t, alice)
				local deny = Guards.check(function(): (boolean, string?)
					return false
				end)
				Notify:Use(deny)
				Notify:On(noop)
				Notify:Fire(alice, "hello")
				t:expect(Notify):firedTo(alice, "hello")
			end)
		end)

		test.case("onReject hooks that fail are warned and the message still drops", function()
			remotes()
			Hydrogen.test({ players = 1 }, function(t)
				local seen, record = recorder()
				local remove = Guards.onReject(record)
				Cast:On(noop)
				Cast:Use(Guards.check(function(): (boolean, string?)
					return false, "nope"
				end, {
					onReject = function()
						error("hook exploded")
					end,
				}))
				Cast:Fire(1)
				remove()
				Cast:Fire(2)

				t:expect(Cast):notFired()
				check.equal(#seen, 1)
				check.equal(seen[1], `guards-Cast{made}: nope`)
				t:expectWarning(`Guards onReject failed for guards-Cast{made}`)
			end)
		end)

		test.case("combinators only take guards", function()
			remotes()
			local ok, err = pcall(function()
				Guards.all(function() end :: any)
			end)
			check.equal(ok, false)
			check.not_nil(string.find(tostring(err), "Guards.all expects guards made by Hydrogen.Guards", 1, true))
			check.equal(Guards.isGuard(Guards.role("g-owner")), true)
			check.equal(Guards.isGuard(noop), false)
		end)
	end)
end
