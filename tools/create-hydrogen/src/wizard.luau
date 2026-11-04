--!strict

-- The whole flow: work out the answers (flags, then prompts or defaults), write the project,
-- then git init, install tools and packages, and commit. Side effects go through Env, so the
-- tests can run it against a temporary directory with scripted answers and fake tools.

local fs = require("@lune/fs")

local Cli = require("./cli")
local Names = require("./names")
local Options = require("./options")
local Prompts = require("./prompts")
local Scaffold = require("./scaffold")
local Tools = require("./tools")
local Versions = require("./versions")

export type Env = {
	-- The directory relative paths are resolved against.
	cwd: string,
	prompter: Prompts.Prompter,
	run: Tools.Runner,
	out: (text: string) -> (),
	-- Whether rokit's trust prompts can be answered (an interactive terminal).
	interactive: boolean,
	templateRoot: string?,
	year: number?,
}

export type Outcome = {
	directory: string,
	answers: Options.Answers,
	files: { Scaffold.File },
	-- Steps that didn't happen, with what to do instead.
	skipped: { string },
	committed: boolean,
	-- A step that should have run was missing a tool or failed (main exits with 3).
	incomplete: boolean,
}

local Wizard = {}

local function isAbsolute(path: string): boolean
	return string.match(path, "^%a:[/\\]") ~= nil or string.match(path, "^[/\\]") ~= nil
end

local function resolve(cwd: string, path: string): string
	path = string.gsub(path, "\\", "/")
	if isAbsolute(path) then
		return (string.gsub(path, "/+$", ""))
	end
	local base = string.gsub(string.gsub(cwd, "\\", "/"), "/+$", "")
	if path == "." or path == "./" then
		return base
	end
	return base .. "/" .. (string.gsub(string.gsub(path, "^%./", ""), "/+$", ""))
end

local function gitAuthor(env: Env): string
	local result = env.run("git", { "config", "user.name" }, env.cwd)
	if result and result.ok then
		return (string.gsub(result.stdout, "%s+$", ""))
	end
	return ""
end

local function check(validate: (string) -> (boolean, string?), value: string, flag: string)
	local ok, err = validate(value)
	if not ok then
		error(`--{flag} '{value}': {err}`, 0)
	end
end

-- Flags first; then, for anything not given, the default (with --yes) or a question.
function Wizard.answers(flags: Cli.Flags, env: Env): Options.Answers
	local ask = not flags.yes
	local prompter = env.prompter
	local defaults = Options.defaults

	-- Name and directory: either one gives the other.
	local directory = flags.directory
	local name = flags.name
	if name then
		check(Names.validateProject, name, "name")
	end
	if directory and not name then
		local base = Names.basename(resolve(env.cwd, directory))
		local ok, err = Names.validateProject(base)
		if ok then
			name = base
		elseif ask then
			name = prompter.text("Project name:", "my-game", Names.validateProject)
		else
			error(`'{base}' can't be the project name: {err}. Pass --name.`, 0)
		end
	end
	if not name then
		name = if ask then prompter.text("Project name:", "my-game", Names.validateProject) else "my-game"
	end
	local projectName = name :: string
	local targetDirectory = directory or projectName

	local description = flags.description
	if not description then
		description = if ask then prompter.text("Description:", defaults.description) else defaults.description
	end

	local author = flags.author
	if not author then
		local default = gitAuthor(env)
		author = if ask then prompter.text("Author:", default) else default
	end

	local package = flags.package
	local defaultPackage = Names.defaultPackage(projectName, author)
	if package then
		check(Names.validatePackage, package, "package")
	else
		package = if ask then prompter.text("pesde package name:", defaultPackage, Names.validatePackage) else defaultPackage
	end

	local license = flags.license
	if license then
		local choice = Options.find(Options.licenses, license)
		if not choice then
			local ids = {}
			for _, option in Options.licenses do
				table.insert(ids, option.id)
			end
			error(`--license '{license}': choose one of {table.concat(ids, ", ")}`, 0)
		end
		license = choice.id
	elseif ask then
		-- The default goes first, because select starts on the first option.
		local ordered = { Options.find(Options.licenses, defaults.license) :: Options.Choice }
		for _, option in Options.licenses do
			if option.id ~= defaults.license then
				table.insert(ordered, option)
			end
		end
		local labels = {}
		for _, option in ordered do
			table.insert(labels, option.label)
		end
		license = ordered[prompter.select("License:", labels)].id
	else
		license = defaults.license
	end

	local function boolean(value: boolean?, question: string, default: boolean): boolean
		if value ~= nil then
			return value
		end
		return if ask then prompter.confirm(question, default) else default
	end

	local examples = boolean(flags.examples, "Add example systems, a network module and a test?", defaults.examples)

	local tools = flags.tools
	if not tools then
		local all = table.clone(defaults.tools)
		if ask then
			local names = {}
			for _, tool in Options.tools do
				local short = string.gsub(string.match(tool.label, "^[^%(]+") :: string, "%s+$", "")
				table.insert(names, short)
			end
			local summary = table.concat(names, ", ")
			local choice = prompter.select("Lint, format and type-check tools:", {
				`All of them: {summary} (recommended)`,
				"Let me pick",
				"None",
			})
			if choice == 1 then
				tools = all
			elseif choice == 3 then
				tools = {}
				for _, tool in Options.tools do
					(tools :: any)[tool.id] = false
				end
			else
				local labels = {}
				for _, tool in Options.tools do
					table.insert(labels, tool.label)
				end
				local picked = {}
				for _, index in prompter.multiselect("Which tools? (space to select, enter to confirm)", labels) do
					picked[Options.tools[index].id] = true
				end
				tools = {}
				for _, tool in Options.tools do
					(tools :: any)[tool.id] = picked[tool.id] == true
				end
			end
		else
			tools = all
		end
	end

	local kit = flags.kit
	if not kit then
		kit = {}
		if ask and #Options.kit > 0 then
			local labels = {}
			for _, module in Options.kit do
				table.insert(labels, module.label)
			end
			for _, index in prompter.multiselect("Which Hydrogen modules do you want? (space to select)", labels) do
				(kit :: any)[Options.kit[index].id] = true
			end
		end
	end

	local ci = boolean(flags.ci, "Add a GitHub Actions workflow (build, test, lint)?", defaults.ci)
	local agents = boolean(flags.agents, "Add AGENTS.md and CLAUDE.md for coding agents?", defaults.agents)
	local git = if flags.git ~= nil then flags.git else defaults.git
	local install = if flags.install ~= nil then flags.install else defaults.install

	return {
		directory = targetDirectory,
		name = projectName,
		package = package :: string,
		description = description :: string,
		author = author :: string,
		license = license :: string,
		examples = examples,
		ci = ci,
		agents = agents,
		tools = tools :: { [string]: boolean },
		kit = kit :: { [string]: boolean },
		git = git,
		install = install,
		force = flags.force,
	}
end

-- The Rokit tools the project pins, in rokit.toml order.
function Wizard.rokitTools(answers: Options.Answers): { string }
	local list = { "rojo", "pesde", "lune" }
	for _, tool in Options.tools do
		if answers.tools[tool.id] then
			table.insert(list, tool.id)
		end
	end
	return list
end

local function step(env: Env, text: string)
	env.out(`\n> {text}\n`)
end

local function failed(result: Tools.Result?): string
	if not result then
		return "not installed"
	end
	local message = string.gsub(result.stderr ~= "" and result.stderr or result.stdout, "%s+$", "")
	return if message ~= "" then message else `exit code {result.code}`
end

function Wizard.run(flags: Cli.Flags, env: Env): Outcome
	local answers = Wizard.answers(flags, env)
	local directory = resolve(env.cwd, answers.directory)

	local problem = Scaffold.checkTarget(directory, answers.force)
	if problem then
		if not flags.yes and not answers.force and fs.isDir(directory) then
			if env.prompter.confirm(`'{answers.directory}' isn't empty. Write into it anyway (files with the same names are overwritten)?`, false) then
				problem = nil
			end
		end
		if problem then
			error(problem, 0)
		end
	end

	local skipped: { string } = {}
	local committed = false
	-- Set when a step that should have run didn't: a missing tool or a failure. Steps the user
	-- turned off (--no-git, --no-install) and a repository that already exists don't count.
	local incomplete = false
	local function problem(text: string)
		incomplete = true
		table.insert(skipped, text)
	end

	-- The branch is decided up front because the CI workflow names it. A default the user set
	-- in their global git config wins; otherwise main (Git for Windows' system config says
	-- master, which most people never chose).
	local hasGit = answers.git and Tools.version(env.run, "git", env.cwd) ~= nil
	local branch = "main"
	if hasGit then
		local configured = env.run("git", { "config", "--global", "init.defaultBranch" }, env.cwd)
		local name = configured and configured.ok and string.match(configured.stdout, "^%s*(%S+)")
		if name then
			branch = name
		end
	end

	local vars = Scaffold.vars(answers, env.year, branch)
	local files = Scaffold.plan(answers, vars, env.templateRoot)
	Scaffold.write(directory, files)
	env.out(`\nCreated {answers.name} in {directory}\n`)

	-- git init first, so a failed install still leaves a repository.
	local useGit = false
	if answers.git then
		if not hasGit then
			problem(`git: not found. {Tools.install.git}`)
		else
			local inside = env.run("git", { "rev-parse", "--show-toplevel" }, directory)
			if inside and inside.ok and not fs.isDir(directory .. "/.git") then
				local top = string.gsub(inside.stdout, "%s+$", "")
				table.insert(skipped, `git init: {directory} is already inside the repository at {top}, so no new repository was made.`)
			else
				step(env, `git init --initial-branch={branch}`)
				local result = env.run("git", { "init", `--initial-branch={branch}` }, directory)
				if not (result and result.ok) then
					-- git before 2.28 has no --initial-branch.
					result = env.run("git", { "init" }, directory)
					if result and result.ok then
						env.run("git", { "symbolic-ref", "HEAD", `refs/heads/{branch}` }, directory)
					end
				end
				if result and result.ok then
					useGit = true
				else
					problem(`git init failed: {failed(result)}`)
				end
			end
		end
	end

	if answers.install then
		local rokitVersion = Tools.version(env.run, "rokit", directory)
		if not rokitVersion then
			problem(`rokit install: Rokit isn't installed. {Tools.install.rokit}`)
		else
			-- Interactive runs let Rokit ask about tools it hasn't seen; without a terminal it
			-- can't, and the trust list is the user's to change, so that case is reported.
			step(env, "rokit install")
			local result = env.run("rokit", { "install" }, directory, env.interactive)
			if not (result and result.ok) then
				local output = if result then result.stdout .. result.stderr else ""
				if string.find(output, "trusted", 1, true) then
					local repos = {}
					for _, id in Wizard.rokitTools(answers) do
						table.insert(repos, Versions.tools[id].repo)
					end
					problem(
						`rokit install: some tools aren't trusted yet. Run \`rokit install\` in the project and answer the questions, or trust them first with \`rokit trust {table.concat(repos, " ")}\`.`
					)
				else
					problem(`rokit install failed: {failed(result)}. Run \`rokit install\` in the project to retry.`)
				end
			end
		end

		if not Tools.version(env.run, "pesde", directory) then
			problem(`pesde install: pesde isn't installed. {Tools.install.pesde}`)
		else
			step(env, "pesde install")
			local result = env.run("pesde", { "install" }, directory, env.interactive)
			if not (result and result.ok) then
				problem(`pesde install failed: {failed(result)}. Run \`pesde install\` in the project to retry.`)
			else
				-- luau-lsp regenerates this on its own; making it now means the editor works on first open.
				local sourcemap = env.run("rojo", { "sourcemap", "default.project.json", "--output", "sourcemap.json" }, directory)
				if not (sourcemap and sourcemap.ok) then
					table.insert(skipped, `rojo sourcemap: {failed(sourcemap)}. luau-lsp makes it when you open the project.`)
				end
			end
		end
	else
		table.insert(skipped, "Installs skipped (--no-install): run `rokit install`, then `pesde install`.")
	end

	if useGit then
		step(env, "git commit")
		env.run("git", { "add", "-A" }, directory)
		local result = env.run("git", { "commit", "--quiet", "-m", "Create project with create_hydrogen" }, directory)
		if result and result.ok then
			committed = true
		else
			problem(
				`git commit failed: {failed(result)}. If git doesn't know who you are yet, run \`git config --global user.name "Your Name"\` and \`git config --global user.email you@example.com\`, then \`git commit -m "First commit"\`.`
			)
		end
	end

	return {
		directory = directory,
		answers = answers,
		files = files,
		skipped = skipped,
		committed = committed,
		incomplete = incomplete,
	}
end

return Wizard
