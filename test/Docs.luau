--!strict

-- Checks the Luau examples in docs/ai/*.md and README.md against the code, so they can't drift
-- from the API. Every ```luau block outside an API section must compile, and every
-- `Hydrogen.<Name>` and `Hydrogen.<Module>.<member>` it mentions must exist (a runtime value, or
-- an exported type for `Hydrogen.<Type>`). API sections (and their subsections) list
-- signatures, not code, so they are skipped. A fragment of a table, such as the fields of a
-- network definitions module, or a bare function expression, compiles when wrapped as one. A block that is deliberately not valid Luau can opt out with an HTML comment
-- `<!-- docs-check: skip -->` on the line before its fence.

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local fs = (require :: any)("@lune/fs")
local luau = (require :: any)("@lune/luau")

local Hydrogen = require("../src") :: any

type Block = {
	file: string,
	line: number,
	source: string,
}

local function documents(): { string }
	local files = { "README.md" }
	local names = fs.readDir("docs/ai")
	table.sort(names)
	for _, name in names do
		if string.match(name, "%.md$") then
			table.insert(files, `docs/ai/{name}`)
		end
	end
	return files
end

local function blocks(): { Block }
	local found: { Block } = {}
	for _, file in documents() do
		local text = string.gsub(fs.readFile(file), "\r\n", "\n")
		local lines = string.split(text, "\n")
		local section = ""
		local heading = ""
		local index = 1
		while index <= #lines do
			local line = lines[index]
			local level, title = string.match(line, "^(#+)%s+(.*)$")
			if level and #level <= 2 then
				section = title :: string
				heading = title :: string
			elseif level and #level == 3 then
				heading = title :: string
			end
			if string.match(line, "^```luau%s*$") then
				local skip = string.find(section, "API", 1, true) ~= nil
					or string.find(heading, "API", 1, true) ~= nil
					or (index > 1 and string.find(lines[index - 1], "docs-check: skip", 1, true) ~= nil)
				local body = {}
				local start = index
				index += 1
				while index <= #lines and not string.match(lines[index], "^```") do
					table.insert(body, lines[index])
					index += 1
				end
				if not skip then
					table.insert(found, { file = file, line = start, source = table.concat(body, "\n") })
				end
			end
			index += 1
		end
	end
	return found
end

-- Every `export type` in src/init.luau, which is what `Hydrogen.<Type>` can name.
local function exportedTypes(): { [string]: boolean }
	local names = {}
	for name in string.gmatch(fs.readFile("src/init.luau"), "export type ([%w_]+)") do
		names[name] = true
	end
	return names
end

local function firstLine(value: any): string
	return (string.split(tostring(value), "\n"))[1]
end

local function member(value: any, key: string): (boolean, any)
	if type(value) ~= "table" then
		return false, nil
	end
	local ok, result = pcall(function()
		return value[key]
	end)
	return ok and result ~= nil, result
end

return function()
	test.suite("Docs", function()
		local all = blocks()
		local types = exportedTypes()

		test.case("found the examples", function()
			check.is_true(#all > 100)
			return nil
		end)

		test.case("every example compiles", function()
			local failures = {}
			for _, block in all do
				local ok, err = pcall(luau.compile, block.source)
				if not ok then
					-- Table fields (`Name = Hydrogen.clientEvent(...),`) or a function expression.
					ok = pcall(luau.compile, "return {\n" .. block.source .. "\n}")
						or pcall(luau.compile, `return {block.source}`)
				end
				if not ok then
					table.insert(failures, `{block.file}:{block.line}: {firstLine(err)}`)
				end
			end
			if #failures > 0 then
				error(`Doc examples that don't compile:\n{table.concat(failures, "\n")}`, 0)
			end
			return nil
		end)

		test.case("every Hydrogen name an example uses exists", function()
			local failures = {}
			local seen: { [string]: boolean } = {}
			for _, block in all do
				-- Strip comments and strings, so prose like "Hydrogen.X lands later" isn't checked.
				local code = string.gsub(block.source, "%-%-[^\n]*", "")
				code = string.gsub(code, '"[^"\n]*"', '""')
				code = string.gsub(code, "`[^`\n]*`", "``")
				for first, second in string.gmatch(code, "%f[%w_]Hydrogen%.([%a_][%w_]*)%.?([%a_]?[%w_]*)") do
					local where = `{block.file}:{block.line}`
					local exists, value = member(Hydrogen, first)
					if not exists then
						if not types[first] and not seen[`{where} {first}`] then
							seen[`{where} {first}`] = true
							table.insert(failures, `{where}: Hydrogen.{first} is neither an export nor an exported type`)
						end
					elseif second ~= "" and type(value) == "table" then
						if not member(value, second) and not seen[`{where} {first}.{second}`] then
							seen[`{where} {first}.{second}`] = true
							table.insert(failures, `{where}: Hydrogen.{first}.{second} doesn't exist`)
						end
					end
				end
			end
			if #failures > 0 then
				error(`Doc examples naming Hydrogen APIs that don't exist:\n{table.concat(failures, "\n")}`, 0)
			end
			return nil
		end)

		return nil
	end)
	return nil
end
