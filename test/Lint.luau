--!strict

-- The network lint against fixture games in test/Fixtures/Lint, each a small Rojo project with a
-- committed sourcemap. Regenerate one with `rojo sourcemap default.project.json --output sourcemap.json`
-- from its folder after changing its layout.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local serde = (require :: any)("@lune/serde")

local Cli = require("../src/Testing/Lint/Cli")
local Lint = require("../src/Testing/Lint/Lint")
local Report = require("../src/Testing/Lint/Report")

type Diagnostic = Lint.Diagnostic

local reports: { [string]: Lint.Report } = {}

-- Booting a fixture loads Hydrogen twice, so each one runs once and its tests share the report.
local function lint(fixture: string): Lint.Report
	local report = reports[fixture]
	if not report then
		report = Lint.run({ root = `test/Fixtures/Lint/{fixture}`, sourcemap = "sourcemap.json", wait = 0 })
		reports[fixture] = report
	end
	return report
end

local function find(report: Lint.Report, rule: string, name: string?): { Diagnostic }
	local found = {}
	for _, diagnostic in report.diagnostics do
		if diagnostic.rule == rule and (name == nil or diagnostic.name == name) then
			table.insert(found, diagnostic)
		end
	end
	return found
end

local function one(report: Lint.Report, rule: string, name: string?): Diagnostic
	local found = find(report, rule, name)
	if #found ~= 1 then
		local all = {}
		for _, diagnostic in report.diagnostics do
			table.insert(all, `{diagnostic.rule} {diagnostic.name or "-"}: {diagnostic.message}`)
		end
		error(`expected one {rule} {name or ""}, found {#found}. Report:\n{table.concat(all, "\n")}`, 2)
	end
	return found[1]
end

local function contains(text: string?, part: string): boolean
	return text ~= nil and string.find(text, part, 1, true) ~= nil
end

local function sides(diagnostic: Diagnostic): string
	return table.concat(diagnostic.sides, ",")
end

-- Cli.main with its output captured.
local function cli(args: { string }): (number, string)
	local written = {}
	local code = Cli.main(args, {
		write = function(text: string)
			table.insert(written, text)
		end,
		ewrite = function(text: string)
			table.insert(written, text)
		end,
	})
	return code, table.concat(written)
end

return function()
	test.suite("Lint: a clean game", function()
		test.case("reports nothing and exits 0", function()
			local report = lint("clean")
			check.equal(#report.diagnostics, 0)
			check.equal(report.ok, true)
			check.equal(report.errors, 0)
		end)

		test.case("boots both sides and sees the same names", function()
			local report = lint("clean")
			check.equal(report.server.started, true)
			check.equal(report.client.started, true)
			check.equal(table.concat(report.server.names, " "), "GetCoins Greeted Ping SayHello Shop/Buy State/Coins State/Round")
			check.equal(table.concat(report.client.names, " "), table.concat(report.server.names, " "))
			check.equal(report.server.hash, report.client.hash)
		end)

		test.case("runs each side's scripts, and the client's from the player's copies", function()
			local report = lint("clean")
			check.equal(#report.server.scripts, 1)
			check.equal(report.server.scripts[1].instance, "ServerScriptService.Server.Main")
			check.equal(report.server.scripts[1].status, "finished")
			-- The client's start hook calls a function; with no real server it waits, as on a slow one.
			check.equal(report.client.scripts[1].instance, "StarterPlayer.StarterPlayerScripts.Client.Main")
			check.equal(report.client.addNetwork[1], "ReplicatedStorage.Shared.Network")
		end)

		test.case("keeps the game's output out of the report", function()
			local report = lint("clean")
			check.equal(table.find(report.client.output, "PlayerGui Player1") ~= nil, true)
		end)

		test.case("boots through engine APIs it doesn't emulate, and lists what it stood in for", function()
			local report = lint("clean")
			-- Hud:init uses UserInputService, TweenService and workspace.Map, which isn't in the project.
			check.equal(table.find(report.client.output, "Spawn 1") ~= nil, true)
			check.equal(table.find(report.client.missing, "Workspace.Map") ~= nil, true)
			check.equal(#report.server.missing, 0)
		end)
	end)

	test.suite("Lint: one-sided names", function()
		test.case("names a module clients can't see", function()
			local diagnostic = one(lint("one-sided"), "one-sided", "Kick")
			check.equal(diagnostic.severity, "error")
			check.equal(sides(diagnostic), "server")
			check.equal(diagnostic.locations[1].file, "src/server/Admin.luau")
			check.equal(diagnostic.locations[1].instance, "ServerScriptService.Server.Admin")
			check.equal(contains(diagnostic.fix, "clients can't see"), true)
		end)

		test.case("shows what each side passed to addNetwork", function()
			local diagnostic = one(lint("one-sided"), "one-sided", "Trade")
			check.equal(diagnostic.locations[1].file, "src/shared/Trading.luau")
			check.equal(contains(diagnostic.fix, "addNetwork on the server: ReplicatedStorage.Shared.Network, ReplicatedStorage.Shared.Trading; on the client: ReplicatedStorage.Shared.Network"), true)
		end)

		test.case("doesn't report names both sides have", function()
			local report = lint("one-sided")
			check.equal(#find(report, "one-sided", "Chat"), 0)
			check.equal(report.errors, 2)
		end)
	end)

	test.suite("Lint: duplicates", function()
		test.case("reports a name defined in two modules once, for both sides", function()
			local diagnostic = one(lint("duplicate"), "duplicate", "Ping")
			check.equal(sides(diagnostic), "server,client")
			check.equal(diagnostic.locations[1].file, "src/shared/Network.luau")
			check.equal(diagnostic.locations[2].file, "src/shared/Effects.luau")
		end)

		test.case("catches a namespace that collides with a State's event", function()
			local diagnostic = one(lint("duplicate"), "duplicate", "State/Coins")
			check.equal(contains(diagnostic.fix, "Hydrogen.State"), true)
			check.equal(diagnostic.locations[1].line, 6)
			check.equal(diagnostic.locations[2].line, 8)
		end)

		test.case("keeps checking after a duplicate, which would error at runtime", function()
			local report = lint("duplicate")
			check.equal(report.errors, 2)
			check.equal(#find(report, "runtime-warning"), 0)
			check.equal(#find(report, "script-error"), 0)
		end)
	end)

	test.suite("Lint: late registration", function()
		test.case("reports an object first required from a client start hook", function()
			local found = find(lint("late"), "late-registration", "Later")
			check.equal(#found, 2)
			local client = if found[1].sides[1] == "client" then found[1] else found[2]
			check.equal(client.locations[1].file, "src/shared/Lazy.luau")
			check.equal(client.locations[2].file, "src/client/Systems/Menu.luau")
		end)

		test.case("reports an object required after app:start() on the server", function()
			local found = find(lint("late"), "late-registration", "Later")
			local server = if found[1].sides[1] == "server" then found[1] else found[2]
			check.equal(server.locations[2].file, "src/server/Main.server.luau")
			check.equal(server.locations[2].line, 10)
		end)

		test.case("doesn't also call a late name one-sided", function()
			check.equal(#find(lint("late"), "one-sided"), 0)
		end)
	end)

	test.suite("Lint: mismatches", function()
		test.case("reports :Encode() on one side only", function()
			local diagnostic = one(lint("mismatch"), "encode-mismatch", "Score")
			check.equal(contains(diagnostic.message, "on the server only"), true)
		end)

		test.case("reports different schemas, showing both", function()
			local diagnostic = one(lint("mismatch"), "schema-mismatch", "Move")
			check.equal(contains(diagnostic.message, "server number, client string"), true)
		end)

		test.case("reports a name that is a different kind on each side", function()
			local diagnostic = one(lint("mismatch"), "kind-mismatch", "Swap")
			check.equal(contains(diagnostic.message, "ServerEvent on the server but a ClientEvent on the client"), true)
			check.equal(diagnostic.locations[1].side, "server")
			check.equal(diagnostic.locations[2].side, "client")
		end)
	end)

	test.suite("Lint: other likely bugs", function()
		test.case("reports a serverFunction without its returns", function()
			local diagnostic = one(lint("functions"), "missing-returns", "Ask")
			check.equal(diagnostic.severity, "error")
			check.equal(diagnostic.locations[1].line, 6)
		end)

		test.case("reports a clientFunction without gt.returns as an error", function()
			local diagnostic = one(lint("functions"), "function-schema", "Query")
			check.equal(diagnostic.severity, "error")
		end)

		test.case("warns about bare schemas in a clientFunction", function()
			local diagnostic = one(lint("functions"), "function-schema", "Bare")
			check.equal(diagnostic.severity, "warning")
		end)

		test.case("warns when nothing on the receiving side listens", function()
			local diagnostic = one(lint("functions"), "no-handler", "Unheard")
			check.equal(sides(diagnostic), "client")
		end)

		test.case("warns about names that differ by case and reserved prefixes", function()
			local report = lint("functions")
			check.equal(#find(report, "similar-names"), 1)
			one(report, "reserved-prefix", "Hydrogen/Mine")
		end)

		test.case("leaves Hydrogen's own objects alone", function()
			local report = lint("clean")
			check.equal(#find(report, "no-handler"), 0)
			check.equal(#find(report, "reserved-prefix"), 0)
		end)
	end)

	test.suite("Lint: a game that doesn't boot", function()
		test.case("reports a script error with where it happened", function()
			local diagnostic = one(lint("broken"), "script-error")
			check.equal(sides(diagnostic), "client")
			check.equal(diagnostic.severity, "error")
			check.equal(diagnostic.locations[1].file, "src/client/Main.client.luau")
			check.equal(diagnostic.locations[1].line, 5)
		end)

		test.case("says a missing side may come from that error", function()
			local diagnostic = one(lint("broken"), "one-sided", "Hello")
			check.equal(contains(diagnostic.fix, "stopped booting early"), true)
		end)

		test.case("reports a State passed to addNetwork, which would never return", function()
			local diagnostic = one(lint("broken"), "addnetwork-hang")
			check.equal(diagnostic.locations[1].instance, "ReplicatedStorage.Shared.GameState")
			check.equal(contains(diagnostic.message, "Round"), true)
		end)

		test.case("passes Hydrogen's own warnings on", function()
			local diagnostic = one(lint("broken"), "runtime-warning")
			check.equal(contains(diagnostic.message, "addNetwork found no network objects in ReplicatedStorage.Shared.Empty"), true)
			check.equal(diagnostic.locations[1].file, "src/server/Main.server.luau")
		end)
	end)

	test.suite("Lint: options and output", function()
		test.case("ignore leaves rules out of the report and the counts", function()
			local report = Lint.run({
				root = "test/Fixtures/Lint/mismatch",
				sourcemap = "sourcemap.json",
				wait = 0,
				ignore = { "kind-mismatch", "encode-mismatch" },
			})
			check.equal(report.errors, 1)
			check.equal(report.diagnostics[1].rule, "schema-mismatch")
		end)

		test.case("text names the rule, the location and the fix", function()
			local text = Report.text(lint("one-sided"))
			check.equal(contains(text, `error[one-sided] on the server: ServerEvent "Kick" is registered on the server only`), true)
			check.equal(contains(text, "--> src/server/Admin.luau:7 (ServerScriptService.Server.Admin)"), true)
			check.equal(contains(text, "2 errors, 0 warnings"), true)
		end)

		test.case("JSON decodes and keeps empty lists as lists", function()
			local text = Report.json(lint("clean"))
			local decoded = serde.decode("json", text)
			check.equal(decoded.ok, true)
			check.equal(decoded.format, Lint.FORMAT)
			check.equal(contains(text, `"diagnostics": []`), true)
		end)
	end)

	test.suite("Lint: command line", function()
		test.case("exits 0 on a clean game and 1 on errors", function()
			local clean = cli({ "test/Fixtures/Lint/clean", "--sourcemap", "sourcemap.json", "--wait", "0", "--no-color" })
			check.equal(clean, 0)
			local code, output = cli({ "test/Fixtures/Lint/mismatch", "--sourcemap=sourcemap.json", "--wait=0", "--json" })
			check.equal(code, 1)
			check.equal(serde.decode("json", output).errors, 3)
		end)

		test.case("--strict fails on warnings too", function()
			local args = { "test/Fixtures/Lint/functions", "--sourcemap", "sourcemap.json", "--wait", "0", "--ignore", "missing-returns,function-schema" }
			check.equal((cli(args)), 0)
			table.insert(args, "--strict")
			check.equal((cli(args)), 1)
		end)

		test.case("exits 2 when it can't run", function()
			local code, output = cli({ "--frobnicate" })
			check.equal(code, 2)
			check.equal(contains(output, "unknown flag --frobnicate"), true)
			check.equal((cli({ "--ignore", "not-a-rule" })), 2)
			local missing, message = cli({ "test/Fixtures/Lint/nowhere", "--json" })
			check.equal(missing, 2)
			check.equal(serde.decode("json", message).ok, false)
		end)

		test.case("--help lists every rule", function()
			local code, output = cli({ "--help" })
			check.equal(code, 0)
			for _, rule in Lint.rules do
				check.equal(contains(output, rule.name), true)
			end
		end)
	end)
end
