--!strict

-- Hydrogen.Commands under Hydrogen.test: parsing, permissions, errors, the network round trip,
-- rate limiting, built-ins and autocomplete. The console UI and chat binding need a real client
-- and are checked in Studio.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Runtime = require("../src/Network/Runtime")

local Commands = Hydrogen.Commands
local Client = Commands.Client
local gt = Hydrogen.gt

local function texts(result: Hydrogen.CommandResult): string
	local lines = {}
	for _, line in result.output do
		table.insert(lines, line.text)
	end
	return table.concat(lines, "\n")
end

local function has(haystack: string, needle: string): boolean
	return string.find(haystack, needle, 1, true) ~= nil
end

local function expectHas(haystack: string, needle: string)
	if not has(haystack, needle) then
		error(`expected {string.format("%q", haystack)} to contain {string.format("%q", needle)}`, 2)
	end
end

local function registered(name: string): boolean
	return Runtime.RegisteredNames[name] == true
end

return function()
	local removers: { () -> () } = {}

	-- Registrations are VM-wide; each test removes its own.
	local function register(name: string, spec: Hydrogen.CommandSpec)
		table.insert(removers, Commands.register(name, spec))
	end

	test.on_test_enter(function()
		Commands.configure({})
	end)

	test.on_test_leave(function()
		for _, remove in removers do
			remove()
		end
		table.clear(removers)
		Commands.configure({})
	end)

	test.suite("Commands", function()
		test.case("nothing is registered on the network until the system is added", function()
			check.is_false(registered("Hydrogen/Commands/Run"))
			Hydrogen.test({ players = 1 }, function()
				check.is_false(registered("Hydrogen/Commands/Run"))
			end)
			Hydrogen.test({ systems = { Commands }, players = 1 }, function(t)
				check.is_true(registered("Hydrogen/Commands/Run"))
				check.is_true(registered("Hydrogen/Commands/Output"))
				check.is_true(registered("Hydrogen/Commands/Catalog"))
				t:expectNoWarnings()
			end)
		end)

		test.case("typed arguments reach run and a returned string is the reply", function()
			local got: { any } = {}
			register("give", {
				args = { Commands.player(), gt.string(), gt.number({ integer = true }) },
				run = function(ctx, target: Player, item: string, count: number): string
					got = { ctx.player, target, item, count, ctx.command, ctx.alias }
					return `Gave {count} {item} to {target.Name}`
				end,
			})
			Hydrogen.test({ systems = { Commands }, players = { "Alice", "Bob" } }, function(_t, alice, bob)
				local result = Commands.execute(alice, "/give bo sword 5")
				check.is_true(result.ok)
				check.equal(result.status, "ok")
				check.equal(result.command, "give")
				check.equal(got[1], alice)
				check.equal(got[2], bob)
				check.equal(got[3], "sword")
				check.equal(got[4], 5)
				check.equal(got[6], "give")
				check.equal(texts(result), "Gave 5 sword to Bob")
				check.equal(result.output[1].kind, "info")
			end)
		end)

		test.case("unknown commands suggest the closest one", function()
			register("give", { run = function() end })
			Hydrogen.test({ systems = { Commands }, players = 1 }, function(_t, player)
				local result = Commands.execute(player, "gvie sword")
				check.is_false(result.ok)
				check.equal(result.status, "unknown")
				expectHas(texts(result), `Unknown command "gvie". Did you mean "give"?`)
				expectHas(texts(result), `Type "help" for a list.`)
				check.equal(result.output[1].kind, "error")
				check.equal(Commands.execute(player, "   ").status, "empty")
			end)
		end)

		test.case("argument errors say which argument and why", function()
			register("give", {
				args = {
					Commands.player({ name = "target" }),
					Commands.named("item", gt.string()),
					Commands.named("count", gt.number({ integer = true, range = "[1, 99]" })),
				},
				run = function() end,
			})
			Hydrogen.test({ systems = { Commands }, players = { "Alice" } }, function(_t, alice)
				local bad = Commands.execute(alice, "give alice sword lots")
				check.equal(bad.status, "invalid")
				expectHas(texts(bad), `Bad argument 3 (count) for give: expected a whole number from 1 to 99, got "lots".`)
				expectHas(texts(bad), "Usage: give <target> <item> <count>")

				expectHas(texts(Commands.execute(alice, "give alice sword 1.5")), "expected a whole number from 1 to 99, got 1.5")
				expectHas(texts(Commands.execute(alice, "give alice sword 500")), "got 500")
				expectHas(texts(Commands.execute(alice, "give zed sword 1")), `Bad argument 1 (target) for give: no player matches "zed"`)
				expectHas(texts(Commands.execute(alice, "give alice")), "Missing argument 2 (item) for give.")
				expectHas(texts(Commands.execute(alice, "give alice sword 1 extra")), "Too many arguments for give: it takes 3, got 4.")
			end)
		end)

		test.case("player arguments match partial names, display names, me, all and others", function()
			local seen: any = nil
			register("one", {
				args = { Commands.player() },
				run = function(_ctx, target: Player)
					seen = target
				end,
			})
			register("many", {
				args = { Commands.players() },
				run = function(_ctx, targets: { Player })
					seen = targets
				end,
			})
			Hydrogen.test({ systems = { Commands }, players = { "Alice", "Alan", "Bob" } }, function(_t, alice, alan, bob)
				(bob :: any).DisplayName = "Builder"
				Commands.execute(alice, "one ali")
				check.equal(seen, alice)
				Commands.execute(alice, "one BUIL")
				check.equal(seen, bob)
				Commands.execute(alice, "one me")
				check.equal(seen, alice)
				Commands.execute(alice, "one alan")
				check.equal(seen, alan)

				local ambiguous = Commands.execute(alice, "one al")
				expectHas(texts(ambiguous), `"al" matches Alice, Alan; type more of the name`)
				expectHas(texts(Commands.execute(alice, "one all")), `expected one player, but "all" matches 3`)

				Commands.execute(alice, "many others")
				check.equal(#seen, 2)
				check.equal(seen[1], alan)
				check.equal(seen[2], bob)
				Commands.execute(alice, "many all")
				check.equal(#seen, 3)
				Commands.execute(alice, "many me,bob,ME")
				check.equal(#seen, 2)
				check.equal(seen[1], alice)
				check.equal(seen[2], bob)
			end)
		end)

		test.case("optional, text, rest, enum and boolean arguments", function()
			local seen: { any } = {}
			register("say", {
				args = { Commands.optional(Commands.integer({ name = "times" }), 1), Commands.text({ name = "message" }) },
				run = function(_ctx, times: number, message: string)
					seen = { times, message }
				end,
			})
			register("sum", {
				args = { Commands.rest(gt.number()) },
				run = function(_ctx, values: { number }): string
					local total = 0
					for _, value in values do
						total += value
					end
					return tostring(total)
				end,
			})
			register("mode", {
				args = { Commands.enum({ "easy", "normal", "hard" }), Commands.optional(Commands.boolean()) },
				run = function(_ctx, mode: string, hardcore: boolean?)
					seen = { mode, hardcore }
				end,
			})
			register("pick", {
				args = { gt.union(gt.literal("red"), gt.literal("blue")) :: any, gt.optional(gt.number()) },
				run = function(_ctx, color: string, amount: number?)
					seen = { color, amount }
				end,
			})
			Hydrogen.test({ systems = { Commands }, players = 1 }, function(_t, player)
				Commands.execute(player, `say 3 hello   there "friend"`)
				check.equal(seen[1], 3)
				check.equal(seen[2], `hello   there "friend"`)
				-- Not a number, so the optional count is left out and the words are the message.
				Commands.execute(player, `say hello there`)
				check.equal(seen[1], 1)
				check.equal(seen[2], "hello there")
				Commands.execute(player, "say 2 hi")
				check.equal(seen[1], 2)
				check.equal(seen[2], "hi")

				check.equal(texts(Commands.execute(player, "sum 1 2 3.5")), "6.5")
				expectHas(texts(Commands.execute(player, "sum")), "Missing argument 1 (number) for sum.")
				expectHas(texts(Commands.execute(player, "sum 1 x")), "Bad argument 1 (number) for sum")

				Commands.execute(player, "mode HA yes")
				check.equal(seen[1], "hard")
				check.equal(seen[2], true)
				Commands.execute(player, "mode normal")
				check.equal(seen[1], "normal")
				check.equal(seen[2], nil)
				expectHas(texts(Commands.execute(player, "mode impossible")), `expected one of easy, normal, hard, got "impossible"`)

				Commands.execute(player, "pick b 4")
				check.equal(seen[1], "blue")
				check.equal(seen[2], 4)
				Commands.execute(player, "pick red")
				check.equal(seen[1], "red")
				check.equal(seen[2], nil)
			end)
		end)

		test.case("permissions: default denies, admins and custom resolvers allow", function()
			register("ban", { permission = "admin", run = function()
				return "banned"
			end })
			register("open", { run = function()
				return "open"
			end })
			Hydrogen.test({ systems = { Commands }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				local denied = Commands.execute(alice, "ban")
				check.equal(denied.status, "denied")
				check.equal(texts(denied), `You don't have permission to use "ban".`)
				check.is_true(Commands.execute(alice, "open").ok)
				check.is_false(Commands.can(alice, "ban"))

				Commands.configure({ admins = { alice.UserId } })
				check.is_true(Commands.execute(alice, "ban").ok)
				check.equal(Commands.execute(bob, "ban").status, "denied")

				local asked: { any } = {}
				Commands.configure({
					permissions = function(player, permission, command)
						asked = { player, permission, command }
						return player == bob
					end,
				})
				check.is_true(Commands.execute(bob, "ban").ok)
				check.equal(asked[2], "admin")
				check.equal(asked[3], "ban")
				check.equal(Commands.execute(alice, "ban").status, "denied")

				Commands.configure({
					permissions = function(): boolean
						error("roles not loaded")
					end,
				})
				check.equal(Commands.execute(bob, "ban").status, "denied")
				t:expectWarning("permission resolver failed for Bob")
			end)
		end)

		test.case("a permission can be a function of the player", function()
			register("vip", {
				permission = function(player: Player): boolean
					return player.Name == "Bob"
				end,
				run = function() end,
			})
			Hydrogen.test({ systems = { Commands }, players = { "Alice", "Bob" } }, function(_t, alice, bob)
				check.is_true(Commands.execute(bob, "vip").ok)
				check.equal(Commands.execute(alice, "vip").status, "denied")
			end)
		end)

		test.case("ctx:fail replies with the message; other errors are warned and hidden", function()
			register("fails", {
				run = function(ctx)
					ctx:reply("working")
					ctx:fail("Not enough coins")
				end,
			})
			register("breaks", {
				run = function()
					error("nil index somewhere")
				end,
			})
			Hydrogen.test({ systems = { Commands }, players = 1 }, function(t, player)
				local failed = Commands.execute(player, "fails")
				check.equal(failed.status, "failed")
				check.equal(texts(failed), "working\nNot enough coins")
				check.equal(failed.output[2].kind, "error")

				local broken = Commands.execute(player, "breaks")
				check.equal(broken.status, "failed")
				check.equal(texts(broken), "breaks failed with an error.")
				t:expectWarning("Command breaks failed for Player1")
				t:expectWarning("nil index somewhere")
			end)
		end)

		test.case("register rejects bad specs with clear errors", function()
			local function errorOf(fn: () -> ()): string
				local ok, err = pcall(fn)
				check.is_false(ok)
				return tostring(err)
			end
			expectHas(errorOf(function()
				Commands.register("two words", { run = function() end })
			end), "command names and aliases are single words")
			expectHas(errorOf(function()
				Commands.register("x", {} :: any)
			end), "the spec needs run = function(ctx, ...) end")
			expectHas(errorOf(function()
				Commands.register("x", { args = { Commands.text(), gt.number() }, run = function() end })
			end), "takes the rest of the line, so it must be the last")
			expectHas(errorOf(function()
				Commands.register("x", { args = { 5 :: any }, run = function() end })
			end), "argument 1 is not an argument")

			register("teleport", { aliases = { "tp" }, run = function() end })
			expectHas(errorOf(function()
				Commands.register("TP", { run = function() end })
			end), `"tp" is already an alias of command "teleport"`)
		end)

		test.case("unregistering removes the command and its aliases", function()
			local remove = Commands.register("temp", { aliases = { "t" }, run = function() end })
			Hydrogen.test({ systems = { Commands }, players = 1 }, function(_t, player)
				check.is_true(Commands.execute(player, "t").ok)
				remove()
				remove()
				check.equal(Commands.execute(player, "temp").status, "unknown")
				check.equal(Commands.execute(player, "t").status, "unknown")
			end)
		end)

		test.case("help lists only what the player may run", function()
			register("give", { description = "Give an item", args = { Commands.player(), gt.string() }, run = function() end })
			register("secret", { hidden = true, run = function() end })
			register("ban", { permission = "admin", run = function() end })
			Hydrogen.test({ systems = { Commands }, players = 1 }, function(_t, player)
				local list = texts(Commands.execute(player, "help"))
				expectHas(list, "give <player> <string> - Give an item")
				expectHas(list, "help [command]")
				check.is_false(has(list, "secret"))
				check.is_false(has(list, "ban"))
				check.is_false(has(list, "kick"))

				local one = texts(Commands.execute(player, "cmds give"))
				expectHas(one, "give <player> <string>")
				expectHas(one, "Give an item")
				expectHas(texts(Commands.execute(player, "help ban")), `No command named "ban"`)
				-- Hidden commands still run for players allowed to.
				check.is_true(Commands.execute(player, "secret").ok)
			end)
		end)

		test.case("kick removes players; a game command shadows a built-in", function()
			Hydrogen.test({ systems = { Commands }, players = { "Admin", "Griefer" } }, function(t, admin, griefer)
				Commands.configure({ admins = { admin.UserId } })
				local result = Commands.execute(admin, "kick grief being rude")
				check.equal(texts(result), "Kicked Griefer.")
				check.equal(#t:players(), 1)
				check.equal(t:players()[1], admin)
				check.is_true(table.find(t:players(), griefer) == nil)

				register("help", { run = function()
					return "custom help"
				end })
				check.equal(texts(Commands.execute(admin, "help")), "custom help")
				-- The built-in's aliases still work.
				expectHas(texts(Commands.execute(admin, "cmds")), "Commands:")

				Commands.configure({ help = false, kick = false })
				check.equal(Commands.execute(admin, "kick admin").status, "unknown")
				check.equal(Commands.execute(admin, "cmds").status, "unknown")
			end)
		end)

		test.case("over the network: output returns to the caller only", function()
			register("whoami", {
				run = function(ctx)
					return `You are {ctx.player.Name}`
				end,
			})
			Hydrogen.test({ systems = { Commands, Client }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				t:as(alice, function()
					Client.run("whoami")
				end)
				check.equal(t:as(alice, function()
					local output = Client.output()
					return output[#output].text
				end), "You are Alice")
				check.equal(t:as(bob, function()
					return #Client.output()
				end), 0)

				t:as(bob, function()
					Client.run("nope")
				end)
				local last = t:as(bob, function()
					local output = Client.output()
					return output[#output]
				end)
				check.equal(last.kind, "error")
				expectHas(last.text, `Unknown command "nope"`)
				t:expectNoWarnings()
			end)
		end)

		test.case("each client gets its own command list and autocomplete", function()
			register("give", { aliases = { "g" }, description = "Give an item", args = { Commands.player(), Commands.enum({ "sword", "shield" }), Commands.integer() }, run = function() end })
			register("ban", { permission = "admin", args = { Commands.players() }, run = function() end })
			Hydrogen.test({ systems = { Commands, Client }, players = { "Alice", "Bob" } }, function(t, alice, bob)
				Commands.configure({ admins = { alice.UserId } })
				t:advance(0)
				local aliceNames = t:as(alice, function()
					local names = {}
					for _, info in Client.commands() do
						table.insert(names, info.name)
					end
					return table.concat(names, ",")
				end)
				check.equal(aliceNames, "ban,give,help,kick")
				local bobNames = t:as(bob, function()
					local names = {}
					for _, info in Client.commands() do
						table.insert(names, info.name)
					end
					return table.concat(names, ",")
				end)
				check.equal(bobNames, "give,help")

				t:as(bob, function()
					local names = Client.complete("")
					check.equal(#names.suggestions, 2)
					local g = Client.complete("/g")
					check.equal(g.suggestions[1].text, "/give ")
					check.equal(g.suggestions[1].detail, "Give an item")
					check.equal(g.usage, "give <player> <choice> <integer>")

					local item = Client.complete("give me sw")
					check.equal(#item.suggestions, 1)
					check.equal(item.suggestions[1].text, "give me sword ")
					check.equal((item.arg :: Hydrogen.CommandArgInfo).name, "choice")

					local target = Client.complete("give ")
					check.equal(target.suggestions[1].label, "me")
					check.equal((target.arg :: Hydrogen.CommandArgInfo).type, "player")

					local helpArg = Client.complete("help gi")
					check.equal(helpArg.suggestions[1].text, "help give ")
					check.equal(#Client.complete("help b").suggestions, 0)
				end)

				-- Permissions changed elsewhere (a role system): refresh resends the lists.
				Commands.configure({ admins = { bob.UserId } })
				Commands.refresh(bob)
				t:advance(0)
				check.equal(t:as(bob, function()
					return #Client.commands()
				end), 4)
			end)
		end)

		test.case("the network rate limit and length cap answer the sender", function()
			local runs = 0
			register("ping", {
				run = function()
					runs += 1
				end,
			})
			Hydrogen.test({ systems = { Commands, Client }, players = 1 }, function(t)
				Commands.configure({ rateLimit = { perSecond = 1, burst = 2 }, maxLength = 20 })
				for _ = 1, 5 do
					Client.run("ping")
				end
				check.equal(runs, 2)
				local limited = 0
				for _, line in Client.output() do
					if has(line.text, "too fast") then
						limited += 1
					end
				end
				check.equal(limited, 1)

				t:advance(1)
				Client.run("ping")
				check.equal(runs, 3)

				t:advance(5)
				Client.run(`ping {string.rep("x", 30)}`)
				check.equal(runs, 3)
				local output = Client.output()
				expectHas(output[#output].text, "too long (35 characters; the limit is 20)")
			end)
		end)

		test.case("a player leaving while their command yields", function()
			local finished = false
			register("slow", {
				run = function(ctx)
					Hydrogen.Clock.wait(5)
					finished = true
					ctx:reply("done")
				end,
			})
			Hydrogen.test({ systems = { Commands, Client }, players = { "Alice" } }, function(t, alice)
				Client.run("slow")
				t:leave(alice)
				t:advance(5)
				check.is_true(finished)
				t:expectNoWarnings()
			end)
		end)

		test.case("commands sent after shutdown are ignored", function()
			local runs = 0
			register("ping", {
				run = function()
					runs += 1
				end,
			})
			Hydrogen.test({ systems = { Commands, Client }, players = 1 }, function(t)
				Client.run("ping")
				check.equal(runs, 1)
				local app: any = t.app
				app:stop()
				-- The loopback is still open, but the system stopped.
				pcall(Client.run, "ping")
				check.equal(runs, 1)
			end)
		end)

		test.case("the docs' network example", function()
			Hydrogen.test({ systems = { Commands, Client }, players = { "Alice" } }, function(t, alice)
				t:as(alice, function()
					Client.run("help")
					local output = Client.output()
					check.is_true(string.find(output[#output].text, "Commands:", 1, true) ~= nil)
					check.equal(Client.complete("he").suggestions[1].text, "help ")
				end)
				t:expectNoWarnings()
			end)
		end)

		test.case("an error in an argument's parse is warned and reported", function()
			register("odd", {
				args = {
					Commands.arg({
						name = "thing",
						parse = function(_text: string): (boolean, any)
							error("parser bug")
						end,
					}),
				},
				run = function() end,
			})
			Hydrogen.test({ systems = { Commands }, players = 1 }, function(t, player)
				local result = Commands.execute(player, "odd x")
				check.equal(result.status, "invalid")
				expectHas(texts(result), `Bad argument 1 (thing) for odd: "x" couldn't be read.`)
				t:expectWarning("parser bug")
			end)
		end)
	end)
end
