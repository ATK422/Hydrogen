--!strict

-- Command-line flags. parse() is pure: it turns argv into Flags or an error message.

local Options = require("./options")

export type Flags = {
	directory: string?,
	name: string?,
	package: string?,
	description: string?,
	author: string?,
	license: string?,
	examples: boolean?,
	ci: boolean?,
	agents: boolean?,
	tools: { [string]: boolean }?,
	kit: { [string]: boolean }?,
	git: boolean?,
	install: boolean?,
	force: boolean,
	yes: boolean,
	help: boolean,
	version: boolean,
}

local Cli = {}

local VALUE_FLAGS = {
	name = true,
	package = true,
	description = true,
	author = true,
	license = true,
	tools = true,
	kit = true,
}

local BOOLEAN_FLAGS = {
	examples = true,
	ci = true,
	agents = true,
	git = true,
	install = true,
}

-- "stylua,selene" -> { stylua = true, selene = true, luau_lsp = false }; "none" -> all false.
local function parseList(list: { Options.Choice }, value: string, flag: string): ({ [string]: boolean }?, string?)
	local chosen: { [string]: boolean } = {}
	for _, choice in list do
		chosen[choice.id] = false
	end
	if string.lower(value) == "none" or value == "" then
		return chosen, nil
	end
	for item in string.gmatch(value, "[^,%s]+") do
		local choice = Options.find(list, item)
		if not choice then
			local known = Options.ids(list)
			local hint = if #known > 0 then `choose from {table.concat(known, ", ")} or none` else "none are available yet"
			return nil, `--{flag}: unknown value '{item}' ({hint})`
		end
		chosen[choice.id] = true
	end
	return chosen, nil
end

function Cli.parse(args: { string }): (Flags?, string?)
	local flags: Flags = { force = false, yes = false, help = false, version = false }
	local raw = flags :: any
	local i = 1
	while i <= #args do
		local arg = args[i]
		i += 1

		if arg == "--" then
			-- `pesde x` and `lune run` pass a separator through on some setups; it means nothing here.
			continue
		elseif arg == "-h" or arg == "--help" then
			flags.help = true
		elseif arg == "-v" or arg == "--version" then
			flags.version = true
		elseif arg == "-y" or arg == "--yes" then
			flags.yes = true
		elseif arg == "-f" or arg == "--force" then
			flags.force = true
		elseif string.sub(arg, 1, 2) == "--" then
			local key, inline = string.match(arg, "^%-%-([^=]+)=(.*)$")
			key = key or string.sub(arg, 3)
			local name = string.gsub(key :: string, "-", "_")

			if VALUE_FLAGS[name] then
				local value = inline
				if value == nil then
					value = args[i]
					i += 1
					if value == nil or string.sub(value, 1, 2) == "--" then
						return nil, `--{key} needs a value`
					end
				end
				if name == "tools" or name == "kit" then
					local list = if name == "tools" then Options.tools else Options.kit
					local chosen, err = parseList(list, value, key)
					if not chosen then
						return nil, err
					end
					raw[name] = chosen
				else
					raw[name] = value
				end
			elseif BOOLEAN_FLAGS[name] and inline == nil then
				raw[name] = true
			elseif string.sub(name, 1, 3) == "no_" and BOOLEAN_FLAGS[string.sub(name, 4)] and inline == nil then
				raw[string.sub(name, 4)] = false
			else
				return nil, `unknown option '{arg}' (see --help)`
			end
		elseif string.sub(arg, 1, 1) == "-" and arg ~= "-" then
			return nil, `unknown option '{arg}' (see --help)`
		elseif flags.directory == nil then
			flags.directory = arg
		else
			return nil, `unexpected argument '{arg}': give one project directory`
		end
	end
	return flags, nil
end

function Cli.help(): string
	local licenses = {}
	for _, license in Options.licenses do
		table.insert(licenses, license.id)
	end
	local kitIds = table.concat(Options.ids(Options.kit), ", ")
	local kitLine = if #Options.kit > 0
		then "  --kit <list>             Hydrogen modules to set up: " .. kitIds .. " or none\n"
		else ""

	local text = [[
Create a new Roblox game with Hydrogen.

Usage:
  pesde x atk422/create_hydrogen -- [directory] [options]

The directory defaults to the project name. Use . for the current directory.
Anything you don't pass as a flag is asked for, unless you pass --yes.

Options:
  --name <name>            project name (default: the directory's name)
  --package <scope/name>   pesde package name (default: <author>/<name>)
  --description <text>     one-line description
  --author <name>          author (default: git config user.name)
  --license <id>           LICENSES (default: MIT)
  --examples, --no-examples
                           example systems, network module and test (default: on)
  --tools <list>           stylua, selene, luau-lsp or none (default: all three)
KIT_LINE  --ci, --no-ci            GitHub Actions workflow (default: on)
  --agents, --no-agents    AGENTS.md and CLAUDE.md for coding agents (default: on)
  --no-git                 don't run git init or make the first commit
  --no-install             don't run rokit install and pesde install
  -f, --force              write into a directory that isn't empty
  -y, --yes                use defaults for everything not given, ask nothing
  -h, --help               show this help
  -v, --version            show the version

Exit codes:
  0  done (steps you turned off with --no-git or --no-install don't count)
  1  nothing written: invalid value, directory not empty, or no terminal to ask in
  2  bad command line
  3  project written, but a tool was missing or a git/install step failed (see "Not done")

Examples:
  pesde x atk422/create_hydrogen
  pesde x atk422/create_hydrogen -- my-game
  pesde x atk422/create_hydrogen -- my-game --yes --no-ci --tools stylua
]]
	text = string.gsub(text, "LICENSES", table.concat(licenses, ", "))
	return (string.gsub(text, "KIT_LINE", kitLine))
end

return Cli
