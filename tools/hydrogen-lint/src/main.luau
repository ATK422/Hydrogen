--!strict

-- Entry point: `pesde x atk422/hydrogen_lint -- [directory] [flags]`.
--
-- The lint engine ships inside Hydrogen (src/Testing/Lint), so it always matches the network
-- runtime the game uses. This launcher finds the project's installed Hydrogen and runs its engine.

local process = require("@lune/process")
local stdio = require("@lune/stdio")

local Locate = require("./locate")

local args = process.args
local located, problem = Locate.engine(args, process.cwd)
if not located then
	if table.find(args, "--json") then
		stdio.write(`\{"format": 1, "ok": false, "fatal": {require("@lune/serde").encode("json", problem)}\}\n`)
	else
		stdio.ewrite(`error: {problem}\n`)
	end
	process.exit(2)
end

local Cli = Locate.load(located :: string)
process.exit(Cli.main(args))
