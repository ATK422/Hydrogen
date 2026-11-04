--!strict

-- Tests for the generator. From tools/create-hydrogen:
--   lune run test/run          unit tests (no network, no tools needed)
--   lune run test/run e2e      also generates a real project, installs it, builds it with
--                              Rojo and runs its tests (needs rokit, pesde and git)

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")

local Cli = require("../src/cli")
local Names = require("../src/names")
local Options = require("../src/options")
local Prompts = require("../src/prompts")
local Render = require("../src/render")
local Scaffold = require("../src/scaffold")
local Tools = require("../src/tools")
local Wizard = require("../src/wizard")

---------------------------------------------------------------------------------------------
-- A very small harness

local passed, failed = 0, 0
local failures: { string } = {}
local currentGroup = ""

local function group(name: string, body: () -> ())
	currentGroup = name
	body()
end

local function test(name: string, body: () -> ())
	local ok, err = xpcall(body, debug.traceback)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, `{currentGroup} > {name}\n    {err}`)
	end
end

local function show(value: any): string
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function equal(actual: any, expected: any, label: string?)
	if actual ~= expected then
		error(`{label or "value"}: expected {show(expected)}, got {show(actual)}`, 2)
	end
end

local function truthy(value: any, label: string)
	if not value then
		error(`expected {label}`, 2)
	end
end

local function contains(haystack: string, needle: string, label: string?)
	if not string.find(haystack, needle, 1, true) then
		error(`{label or "text"} should contain {show(needle)}, got:\n{haystack}`, 2)
	end
end

local function lacks(haystack: string, needle: string, label: string?)
	if string.find(haystack, needle, 1, true) then
		error(`{label or "text"} shouldn't contain {show(needle)}, got:\n{haystack}`, 2)
	end
end

local function errors(body: () -> (), needle: string)
	local ok, err = pcall(body)
	if ok then
		error(`expected an error containing {show(needle)}`, 2)
	end
	contains(tostring(err), needle, "error")
end

---------------------------------------------------------------------------------------------
-- Helpers

local tempRoot = string.gsub(process.env.TEMP or process.env.TMPDIR or "/tmp", "\\", "/")
local tempCount = 0
local tempDirs: { string } = {}

local function tempDir(): string
	tempCount += 1
	local path = `{tempRoot}/create_hydrogen_test_{os.time()}_{math.random(1, 1e6)}_{tempCount}`
	fs.writeDir(path)
	table.insert(tempDirs, path)
	return path
end

local function answers(overrides: { [string]: any }?): Options.Answers
	local base: { [string]: any } = {
		directory = "my-game",
		name = "my-game",
		package = "atk/my_game",
		description = "A test game",
		author = "ATK",
		license = "MIT",
		examples = true,
		ci = true,
		tools = { stylua = true, selene = true, luau_lsp = true },
		kit = {},
		git = true,
		install = true,
		force = false,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base :: any
end

local function byPath(files: { Scaffold.File }): { [string]: string }
	local map = {}
	for _, file in files do
		map[file.path] = file.contents
	end
	return map
end

local function plan(overrides: { [string]: any }?, branch: string?): { [string]: string }
	local a = answers(overrides)
	return byPath(Scaffold.plan(a, Scaffold.vars(a, 2026, branch)))
end

type Call = { program: string, args: { string }, cwd: string? }

-- A Runner that pretends tools exist (or not) and records what was run.
local function fakeRunner(config: { [string]: any }?): (Tools.Runner, { Call })
	local settings = config or {}
	local calls: { Call } = {}
	local function run(program: string, args: { string }, cwd: string?, _inherit: boolean?): Tools.Result?
		table.insert(calls, { program = program, args = args, cwd = cwd })
		if settings.missing and table.find(settings.missing, program) then
			return nil
		end
		local command = program .. " " .. table.concat(args, " ")
		local custom = settings.results and settings.results[command]
		if custom then
			return custom
		end
		if args[1] == "--version" then
			return { ok = true, code = 0, stdout = `{program} 1.0.0\n`, stderr = "" }
		end
		if command == "git config user.name" then
			return { ok = true, code = 0, stdout = "Test Author\n", stderr = "" }
		end
		if command == "git config --global init.defaultBranch" or command == "git rev-parse --show-toplevel" then
			return { ok = false, code = 1, stdout = "", stderr = "" }
		end
		return { ok = true, code = 0, stdout = "", stderr = "" }
	end
	return run, calls
end

local function env(cwd: string, overrides: { [string]: any }?): (Wizard.Env, { string })
	local output: { string } = {}
	local base: { [string]: any } = {
		cwd = cwd,
		prompter = Prompts.scripted({}),
		run = (fakeRunner()),
		out = function(text: string)
			table.insert(output, text)
		end,
		interactive = false,
		year = 2026,
	}
	for key, value in overrides or {} do
		base[key] = value
	end
	return base :: any, output
end

local function flags(args: { string }): Cli.Flags
	local parsed, err = Cli.parse(args)
	assert(parsed, err)
	return parsed
end

local function ran(calls: { Call }, command: string): boolean
	for _, call in calls do
		if call.program .. " " .. table.concat(call.args, " ") == command then
			return true
		end
	end
	return false
end

local function skippedText(outcome: Wizard.Outcome): string
	return table.concat(outcome.skipped, "\n")
end

---------------------------------------------------------------------------------------------

group("Names.validateProject", function()
	test("accepts ordinary names", function()
		for _, name in { "my-game", "MyGame", "game_2", "v1.2", "a" } do
			local ok, err = Names.validateProject(name)
			equal(ok, true, `{name} ({err})`)
		end
	end)

	test("rejects names that can't be folders everywhere", function()
		local cases = {
			[""] = "empty",
			["my game"] = "no spaces",
			["-game"] = "start with a letter",
			[".game"] = "start with a letter",
			["game."] = "end with '.'",
			["con"] = "reserved",
			["CON.txt"] = "reserved",
			["lpt1"] = "reserved",
			["a/b"] = "only letters",
			["日本"] = "only letters",
			[string.rep("a", 65)] = "64",
		}
		for name, reason in cases do
			local ok, err = Names.validateProject(name)
			equal(ok, false, name)
			contains(err :: string, reason, `error for {show(name)}`)
		end
	end)
end)

group("Names.validatePackage", function()
	test("accepts pesde names", function()
		for _, name in { "atk/my_game", "studio_x/a", "abc/game2" } do
			local ok, err = Names.validatePackage(name)
			equal(ok, true, `{name} ({err})`)
		end
	end)

	test("rejects what pesde rejects", function()
		local cases = {
			["game"] = "scope/name",
			["ab/game"] = "3-32",
			["atk/My-Game"] = "a-z, 0-9",
			["atk/_game"] = "start or end",
			["atk/123"] = "only digits",
			[`atk/{string.rep("a", 33)}`] = "1-32",
			["a/b/c"] = "scope/name",
		}
		for name, reason in cases do
			local ok, err = Names.validatePackage(name)
			equal(ok, false, name)
			contains(err :: string, reason, `error for {name}`)
		end
	end)

	test("derives a valid default from the project and author", function()
		equal(Names.defaultPackage("My-Cool.Game", "ATK 422"), "atk_422/my_cool_game")
		equal(Names.defaultPackage("x", "Al"), "game/x") -- scope too short
		equal(Names.defaultPackage("123", nil), "game/game") -- all digits
		for _, project in { "My-Cool.Game", string.rep("ab-", 30), "9lives" } do
			local name = Names.defaultPackage(project, "Some Author")
			local ok, err = Names.validatePackage(name)
			equal(ok, true, `{name} ({err})`)
		end
	end)

	test("basename ignores trailing slashes and handles both separators", function()
		equal(Names.basename("games/my-game/"), "my-game")
		equal(Names.basename("C:\\games\\my-game"), "my-game")
	end)
end)

group("Cli.parse", function()
	test("reads the directory, values and switches", function()
		local parsed = flags({ "my-game", "--author", "ATK", "--license=Apache-2.0", "--no-ci", "--examples", "-y" })
		equal(parsed.directory, "my-game")
		equal(parsed.author, "ATK")
		equal(parsed.license, "Apache-2.0")
		equal(parsed.ci, false)
		equal(parsed.examples, true)
		equal(parsed.yes, true)
		equal(parsed.git, nil)
	end)

	test("ignores a -- separator", function()
		equal(flags({ "--", "my-game" }).directory, "my-game")
	end)

	test("reads tool lists", function()
		local parsed = flags({ "--tools", "stylua,luau-lsp" })
		local tools = parsed.tools :: { [string]: boolean }
		equal(tools.stylua, true)
		equal(tools.selene, false)
		equal(tools.luau_lsp, true)
		local none = flags({ "--tools=none" }).tools :: { [string]: boolean }
		equal(none.stylua, false)
	end)

	test("reports mistakes", function()
		local cases = {
			{ { "--tools", "prettier" }, "unknown value 'prettier'" },
			{ { "--colour" }, "unknown option '--colour'" },
			{ { "-x" }, "unknown option '-x'" },
			{ { "--author" }, "--author needs a value" },
			{ { "--author", "--yes" }, "--author needs a value" },
			{ { "a", "b" }, "unexpected argument 'b'" },
			{ { "--no-yes" }, "unknown option" },
			{ { "--kit", "data" }, "none are available yet" },
		}
		for _, case in cases do
			local parsed, err = Cli.parse(case[1] :: { string })
			equal(parsed, nil, table.concat(case[1] :: { string }, " "))
			contains(err :: string, case[2] :: string)
		end
	end)

	test("help lists the flags", function()
		local help = Cli.help()
		for _, flag in { "--name", "--package", "--license", "--tools", "--no-git", "--no-install", "--yes", "--force" } do
			contains(help, flag, "help")
		end
		lacks(help, "LICENSES", "help")
		lacks(help, "KIT_LINE", "help")
	end)
end)

group("Render", function()
	test("substitutes variables", function()
		equal(Render.text("name = {{name}}!", { name = "x" }), "name = x!")
	end)

	test("keeps or drops blocks, and standalone tags take their line", function()
		local source = "a\n{{#if on}}\nb\n{{/if}}\n{{#unless on}}\nc\n{{/unless}}\nd\n"
		equal(Render.text(source, { on = true }), "a\nb\nd\n")
		equal(Render.text(source, { on = false }), "a\nc\nd\n")
	end)

	test("handles inline and nested blocks", function()
		equal(Render.text("x{{#if a}} and y{{/if}}.", { a = false }), "x.")
		local nested = "{{#if a}}\n1\n{{#if b}}\n2\n{{/if}}\n3\n{{/if}}\n"
		equal(Render.text(nested, { a = true, b = false }), "1\n3\n")
		equal(Render.text(nested, { a = false, b = true }), "")
	end)

	test("errors on template mistakes", function()
		errors(function()
			Render.text("{{nope}}", {})
		end, "unknown variable 'nope'")
		errors(function()
			Render.text("{{#if a}}x", { a = true })
		end, "never closed")
		errors(function()
			Render.text("{{/if}}", {})
		end, "doesn't close")
		errors(function()
			Render.text("{{#if name}}x{{/if}}", { name = "text" })
		end, "unknown flag")
		errors(function()
			Render.text("{{#each x}}{{/each}}", { x = true })
		end, "unknown block")
	end)

	test("maps template paths", function()
		local path, isTemplate = Render.path("dot-github/workflows/ci.yml.tmpl")
		equal(path, ".github/workflows/ci.yml")
		equal(isTemplate, true)
		path, isTemplate = Render.path("src/dot-gitkeep")
		equal(path, "src/.gitkeep")
		equal(isTemplate, false)
	end)
end)

group("Scaffold.plan", function()
	test("the default project has everything", function()
		local files = plan()
		for _, path in {
			".gitignore",
			".gitattributes",
			".luaurc",
			".vscode/settings.json",
			".vscode/extensions.json",
			".github/workflows/ci.yml",
			"default.project.json",
			"pesde.toml",
			"rokit.toml",
			"README.md",
			"LICENSE",
			"stylua.toml",
			".styluaignore",
			"selene.toml",
			"src/server/Main.server.luau",
			"src/client/Main.client.luau",
			"src/server/Systems/Greeter.luau",
			"src/server/Systems/Visits.luau",
			"src/client/Systems/Greetings.luau",
			"src/shared/Network/Greeting.luau",
			"test/run.luau",
			"test/Roblox.luau",
			"test/Greeter.test.luau",
		} do
			truthy(files[path], path)
		end
		contains(files["src/server/Main.server.luau"], "app:addNetwork(ReplicatedStorage.Shared.Network)")
		contains(files["src/client/Main.client.luau"], 'WaitForChild("Network")')
		contains(files["pesde.toml"], 'hydrogen = { name = "atk422/hydrogen", version = "^0.4.0" }')
		contains(files.LICENSE, "Copyright (c) 2026 ATK")
	end)

	test("every combination renders valid JSON and TOML with nothing left over", function()
		local combos = {}
		for _, examples in { true, false } do
			for _, ci in { true, false } do
				for _, toolSet in { { stylua = true, selene = true, luau_lsp = true }, { stylua = false, selene = false, luau_lsp = false }, { stylua = true, selene = false, luau_lsp = false }, { stylua = false, selene = true, luau_lsp = true } } do
					for _, license in { "MIT", "Apache-2.0", "MPL-2.0", "None" } do
						table.insert(combos, { examples = examples, ci = ci, tools = toolSet, license = license })
					end
				end
			end
		end
		for _, combo in combos do
			local label = serde.encode("json", combo)
			local files = plan(combo)
			for path, contents in files do
				lacks(contents, "{{", `{path} in {label}`)
				if string.match(path, "%.json$") then
					local ok, err = pcall(serde.decode, "json", contents)
					truthy(ok, `{path} parses as JSON in {label}: {err}`)
				elseif string.match(path, "%.toml$") then
					local ok, err = pcall(serde.decode, "toml", contents)
					truthy(ok, `{path} parses as TOML in {label}: {err}`)
				end
			end
			equal(files.LICENSE ~= nil, combo.license ~= "None", `LICENSE in {label}`)
		end
	end)

	test("tool choices drive rokit.toml, configs, editor and CI", function()
		local none = plan({ ci = true, tools = { stylua = false, selene = false, luau_lsp = false } })
		local rokit = serde.decode("toml", none["rokit.toml"]).tools
		truthy(rokit.rojo and rokit.pesde and rokit.lune, "rojo, pesde and lune are always pinned")
		equal(rokit.stylua, nil, "stylua pin")
		equal(none["stylua.toml"], nil, "stylua.toml")
		equal(none["selene.toml"], nil, "selene.toml")
		lacks(none[".github/workflows/ci.yml"], "stylua")
		lacks(none[".github/workflows/ci.yml"], "luau-lsp")
		lacks(none[".vscode/extensions.json"], "stylua")

		local all = plan()
		local pinned = serde.decode("toml", all["rokit.toml"]).tools
		truthy(pinned.stylua and pinned.selene and pinned["luau-lsp"], "all tools pinned")
		contains(all[".github/workflows/ci.yml"], "stylua --check src test")
		contains(all[".github/workflows/ci.yml"], "selene src test")
		contains(all[".github/workflows/ci.yml"], "luau-lsp analyze")
		contains(all[".vscode/extensions.json"], "JohnnyMorganz.stylua")
	end)

	test("without examples it has starter systems and no network", function()
		local files = plan({ examples = false })
		truthy(files["src/server/Systems/Game.luau"], "server starter")
		truthy(files["src/client/Systems/Interface.luau"], "client starter")
		equal(files["test/Greeter.test.luau"], nil, "example test")
		equal(files["src/shared/Network/Greeting.luau"], nil, "example network")
		contains(files["src/server/Main.server.luau"], "-- app:addNetwork")
		truthy(files["test/run.luau"], "the test runner is always there")
	end)

	test("escapes TOML strings and names the CI branch", function()
		local files = plan({ description = 'Say "hi" \\ bye', author = 'A "B"' }, "trunk")
		local manifest = serde.decode("toml", files["pesde.toml"])
		equal(manifest.description, 'Say "hi" \\ bye')
		equal(manifest.authors[1], 'A "B"')
		equal(manifest.private, true)
		contains(files[".github/workflows/ci.yml"], 'branches: ["trunk"]')
	end)

	test("leaves authors and license out when empty", function()
		local manifest = serde.decode("toml", plan({ author = "", license = "None" })["pesde.toml"])
		equal(manifest.authors, nil)
		equal(manifest.license, nil)
	end)

	test("the generated pesde name is valid for every default", function()
		local manifest = serde.decode("toml", plan()["pesde.toml"])
		local ok, err = Names.validatePackage(manifest.name)
		equal(ok, true, `{manifest.name} ({err})`)
	end)

	test("writes LF even from a CRLF checkout", function()
		local root = tempDir()
		fs.writeDir(root .. "/base")
		fs.writeDir(root .. "/starter")
		fs.writeFile(root .. "/base/plain.txt", "one\r\ntwo\r\n")
		fs.writeFile(root .. "/base/named.txt.tmpl", "{{#if examples}}\r\nx\r\n{{/if}}\r\n{{name}}\r\n")
		local a = answers({ examples = false, ci = false, tools = {}, license = "None" })
		local files = byPath(Scaffold.plan(a, Scaffold.vars(a, 2026), root))
		equal(files["plain.txt"], "one\ntwo\n")
		equal(files["named.txt"], "my-game\n")
	end)

	test("the tree lists directories before their files", function()
		local tree = Scaffold.tree({ { path = "a/b.txt", contents = "" }, { path = "c.txt", contents = "" } })
		equal(tree, "a/\n  b.txt\nc.txt")
	end)
end)

group("Scaffold.checkTarget", function()
	test("allows a missing or empty directory", function()
		local dir = tempDir()
		equal(Scaffold.checkTarget(dir, false), nil)
		equal(Scaffold.checkTarget(dir .. "/new", false), nil)
	end)

	test("refuses a directory with files unless forced", function()
		local dir = tempDir()
		fs.writeFile(dir .. "/notes.txt", "keep me")
		local problem = Scaffold.checkTarget(dir, false) :: string
		contains(problem, "isn't empty")
		contains(problem, "notes.txt")
		contains(problem, "--force")
		equal(Scaffold.checkTarget(dir, true), nil)
	end)

	test("refuses a file", function()
		local dir = tempDir()
		fs.writeFile(dir .. "/file", "")
		contains(Scaffold.checkTarget(dir .. "/file", false) :: string, "is a file")
	end)
end)

group("Wizard.answers", function()
	test("--yes uses defaults and git's user.name", function()
		local e = env(tempDir())
		local a = Wizard.answers(flags({ "cool-game", "--yes" }), e)
		equal(a.name, "cool-game")
		equal(a.directory, "cool-game")
		equal(a.author, "Test Author")
		equal(a.package, "test_author/cool_game")
		equal(a.license, "MIT")
		equal(a.examples, true)
		equal(a.ci, true)
		equal(a.tools.selene, true)
	end)

	test("the project name comes from the directory, including .", function()
		local cwd = tempDir() .. "/Space-Race"
		fs.writeDir(cwd)
		local a = Wizard.answers(flags({ ".", "--yes" }), (env(cwd)))
		equal(a.name, "Space-Race")
		equal(a.package, "test_author/space_race")
	end)

	test("a directory that can't be a project name needs --name with --yes", function()
		errors(function()
			Wizard.answers(flags({ "my game", "--yes" }), (env(tempDir())))
		end, "Pass --name")
		local a = Wizard.answers(flags({ "my game", "--name", "my-game", "--yes" }), (env(tempDir())))
		equal(a.directory, "my game")
		equal(a.name, "my-game")
	end)

	test("invalid flag values are errors", function()
		errors(function()
			Wizard.answers(flags({ "--name", "con", "--yes" }), (env(tempDir())))
		end, "reserved")
		errors(function()
			Wizard.answers(flags({ "x", "--package", "Bad/Name", "--yes" }), (env(tempDir())))
		end, "--package")
		errors(function()
			Wizard.answers(flags({ "x", "--license", "GPL", "--yes" }), (env(tempDir())))
		end, "choose one of")
	end)

	test("asks the questions in order and uses the answers", function()
		local prompter, asked = Prompts.scripted({
			"space-race", -- name
			"", -- description: default
			"Someone", -- author
			"", -- package: default
			2, -- license: the second option (default first, then the rest)
			false, -- examples
			2, -- tools: let me pick
			{ 1 }, -- just StyLua
			false, -- CI
		})
		local a = Wizard.answers(flags({}), (env(tempDir(), { prompter = prompter })))
		equal(#asked, 9)
		equal(a.name, "space-race")
		equal(a.description, Options.defaults.description)
		equal(a.author, "Someone")
		equal(a.package, "someone/space_race")
		equal(a.license, "Apache-2.0")
		equal(a.examples, false)
		equal(a.tools.stylua, true)
		equal(a.tools.selene, false)
		equal(a.ci, false)
	end)

	test("flags skip their questions", function()
		local prompter, asked = Prompts.scripted({ "", "" }) -- description, package
		Wizard.answers(
			flags({ "my-game", "--author", "A", "--license", "MIT", "--no-examples", "--tools", "none", "--ci" }),
			(env(tempDir(), { prompter = prompter }))
		)
		equal(#asked, 2)
	end)
end)

group("Wizard.run", function()
	test("writes the project, inits git, installs and commits", function()
		local cwd = tempDir()
		local run, calls = fakeRunner()
		local outcome = Wizard.run(flags({ "game", "--yes" }), (env(cwd, { run = run })))
		equal(#outcome.skipped, 0, skippedText(outcome))
		equal(outcome.committed, true)
		truthy(fs.isFile(cwd .. "/game/default.project.json"), "files written")
		truthy(ran(calls, "git init --initial-branch=main"), "git init")
		truthy(ran(calls, "rokit install"), "rokit install")
		truthy(ran(calls, "pesde install"), "pesde install")
		truthy(ran(calls, "git add -A"), "git add")
		lacks(table.concat((function()
			local list = {}
			for _, call in calls do
				table.insert(list, call.program .. " " .. table.concat(call.args, " "))
			end
			return list
		end)(), "\n"), "rokit trust", "commands") -- never changes Rokit's trust list
	end)

	test("missing tools are reported with how to install them", function()
		local cwd = tempDir()
		local run = fakeRunner({ missing = { "git", "rokit", "pesde" } })
		local outcome = Wizard.run(flags({ "game", "--yes" }), (env(cwd, { run = run })))
		local text = skippedText(outcome)
		contains(text, "git: not found")
		contains(text, "git-scm.com")
		contains(text, "Rokit isn't installed")
		contains(text, "rokit self-install")
		contains(text, "pesde isn't installed")
		contains(text, "docs.pesde.dev")
		equal(outcome.committed, false)
		truthy(fs.isFile(cwd .. "/game/pesde.toml"), "files are still written")
	end)

	test("--no-git and --no-install run nothing", function()
		local run, calls = fakeRunner()
		local outcome = Wizard.run(flags({ "game", "--yes", "--no-git", "--no-install" }), (env(tempDir(), { run = run })))
		for _, call in calls do
			truthy(call.args[1] == "config" or call.args[1] == "--version", `only lookups, not {call.program} {table.concat(call.args, " ")}`)
		end
		contains(skippedText(outcome), "--no-install")
	end)

	test("a non-empty directory is refused, then allowed with --force", function()
		local cwd = tempDir()
		fs.writeDir(cwd .. "/game")
		fs.writeFile(cwd .. "/game/keep.txt", "mine")
		errors(function()
			Wizard.run(flags({ "game", "--yes", "--no-git", "--no-install" }), (env(cwd)))
		end, "--force")
		Wizard.run(flags({ "game", "--yes", "--no-git", "--no-install", "--force" }), (env(cwd)))
		equal(fs.readFile(cwd .. "/game/keep.txt"), "mine", "other files are left alone")
		truthy(fs.isFile(cwd .. "/game/rokit.toml"), "files written")
	end)

	test("interactively, a non-empty directory is a question", function()
		local cwd = tempDir()
		fs.writeDir(cwd .. "/game")
		fs.writeFile(cwd .. "/game/keep.txt", "mine")
		local args = { "game", "--description", "d", "--author", "a", "--package", "abc/game", "--license", "MIT", "--examples", "--tools", "none", "--ci", "--no-git", "--no-install" }
		local no = Prompts.scripted({ false })
		errors(function()
			Wizard.run(flags(args), (env(cwd, { prompter = no })))
		end, "isn't empty")
		local yes = Prompts.scripted({ true })
		Wizard.run(flags(args), (env(cwd, { prompter = yes })))
		truthy(fs.isFile(cwd .. "/game/rokit.toml"), "written after yes")
	end)

	test("inside another repository it doesn't make a nested one", function()
		local run, calls = fakeRunner({
			results = { ["git rev-parse --show-toplevel"] = { ok = true, code = 0, stdout = "C:/work/monorepo\n", stderr = "" } },
		})
		local outcome = Wizard.run(flags({ "game", "--yes", "--no-install" }), (env(tempDir(), { run = run })))
		contains(skippedText(outcome), "already inside the repository at C:/work/monorepo")
		equal(ran(calls, "git init --initial-branch=main"), false, "git init")
		equal(outcome.committed, false)
	end)

	test("a global default branch is used for git and CI", function()
		local cwd = tempDir()
		local run, calls = fakeRunner({
			results = { ["git config --global init.defaultBranch"] = { ok = true, code = 0, stdout = "trunk\n", stderr = "" } },
		})
		Wizard.run(flags({ "game", "--yes", "--no-install" }), (env(cwd, { run = run })))
		truthy(ran(calls, "git init --initial-branch=trunk"), "git init on trunk")
		contains(fs.readFile(cwd .. "/game/.github/workflows/ci.yml"), 'branches: ["trunk"]')
	end)

	test("a failed commit explains how to set a git identity", function()
		local run = fakeRunner({
			results = {
				["git commit --quiet -m Create project with create_hydrogen"] = { ok = false, code = 128, stdout = "", stderr = "Author identity unknown" },
			},
		})
		local outcome = Wizard.run(flags({ "game", "--yes", "--no-install" }), (env(tempDir(), { run = run })))
		local text = skippedText(outcome)
		contains(text, "Author identity unknown")
		contains(text, "git config --global user.email")
		equal(outcome.committed, false)
	end)

	test("untrusted Rokit tools are reported, not trusted for you", function()
		local run = fakeRunner({
			results = {
				["rokit install"] = { ok = false, code = 1, stdout = "", stderr = "The following tool has not been marked as trusted: JohnnyMorganz/luau-lsp" },
			},
		})
		local outcome = Wizard.run(flags({ "game", "--yes", "--no-git" }), (env(tempDir(), { run = run })))
		local text = skippedText(outcome)
		contains(text, "aren't trusted yet")
		contains(text, "rokit trust rojo-rbx/rojo pesde-pkg/pesde lune-org/lune JohnnyMorganz/StyLua Kampfkarren/selene JohnnyMorganz/luau-lsp")
	end)

	test("a failed pesde install says how to retry", function()
		local run = fakeRunner({
			results = { ["pesde install"] = { ok = false, code = 1, stdout = "", stderr = "network down" } },
		})
		local outcome = Wizard.run(flags({ "game", "--yes", "--no-git" }), (env(tempDir(), { run = run })))
		contains(skippedText(outcome), "pesde install failed: network down")
	end)
end)

group("Tools", function()
	test("version skips pesde's update box and colors", function()
		local run = function(): Tools.Result?
			return { ok = true, code = 0, stdout = "\n┃  update available! 0.7.2 → 0.7.4\n┃\n\27[1mpesde 0.7.2\27[0m\n", stderr = "" }
		end
		equal(Tools.version(run, "pesde"), "pesde 0.7.2")
	end)

	test("exec returns nil for a program that isn't installed", function()
		equal(Tools.exec("create-hydrogen-no-such-tool", { "--version" }), nil)
	end)
end)

---------------------------------------------------------------------------------------------
-- End to end: a real project with real tools.

if process.args[1] == "e2e" then
	group("end to end", function()
		local cwd = tempDir()
		local outcome: Wizard.Outcome? = nil

		test("generates, installs and commits", function()
			local e = env(cwd, { run = Tools.exec })
			outcome = Wizard.run(flags({ "e2e-game", "--yes", "--author", "Hydrogen Tests" }), e)
			local result = outcome :: Wizard.Outcome
			equal(#result.skipped, 0, skippedText(result))
		end)

		local project = cwd .. "/e2e-game"
		local function check(label: string, program: string, args: { string })
			test(label, function()
				local result = Tools.exec(program, args, project)
				truthy(result, `{program} is installed`)
				local r = result :: Tools.Result
				truthy(r.ok, `{program} {table.concat(args, " ")} succeeds:\n{r.stdout}\n{r.stderr}`)
			end)
		end

		check("rojo build", "rojo", { "build", "default.project.json", "--output", "build.rbxl" })
		check("pesde run test", "pesde", { "run", "test" })
		check("stylua --check", "stylua", { "--check", "src", "test" })
		check("selene", "selene", { "src", "test" })

		test("the commit has the project and the lockfile", function()
			local result = Tools.exec("git", { "ls-files" }, project) :: Tools.Result
			contains(result.stdout, "pesde.lock")
			contains(result.stdout, "src/server/Main.server.luau")
			lacks(result.stdout, "roblox_packages")
		end)
	end)
end

---------------------------------------------------------------------------------------------

for _, dir in tempDirs do
	pcall(fs.removeDir, dir)
end

for _, failure in failures do
	print(`FAIL {failure}\n`)
end
print(`{passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
