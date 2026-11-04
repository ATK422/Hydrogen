--!strict

-- The lint's two outputs: text for people, JSON for CI and agents.

local serde = (require :: any)("@lune/serde")

local Lint = require("./Lint")

type Report = Lint.Report

export type TextOptions = {
	color: boolean?,
	-- Also print the game's own output and the Instances that got stand-ins.
	verbose: boolean?,
}

local Report = {}

local CODES = {
	red = "\27[31m",
	yellow = "\27[33m",
	cyan = "\27[36m",
	dim = "\27[2m",
	bold = "\27[1m",
	green = "\27[32m",
	reset = "\27[0m",
}

local function plural(count: number, word: string): string
	return `{count} {word}{if count == 1 then "" else "s"}`
end

local function sideLine(name: string, side: Lint.SideSummary): string
	local status = if side.started then "network started" else "network not started"
	return `{name}: {plural(#side.scripts, "script")}, {plural(#side.names, "name")}, {status}`
end

function Report.text(report: Report, options: TextOptions?): string
	local color = options ~= nil and options.color == true
	local verbose = options ~= nil and options.verbose == true
	local function paint(name: string, text: string): string
		return if color then (CODES :: any)[name] .. text .. CODES.reset else text
	end

	local lines = {}
	for _, diagnostic in report.diagnostics do
		local label = if diagnostic.severity == "error" then paint("red", "error") else paint("yellow", "warning")
		local sides = if #diagnostic.sides == 2 then "both sides" else `the {diagnostic.sides[1]}`
		table.insert(lines, `{label}{paint("dim", `[{diagnostic.rule}]`)} on {sides}: {paint("bold", diagnostic.message)}`)
		-- Name the side per location only when they differ, as in a kind mismatch.
		local mixed = false
		for _, location in diagnostic.locations do
			mixed = mixed or location.side ~= diagnostic.locations[1].side
		end
		for _, location in diagnostic.locations do
			local details = {}
			if mixed then
				table.insert(details, location.side)
			end
			if location.instance then
				table.insert(details, location.instance)
			end
			local suffix = if #details > 0 then ` ({table.concat(details, ", ")})` else ""
			table.insert(lines, `  {paint("cyan", "-->")} {location.file}:{location.line}{suffix}`)
		end
		if diagnostic.fix then
			table.insert(lines, `  {paint("green", "fix")}: {diagnostic.fix}`)
		end
		table.insert(lines, "")
	end

	if verbose then
		local sides: { { name: string, side: Lint.SideSummary } } = {
			{ name = "server", side = report.server },
			{ name = "client", side = report.client },
		}
		for _, entry in sides do
			local name, side = entry.name, entry.side
			if #side.missing > 0 then
				table.insert(lines, paint("dim", `{name}: stand-ins for Instances missing from the Rojo project: {table.concat(side.missing, ", ")}`))
			end
			for _, output in side.output do
				table.insert(lines, paint("dim", `{name} output: {output}`))
			end
		end
	end

	table.insert(lines, paint("dim", sideLine("server", report.server)))
	table.insert(lines, paint("dim", sideLine("client", report.client)))
	if report.errors == 0 and report.warnings == 0 then
		table.insert(lines, paint("green", "No network problems found."))
	else
		local summary = `{plural(report.errors, "error")}, {plural(report.warnings, "warning")}`
		table.insert(lines, paint(if report.errors > 0 then "red" else "yellow", summary))
	end
	return table.concat(lines, "\n")
end

-- A small JSON writer: keys sorted so output is stable between runs, and every empty table is a
-- list (a report has no empty objects).
local function encode(value: any, indent: string, into: { string })
	local kind = type(value)
	if kind == "table" then
		local inner = indent .. "  "
		if next(value) == nil or #value > 0 then
			if next(value) == nil then
				table.insert(into, "[]")
				return
			end
			table.insert(into, "[\n")
			for index, child in ipairs(value) do
				table.insert(into, inner)
				encode(child, inner, into)
				table.insert(into, if index < #value then ",\n" else "\n")
			end
			table.insert(into, indent .. "]")
			return
		end

		local keys = {}
		for key in value do
			table.insert(keys, tostring(key))
		end
		table.sort(keys)
		table.insert(into, "{\n")
		for index, key in keys do
			table.insert(into, `{inner}{serde.encode("json", key)}: `)
			encode(value[key], inner, into)
			table.insert(into, if index < #keys then ",\n" else "\n")
		end
		table.insert(into, indent .. "}")
	elseif kind == "string" then
		table.insert(into, serde.encode("json", value))
	elseif kind == "number" or kind == "boolean" then
		table.insert(into, tostring(value))
	else
		table.insert(into, "null")
	end
end

function Report.json(report: Report): string
	local into = {}
	encode(report, "", into)
	return table.concat(into)
end

return Report
