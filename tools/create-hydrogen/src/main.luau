--!strict

-- Entry point: `pesde x atk422/create_hydrogen -- [directory] [options]`.

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Cli = require("./cli")
local Prompts = require("./prompts")
local Scaffold = require("./scaffold")
local Tools = require("./tools")
local Versions = require("./versions")
local Wizard = require("./wizard")

local function color(name: string, text: string): string
	return stdio.color(name :: any) .. text .. stdio.color("reset")
end

local flags, parseError = Cli.parse(process.args)
if not flags then
	stdio.ewrite(color("red", `error: {parseError}`) .. "\n")
	process.exit(2)
end
local parsed = flags :: Cli.Flags

if parsed.help then
	print(Cli.help())
	process.exit(0)
end
if parsed.version then
	print(`create_hydrogen {Versions.cli}`)
	process.exit(0)
end

print(color("cyan", "Hydrogen") .. " - new game\n")

local ok, result = pcall(Wizard.run, parsed, {
	cwd = process.cwd,
	prompter = Prompts.terminal,
	run = Tools.exec,
	out = function(text: string)
		stdio.write(stdio.style("dim") .. text .. stdio.style("reset"))
	end,
	interactive = not parsed.yes,
})

if not ok then
	stdio.ewrite("\n" .. color("red", `error: {result}`) .. "\n")
	process.exit(1)
end

local outcome = result :: Wizard.Outcome
print("\n" .. Scaffold.tree(outcome.files))

if #outcome.skipped > 0 then
	print("\n" .. color("yellow", "Not done:"))
	for _, note in outcome.skipped do
		print("  - " .. string.gsub(note, "\n", "\n    "))
	end
end

local answers = outcome.answers
if outcome.incomplete then
	print("\n" .. color("yellow", "Project created; finish the steps above.") .. " Then:\n")
else
	print("\n" .. color("green", "Done.") .. " Next:\n")
end
if answers.directory ~= "." then
	print(`  cd {answers.directory}`)
end
print("  code .                     open in VS Code (install the recommended extensions)")
print("  rojo serve                 sync into Studio with the Rojo plugin")
print("  pesde run test             run the tests in test/")
print("  rojo build -o game.rbxl    build a place file")
print("")

-- 3: the project is written, but a step it should have run was missing a tool or failed.
process.exit(if outcome.incomplete then 3 else 0)
