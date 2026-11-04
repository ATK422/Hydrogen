--!strict

-- The command line: `pesde x atk422/hydrogen_lint -- [directory] [flags]` runs Cli.main.
-- Exit codes: 0 no errors, 1 errors found (or warnings with --strict), 2 the lint couldn't run.

local process = (require :: any)("@lune/process")
local stdio = (require :: any)("@lune/stdio")

local Lint = require("./Lint")
local Report = require("./Report")

export type Flags = {
	root: string,
	project: string?,
	sourcemap: string?,
	json: boolean,
	strict: boolean,
	verbose: boolean,
	color: boolean,
	wait: number?,
	ignore: { string },
	help: boolean,
}

export type Output = {
	write: (text: string) -> (),
	ewrite: (text: string) -> (),
}

local Cli = {}

Cli.VERSION = "0.1.0"

local VALUE_FLAGS = { project = true, sourcemap = true, ignore = true, wait = true, hydrogen = true }

function Cli.help(): string
	local rules = {}
	for _, rule in Lint.rules do
		table.insert(rules, `  {rule.name}{string.rep(" ", 18 - #rule.name)}{rule.severity}: {rule.summary}`)
	end
	return table.concat({
		"hydrogen-lint: checks a Hydrogen game's network before you playtest.",
		"It boots the server and the client under Lune and compares what each registers.",
		"",
		"Usage: pesde x atk422/hydrogen_lint -- [directory] [flags]",
		"",
		"  directory            the game's folder (default: the current one)",
		"  --project <file>     Rojo project file (default: default.project.json)",
		"  --sourcemap <file>   use this sourcemap instead of running `rojo sourcemap`",
		"  --json               print the report as JSON (for CI and agents)",
		"  --strict             exit 1 on warnings too",
		"  --ignore <rules>     leave rules out, comma-separated; repeatable",
		"  --wait <seconds>     let deferred code run this long after the scripts start (default 0.1)",
		"  --verbose            also print the game's output and Instances the lint stood in for",
		"  --no-color           plain text",
		"  --hydrogen <dir>     the Hydrogen package to use (default: the project's roblox_packages)",
		"  --help               this text",
		"",
		"Exit codes: 0 no errors, 1 errors (or warnings with --strict), 2 the lint couldn't run.",
		"",
		"Rules:",
		table.concat(rules, "\n"),
	}, "\n")
end

function Cli.parse(args: { string }): (Flags?, string?)
	local flags: Flags = {
		root = ".",
		project = nil,
		sourcemap = nil,
		json = false,
		strict = false,
		verbose = false,
		color = process.env.NO_COLOR == nil,
		wait = nil,
		ignore = {},
		help = false,
	}
	local positional = 0

	local index = 1
	while index <= #args do
		local arg = args[index]
		local name, inline = string.match(arg, "^%-%-([%w%-]+)=(.*)$")
		name = name or string.match(arg, "^%-%-([%w%-]+)$")

		if arg == "--" then
			-- pesde x and lune run may pass the separator through.
		elseif name then
			local value = inline
			if VALUE_FLAGS[name] and value == nil then
				index += 1
				value = args[index]
				if value == nil then
					return nil, `--{name} needs a value`
				end
			end

			if name == "project" then
				flags.project = value
			elseif name == "sourcemap" then
				flags.sourcemap = value
			elseif name == "ignore" then
				for rule in string.gmatch(value :: string, "[^,%s]+") do
					if not Lint.isRule(rule) then
						return nil, `--ignore: unknown rule {rule} (see --help for the list)`
					end
					table.insert(flags.ignore, rule)
				end
			elseif name == "wait" then
				local seconds = tonumber(value)
				if not seconds or seconds < 0 then
					return nil, `--wait needs a number of seconds, got {value}`
				end
				flags.wait = seconds
			elseif name == "hydrogen" then
				-- The launcher's flag; the engine is already the one it picked.
			elseif name == "json" then
				flags.json = true
			elseif name == "strict" then
				flags.strict = true
			elseif name == "verbose" then
				flags.verbose = true
			elseif name == "no-color" then
				flags.color = false
			elseif name == "help" then
				flags.help = true
			else
				return nil, `unknown flag --{name} (see --help)`
			end
		elseif arg == "-h" then
			flags.help = true
		elseif string.sub(arg, 1, 1) == "-" then
			return nil, `unknown flag {arg} (see --help)`
		else
			positional += 1
			if positional > 1 then
				return nil, `expected one directory, got {flags.root} and {arg}`
			end
			flags.root = arg
		end
		index += 1
	end

	return flags, nil
end

-- Runs the lint and prints the report. Returns the exit code instead of exiting, so tests and
-- the launcher decide.
function Cli.main(args: { string }, output: Output?): number
	local out: Output = output or {
		write = function(text: string)
			stdio.write(text)
		end,
		ewrite = function(text: string)
			stdio.ewrite(text)
		end,
	}

	local flags, problem = Cli.parse(args)
	if not flags then
		out.ewrite(`error: {problem}\n`)
		return 2
	end
	if flags.help then
		out.write(Cli.help() .. "\n")
		return 0
	end

	local ok, result = pcall(Lint.run, {
		root = flags.root,
		project = flags.project,
		sourcemap = flags.sourcemap,
		wait = flags.wait,
		ignore = flags.ignore,
	})
	if not ok then
		local message = tostring(result)
		if flags.json then
			out.write(`\{"format": {Lint.FORMAT}, "ok": false, "fatal": {(require :: any)("@lune/serde").encode("json", message)}\}\n`)
		else
			out.ewrite(`error: {message}\n`)
		end
		return 2
	end

	local report = result :: Lint.Report
	if flags.json then
		out.write(Report.json(report) .. "\n")
	else
		out.write(Report.text(report, { color = flags.color, verbose = flags.verbose }) .. "\n")
	end

	if report.errors > 0 or (flags.strict and report.warnings > 0) then
		return 1
	end
	return 0
end

return Cli
