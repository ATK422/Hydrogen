--!strict
--!nolint DeprecatedApi

-- Finds the Hydrogen a project installed and loads its lint engine.

local fs = require("@lune/fs")
local luau = require("@lune/luau")

local Locate = {}

local ENGINE = "src/Testing/Lint/Cli.luau"
local VALUE_FLAGS = { ["--project"] = true, ["--sourcemap"] = true, ["--ignore"] = true, ["--wait"] = true, ["--hydrogen"] = true }

local function slashes(path: string): string
	return (string.gsub(string.gsub(path, "\\", "/"), "/+$", ""))
end

local function absolute(path: string, base: string): string
	path = slashes(path)
	if string.match(path, "^%a:/") or string.sub(path, 1, 1) == "/" then
		return path
	end
	local parts = {}
	for part in string.gmatch(`{slashes(base)}/{path}`, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	local joined = table.concat(parts, "/")
	return if string.sub(slashes(base), 1, 1) == "/" then `/{joined}` else joined
end

-- The project directory and --hydrogen from the arguments, without validating the rest.
function Locate.parse(args: { string }): (string, string?)
	local directory = "."
	local hydrogen = nil
	local index = 1
	while index <= #args do
		local arg = args[index]
		local inline = string.match(arg, "^%-%-hydrogen=(.*)$")
		if inline then
			hydrogen = inline
		elseif arg == "--hydrogen" then
			index += 1
			hydrogen = args[index]
		elseif VALUE_FLAGS[arg] then
			index += 1
		elseif arg ~= "--" and string.sub(arg, 1, 1) ~= "-" then
			directory = arg
		end
		index += 1
	end
	return directory, hydrogen
end

-- A Hydrogen package folder (one with src/), or its src folder.
local function engineIn(folder: string): string?
	for _, candidate in { `{folder}/{ENGINE}`, `{folder}/{string.sub(ENGINE, 5)}` } do
		if fs.isFile(candidate) then
			return candidate
		end
	end
	return nil
end

-- pesde writes roblox_packages/<alias>.luau as `return require("./.pesde/<scope>+<name>/<version>/<name>/src")`.
local function installed(project: string): (string?, string?)
	local packages = `{project}/roblox_packages`
	if not fs.isDir(packages) then
		return nil, nil
	end
	for _, entry in fs.readDir(packages) do
		local file = `{packages}/{entry}`
		if string.match(entry, "%.luau$") and fs.isFile(file) then
			local target = string.match(fs.readFile(file), "require%(\"%./(%.pesde/atk422%+hydrogen/[^\"]+)\"%)")
			if target then
				local folder = string.gsub(`{packages}/{target}`, "/src$", "")
				local version = string.match(target, "atk422%+hydrogen/([^/]+)/")
				return folder, version
			end
		end
	end
	return nil, nil
end

-- The engine's Cli.luau for the arguments' project, or why there isn't one.
function Locate.engine(args: { string }, cwd: string): (string?, string?)
	local directory, hydrogen = Locate.parse(args)
	local project = absolute(directory, cwd)

	if hydrogen then
		local folder = absolute(hydrogen, cwd)
		local engine = engineIn(folder)
		if not engine then
			return nil, `--hydrogen {folder} has no lint engine ({ENGINE}); point it at a Hydrogen package folder`
		end
		return engine, nil
	end

	local folder, version = installed(project)
	if folder then
		local engine = engineIn(folder)
		if not engine then
			return nil, `This project's Hydrogen ({version}) has no network lint. Update Hydrogen in pesde.toml to 0.5.0 or later, then run pesde install.`
		end
		return engine, nil
	end

	-- Hydrogen's own repository, or a checkout next to the game.
	local own = engineIn(project)
	if own then
		return own, nil
	end

	return nil, `Couldn't find Hydrogen in {project}/roblox_packages. Run pesde install in the game's folder, or pass --hydrogen <folder>.`
end

-- Loads a module and the modules it requires by relative path, from anywhere on disk. Lune's own
-- require only takes paths relative to the requiring script.
function Locate.load(file: string): any
	local cache: { [string]: any } = {}
	local globals = getfenv(0)

	local function load(path: string): any
		local key = string.lower(path)
		if cache[key] ~= nil then
			return cache[key]
		end
		local folder = string.match(path, "^(.*)/[^/]*$") or path
		local environment = setmetatable({
			require = function(target: string): any
				if string.sub(target, 1, 1) == "@" then
					return (require :: any)(target)
				end
				local resolved = absolute(target, folder)
				for _, candidate in { `{resolved}.luau`, `{resolved}.lua`, `{resolved}/init.luau` } do
					if fs.isFile(candidate) then
						return load(candidate)
					end
				end
				error(`can't find {target} required from {path}`, 2)
			end,
		}, { __index = globals })
		local chunk = luau.load(fs.readFile(path), {
			debugName = `@{path}`,
			environment = environment,
			injectGlobals = false,
		})
		local value = chunk()
		cache[key] = value
		return value
	end

	return load(slashes(file))
end

return Locate
