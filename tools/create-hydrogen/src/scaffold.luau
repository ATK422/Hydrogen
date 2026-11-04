--!strict

-- Turns answers into files: picks the template overlays, renders them, checks the target
-- directory and writes the result.

local fs = require("@lune/fs")

local Options = require("./options")
local Render = require("./render")
local Versions = require("./versions")

export type File = { path: string, contents: string }

local Scaffold = {}

local function join(a: string, b: string): string
	return (string.gsub(a, "[/\\]+$", "")) .. "/" .. b
end

-- The template folder ships next to src/ in the package.
function Scaffold.templateRoot(): string
	local source = debug.info(1, "s") :: string
	local here = string.match(string.gsub(source, "\\", "/"), "^(.*)/[^/]+$") or "."
	return join(string.match(here, "^(.*)/src$") or here, "template")
end

-- Overlays in the order they're applied; a later overlay replaces an earlier one's file.
function Scaffold.overlays(answers: Options.Answers): { string }
	local list = { "base", if answers.examples then "examples" else "starter" }
	if answers.ci then
		table.insert(list, "ci")
	end
	for _, group in { { Options.tools, answers.tools }, { Options.kit, answers.kit } } do
		local choices, chosen = group[1] :: { Options.Choice }, group[2] :: { [string]: boolean }
		for _, choice in choices do
			if chosen[choice.id] then
				for _, overlay in choice.overlays or {} do
					table.insert(list, overlay)
				end
			end
		end
	end
	return list
end

function Scaffold.vars(answers: Options.Answers, year: number?, branch: string?): Render.Vars
	local tools = Versions.tools
	local vars: Render.Vars = {
		name = answers.name,
		package = answers.package,
		description = answers.description,
		-- TOML and JSON strings: escape backslashes and quotes.
		description_toml = (string.gsub(answers.description, '[\\"]', "\\%0")),
		author = answers.author,
		author_toml = (string.gsub(answers.author, '[\\"]', "\\%0")),
		has_author = answers.author ~= "",
		license = answers.license,
		has_license = answers.license ~= "None",
		year = tostring(year or os.date("*t").year),
		branch = branch or "main",
		hydrogen_version = Versions.hydrogen,
		examples = answers.examples,
		ci = answers.ci,
		lint = answers.tools.stylua or answers.tools.selene or answers.tools.luau_lsp or false,
		pesde_engine = Versions.engines.pesde,
		lune_engine = Versions.engines.lune,
		scripts_rojo_version = Versions.devDependencies.scripts_rojo,
		rojo_package_version = Versions.devDependencies.rojo,
		frktest_version = Versions.devDependencies.frktest,
		action_checkout = Versions.actions.checkout,
		action_setup_rokit = Versions.actions.setupRokit,
	}
	for id, tool in tools do
		vars[`{id}_tool`] = `{tool.repo}@{tool.version}`
		vars[`{id}_version`] = tool.version
	end
	for _, choice in Options.tools do
		vars[choice.id] = answers.tools[choice.id] == true
	end
	for _, module in Options.kit do
		vars[`kit_{module.id}`] = answers.kit[module.id] == true
	end
	return vars
end

local function collect(root: string, relative: string, into: { [string]: string })
	local dir = if relative == "" then root else join(root, relative)
	for _, entry in fs.readDir(dir) do
		local childRelative = if relative == "" then entry else `{relative}/{entry}`
		if fs.isDir(join(root, childRelative)) then
			collect(root, childRelative, into)
		else
			into[childRelative] = join(root, childRelative)
		end
	end
end

-- Every file the project will have, rendered, sorted by path.
function Scaffold.plan(answers: Options.Answers, vars: Render.Vars, templateRoot: string?): { File }
	local root = templateRoot or Scaffold.templateRoot()
	local byPath: { [string]: File } = {}

	local function add(sourcePath: string, relative: string)
		local outPath, isTemplate = Render.path(relative)
		local contents = fs.readFile(sourcePath)
		if isTemplate then
			contents = Render.text(contents, vars, relative)
		end
		byPath[outPath] = { path = outPath, contents = contents }
	end

	for _, overlay in Scaffold.overlays(answers) do
		local overlayRoot = join(root, overlay)
		if not fs.isDir(overlayRoot) then
			error(`template overlay '{overlay}' is missing from {root}`, 0)
		end
		local files: { [string]: string } = {}
		collect(overlayRoot, "", files)
		for relative, sourcePath in files do
			add(sourcePath, relative)
		end
	end

	if answers.license ~= "None" then
		local licenses = join(root, "licenses")
		local plain = join(licenses, answers.license)
		local templated = plain .. ".tmpl"
		if fs.isFile(templated) then
			byPath.LICENSE = { path = "LICENSE", contents = Render.text(fs.readFile(templated), vars, "LICENSE") }
		elseif fs.isFile(plain) then
			byPath.LICENSE = { path = "LICENSE", contents = fs.readFile(plain) }
		else
			error(`no license text for '{answers.license}' in {licenses}`, 0)
		end
	end

	local files = {}
	for _, file in byPath do
		table.insert(files, file)
	end
	table.sort(files, function(a, b)
		return a.path < b.path
	end)
	return files
end

-- nil when the directory can be written to, otherwise why not.
function Scaffold.checkTarget(directory: string, force: boolean): string?
	if fs.isFile(directory) then
		return `'{directory}' is a file, not a directory`
	end
	if not fs.isDir(directory) then
		return nil
	end
	local entries = fs.readDir(directory)
	if #entries == 0 or force then
		return nil
	end
	table.sort(entries)
	local shown = table.concat(entries, ", ", 1, math.min(#entries, 5))
	if #entries > 5 then
		shown ..= `, and {#entries - 5} more`
	end
	return `'{directory}' isn't empty (it has {shown}). Pick another directory, or pass --force to write into it anyway (files with the same names are overwritten).`
end

function Scaffold.write(directory: string, files: { File })
	for _, file in files do
		local path = join(directory, file.path)
		local parent = string.match(path, "^(.*)/[^/]+$")
		if parent and not fs.isDir(parent) then
			fs.writeDir(parent)
		end
		fs.writeFile(path, file.contents)
	end
end

-- The files as an indented tree, for the summary.
function Scaffold.tree(files: { File }): string
	local lines = {}
	local printed: { [string]: boolean } = {}
	for _, file in files do
		local parts = string.split(file.path, "/")
		local prefix = ""
		for depth, part in parts do
			prefix = if prefix == "" then part else `{prefix}/{part}`
			if not printed[prefix] then
				printed[prefix] = true
				local isDir = depth < #parts
				table.insert(lines, string.rep("  ", depth - 1) .. part .. (if isDir then "/" else ""))
			end
		end
	end
	return table.concat(lines, "\n")
end

return Scaffold
