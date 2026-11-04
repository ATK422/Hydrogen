--!strict

-- Tests for the launcher. From tools/hydrogen-lint: lune run test/run
-- The lint itself is tested with Hydrogen's suite (test/Lint.luau at the repository root).

local fs = require("@lune/fs")
local process = require("@lune/process")

local Locate = require("../src/locate")

local passed, failed = 0, 0
local failures: { string } = {}

local function test(name: string, body: () -> ())
	local ok, err = (xpcall :: any)(body, function(message: any): string
		return debug.traceback(tostring(message))
	end)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, `{name}\n    {err}`)
	end
end

local function equal(actual: any, expected: any)
	if actual ~= expected then
		error(`expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

local function contains(text: string?, part: string)
	if text == nil or not string.find(text, part, 1, true) then
		error(`expected "{tostring(text)}" to contain "{part}"`, 2)
	end
end

local here = string.gsub(process.cwd, "\\", "/")
local repository = `{here}/../..`
local scratch = `{here}/test/.scratch`

local function project(name: string, version: string?, engine: boolean): string
	local root = `{scratch}/{name}`
	fs.writeDir(`{root}/roblox_packages`)
	if version then
		local package = `{root}/roblox_packages/.pesde/atk422+hydrogen/{version}/hydrogen`
		fs.writeDir(`{package}/src/Testing/Lint`)
		if engine then
			fs.writeFile(`{package}/src/Testing/Lint/Cli.luau`, "return { main = function() return 0 end }\n")
		end
		fs.writeFile(`{root}/roblox_packages/hydrogen.luau`, `return require("./.pesde/atk422+hydrogen/{version}/hydrogen/src")\n`)
	end
	return root
end

if fs.isDir(scratch) then
	fs.removeDir(scratch)
end

test("parse finds the directory and --hydrogen among the other flags", function()
	local directory, hydrogen = Locate.parse({ "--", "--json", "--ignore", "no-handler", "games/obby", "--hydrogen", "../h" })
	equal(directory, "games/obby")
	equal(hydrogen, "../h")
	local _, inline = Locate.parse({ "--hydrogen=../x", "--wait=1" })
	equal(inline, "../x")
end)

test("finds the engine through the link file pesde writes", function()
	local root = project("installed", "0.5.0", true)
	local engine = Locate.engine({ root }, here)
	contains(engine, "atk422+hydrogen/0.5.0/hydrogen/src/Testing/Lint/Cli.luau")
end)

test("says to update Hydrogen when the installed one has no lint", function()
	local root = project("old", "0.4.0", false)
	local engine, problem = Locate.engine({ root }, here)
	equal(engine, nil)
	contains(problem, "Hydrogen (0.4.0) has no network lint")
end)

test("says to run pesde install when there is no Hydrogen", function()
	local root = project("empty", nil, false)
	local engine, problem = Locate.engine({ root }, here)
	equal(engine, nil)
	contains(problem, "pesde install")
end)

test("--hydrogen picks a package folder or its src", function()
	contains(Locate.engine({ "--hydrogen", repository }, here), "src/Testing/Lint/Cli.luau")
	contains(Locate.engine({ "--hydrogen", `{repository}/src` }, here), "Testing/Lint/Cli.luau")
	local engine, problem = Locate.engine({ "--hydrogen", scratch }, here)
	equal(engine, nil)
	contains(problem, "has no lint engine")
end)

test("loads the real engine and lints a fixture game", function()
	local engine = Locate.engine({ "--hydrogen", repository }, here) :: string
	local Cli = Locate.load(engine)
	local written = {}
	local code = Cli.main({ `{repository}/test/Fixtures/Lint/clean`, "--sourcemap", "sourcemap.json", "--wait", "0", "--no-color" }, {
		write = function(text: string)
			table.insert(written, text)
		end,
		ewrite = function(text: string)
			table.insert(written, text)
		end,
	})
	equal(code, 0)
	contains(table.concat(written), "No network problems found.")
end)

fs.removeDir(scratch)

print(`{passed} passed, {failed} failed`)
for _, failure in failures do
	print(`FAIL {failure}`)
end
process.exit(if failed == 0 then 0 else 1)
