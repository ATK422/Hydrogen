--!strict

-- The network lint: boots a game's server and client under Lune, each in its own world, and
-- compares what Hydrogen's network registered on each side. See docs/ai/lint.md.
--
-- Lune-only, like src/Testing/Lune.luau: nothing in a game requires it, so it costs nothing there.

local lune = {
	fs = (require :: any)("@lune/fs"),
	process = (require :: any)("@lune/process"),
	serde = (require :: any)("@lune/serde"),
	task = (require :: any)("@lune/task"),
}

local Probe = require("./Probe")
local Rules = require("./Rules")
local World = require("./World")

export type Diagnostic = Rules.Diagnostic
export type Location = Rules.Location

export type Options = {
	-- The game's project directory. Relative paths are from the working directory.
	root: string,
	-- The Rojo project file, relative to root. Defaults to default.project.json.
	project: string?,
	-- A sourcemap file (relative to root) or a decoded one. Without it the lint runs
	-- `rojo sourcemap`, and falls back to root/sourcemap.json when Rojo isn't installed.
	sourcemap: (string | { [string]: any })?,
	-- Seconds to let deferred work (task.defer, task.delay) run after the scripts start.
	wait: number?,
	-- Rules to leave out of the report.
	ignore: { string }?,
}

export type ScriptSummary = {
	instance: string,
	file: string,
	status: "finished" | "errored" | "running",
}

export type SideSummary = {
	scripts: { ScriptSummary },
	started: boolean,
	names: { string },
	hash: string?,
	addNetwork: { string },
	-- Instances the game waited for or indexed that aren't in the Rojo project.
	missing: { string },
	-- What the game printed and warned while booting, kept out of the report.
	output: { string },
}

export type Report = {
	-- Bumped when the JSON shape changes incompatibly.
	format: number,
	ok: boolean,
	errors: number,
	warnings: number,
	diagnostics: { Diagnostic },
	server: SideSummary,
	client: SideSummary,
	-- Where the sourcemap came from.
	sourcemap: string,
}

local Lint = {}

Lint.FORMAT = 1

-- Seconds the lint waits for the game to finish loading its modules.
local TIMEOUT = 60
Lint.rules = Rules.list

local function cwd(): string
	return (string.gsub(string.gsub(lune.process.cwd :: string, "\\", "/"), "/+$", ""))
end

local function readJson(file: string): any
	local ok, value = pcall(function()
		return lune.serde.decode("json", lune.fs.readFile(file))
	end)
	if not ok then
		error(`[HYDROGEN] Couldn't read {file} as JSON: {value}`, 0)
	end
	return value
end

local function sourcemapFor(root: string, options: Options): (any, string)
	local given = options.sourcemap
	if type(given) == "table" then
		return given, "given"
	elseif type(given) == "string" then
		local file = World.normalize(given, root)
		if not lune.fs.isFile(file) then
			error(`[HYDROGEN] No sourcemap at {file}`, 0)
		end
		return readJson(file), given
	end

	local project = options.project or "default.project.json"
	if not lune.fs.isFile(World.normalize(project, root)) then
		error(`[HYDROGEN] No Rojo project at {World.normalize(project, root)}. Run the lint from the game's folder, or pass --project <file>.`, 0)
	end

	local ok, result = pcall(lune.process.exec, "rojo", { "sourcemap", project }, { cwd = root })
	if ok and result.ok then
		return lune.serde.decode("json", result.stdout), `rojo sourcemap {project}`
	end

	local fallback = World.normalize("sourcemap.json", root)
	if lune.fs.isFile(fallback) then
		return readJson(fallback), "sourcemap.json (Rojo didn't run, so it may be stale)"
	end

	local reason = if ok then result.stderr else tostring(result)
	error(`[HYDROGEN] Couldn't run \`rojo sourcemap {project}\`: {reason}\nInstall Rojo (rokit install), or pass --sourcemap <file>.`, 0)
end

local function summarize(world: World.World, snapshot: Probe.Snapshot): SideSummary
	local scripts = {}
	for _, run in world.scripts do
		table.insert(scripts, { instance = run.instance, file = run.file, status = run.status })
	end
	local containers = {}
	for _, call in snapshot.addNetwork do
		for _, container in call.containers do
			table.insert(containers, container)
		end
	end
	local missing = {}
	for path in world.missing do
		table.insert(missing, path)
	end
	table.sort(missing)
	local output = {}
	for _, line in world.prints do
		table.insert(output, line.text)
	end
	for _, line in world.warnings do
		table.insert(output, line.text)
	end
	return {
		scripts = scripts,
		started = snapshot.started,
		names = snapshot.names,
		hash = snapshot.hash,
		addNetwork = containers,
		missing = missing,
		output = output,
	}
end

-- Boots both sides and checks them. Errors with a [HYDROGEN] message when it can't run at all
-- (no project, no sourcemap); problems in the game are diagnostics in the report.
function Lint.run(options: Options): Report
	local root = World.normalize(options.root, cwd())
	if not lune.fs.isDir(root) then
		error(`[HYDROGEN] No project directory at {root}`, 0)
	end
	local sourcemap, source = sourcemapFor(root, options)

	local booted = {}
	for _, side: World.Side in { "server", "client" } :: { World.Side } do
		local world = World.new({ side = side, root = root, sourcemap = sourcemap })
		local probe = Probe.attach(world)
		world.started = function(): boolean
			return probe:started()
		end
		booted[side] = { side = side, world = world, probe = probe }
	end

	-- Both sides boot at once, like a server and a client joining it.
	for _, side in { "server", "client" } do
		local entry = booted[side]
		for _, node in entry.world:entryScripts() do
			entry.world:runScript(node)
		end
	end
	-- Loading yields on file reads; wait for it, give deferred work its time, then wait again.
	local deadline = os.clock() + TIMEOUT
	local function settle()
		repeat
			lune.task.wait()
		until not World.busy() or os.clock() > deadline
	end
	settle()
	lune.task.wait(options.wait or 0.1)
	settle()

	for _, side in { "server", "client" } do
		local entry = booted[side]
		entry.world:finish()
		entry.snapshot = entry.probe:snapshot()
	end

	local ignored: { [string]: boolean } = {}
	for _, rule in options.ignore or {} :: { string } do
		ignored[rule] = true
	end

	local diagnostics = {}
	local errors, warnings = 0, 0
	for _, diagnostic in Rules.check(booted.server, booted.client) do
		if not ignored[diagnostic.rule] then
			table.insert(diagnostics, diagnostic)
			if diagnostic.severity == "error" then
				errors += 1
			else
				warnings += 1
			end
		end
	end

	return {
		format = Lint.FORMAT,
		ok = errors == 0,
		errors = errors,
		warnings = warnings,
		diagnostics = diagnostics,
		server = summarize(booted.server.world, booted.server.snapshot),
		client = summarize(booted.client.world, booted.client.snapshot),
		sourcemap = source,
	}
end

-- Whether a rule name exists, for validating --ignore.
function Lint.isRule(name: string): boolean
	for _, rule in Rules.list do
		if rule.name == name then
			return true
		end
	end
	return false
end

return Lint
