local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local dataModel = roblox.Instance.new("DataModel")
Instance = roblox.Instance

for _, className in { "ReplicatedStorage", "Players", "RunService" } do
	pcall(function()
		local service = Instance.new(className)
		service.Name = className
		service.Parent = dataModel
	end)
end

local runService = {}
function runService:IsClient()
	return false
end
function runService:IsServer()
	return false
end

game = setmetatable({
	GetService = function(_self, name: string)
		if name == "RunService" then
			return runService
		end
		return dataModel:GetService(name)
	end,
}, {
	__index = dataModel,
})

local oldRequire = require
local cwd = (process.cwd :: string):gsub("[/\\]+$", "")

local function toAbsolute(path: string): string
	path = string.gsub(path, "\\", "/")
	if string.match(path, "^[A-Za-z]:/") or string.sub(path, 1, 1) == "/" then
		return path
	end
	return `{cwd}/{string.gsub(path, "^%./", "")}`
end

local function splitPath(path: string): { string }
	local parts = {}
	for part in string.gmatch(path, "[^/\\]+") do
		table.insert(parts, part)
	end
	return parts
end

local function joinPath(parts: { string }): string
	return table.concat(parts, "/")
end

local function dirname(path: string): string
	return string.match(path, "^(.*)[/\\][^/\\]+$") or path
end

local function resolvePath(base: string, rel: string): string
	local parts = splitPath(base)
	for _, part in splitPath(rel) do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return joinPath(parts)
end

local runnerDir = dirname(toAbsolute(debug.info(1, "s") :: string))

local function pathFromRunner(absPath: string): string
	local fromParts = splitPath(runnerDir)
	local toParts = splitPath(absPath)
	local i = 1
	while fromParts[i] and toParts[i] and string.lower(fromParts[i]) == string.lower(toParts[i]) do
		i += 1
	end

	local rel = {}
	for _ = i, #fromParts do
		table.insert(rel, "..")
	end
	for j = i, #toParts do
		table.insert(rel, toParts[j])
	end

	if #rel == 0 then
		return "./"
	end

	local result = joinPath(rel)
	if string.sub(result, 1, 1) ~= "." then
		result = "./" .. result
	end
	return result
end

local function callerRoot(caller: string): string
	caller = toAbsolute(caller)
	if fs.isDir(caller) then
		return caller
	end
	return dirname(caller)
end

require = function(path: string)
	if path == "@pkg/gt" or string.match(path, "roblox_packages/gt$") then
		return oldRequire("../roblox_packages/.pesde/corecii+greentea/0.4.11/greentea/src/GreenTea")
	end

	if string.sub(path, 1, 1) == "@" and string.sub(path, 1, 6) ~= "@self/" then
		return oldRequire(path)
	end

	local caller = debug.info(2, "s") :: string
	local target = if string.sub(path, 1, 6) == "@self/"
		then resolvePath(callerRoot(caller), string.sub(path, 7))
		else resolvePath(callerRoot(caller), path)

	return oldRequire(pathFromRunner(target))
end

require("./Graph")()
require("./Definition")()
require("./App")()
require("./Network")()

local frktest = require("@pkg/frktest")
local console_reporter = frktest.reporters.console_reporter

console_reporter.init()

if not frktest.run() then
	process.exit(1)
end
