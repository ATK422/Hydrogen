--!strict

-- `pesde run test`: loads every *.test.luau under test/ with Roblox globals (see Roblox.luau),
-- runs them with frktest and exits with 1 if anything failed.

local fs = (require :: any)("@lune/fs")
local process = (require :: any)("@lune/process")

local Roblox = require("./Roblox")
Roblox.install()

local frktest = require("@pkg/frktest")

local function findTests(dir: string, into: { string })
	local entries = fs.readDir(dir)
	table.sort(entries)
	for _, entry in entries do
		local path = `{dir}/{entry}`
		if fs.isDir(path) then
			findTests(path, into)
		elseif string.match(entry, "%.test%.luau$") then
			table.insert(into, path)
		end
	end
end

local files = {}
findTests("test", files)
if #files == 0 then
	print("No tests yet: add a file ending in .test.luau under test/.")
	process.exit(0)
end
for _, file in files do
	Roblox.require(file)
end

frktest.reporters.console_reporter.init()
-- Exit explicitly: a test that leaves a thread waiting would otherwise keep Lune running.
process.exit(if frktest.run() then 0 else 1)
