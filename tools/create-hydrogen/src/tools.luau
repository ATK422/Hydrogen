--!strict

-- Running external tools (git, rokit, pesde, rojo). Everything goes through a Runner, so the
-- tests can pretend a tool is missing or failing without changing the machine.

local process = require("@lune/process")

export type Result = {
	ok: boolean,
	code: number,
	stdout: string,
	stderr: string,
}

-- Returns nil when the program isn't installed (not on PATH).
-- With inherit = true, the tool reads from and writes to the terminal directly.
export type Runner = (program: string, args: { string }, cwd: string?, inherit: boolean?) -> Result?

local Tools = {}

function Tools.exec(program: string, args: { string }, cwd: string?, inherit: boolean?): Result?
	local ok, result = pcall(process.exec, program, args, {
		cwd = cwd,
		stdio = if inherit then "inherit" else "default",
	} :: any)
	if not ok then
		if string.find(tostring(result), "not found", 1, true) then
			return nil
		end
		return { ok = false, code = -1, stdout = "", stderr = tostring(result) }
	end
	local output = result :: any
	return {
		ok = output.ok,
		code = output.code,
		stdout = output.stdout or "",
		stderr = output.stderr or "",
	}
end

-- What to tell someone who doesn't have a tool, per platform where it differs.
Tools.install = {
	git = "Install Git from https://git-scm.com/downloads, or pass --no-git to skip it.",
	rokit = table.concat({
		"Install Rokit (https://github.com/rojo-rbx/rokit#installation):",
		"  Windows: download rokit from https://github.com/rojo-rbx/rokit/releases and run `./rokit self-install`",
		"  macOS / Linux: curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash",
		"then run `rokit install` in the project.",
	}, "\n"),
	pesde = "Install pesde (https://docs.pesde.dev/installation), then run `pesde install` in the project.",
	rojo = "Rojo comes from Rokit: run `rokit install` in the project.",
}

-- The first line of `<program> --version`, or nil if it isn't installed or doesn't run.
function Tools.version(run: Runner, program: string, cwd: string?): string?
	local result = run(program, { "--version" }, cwd)
	if not result or not result.ok then
		return nil
	end
	local text = string.gsub(result.stdout, "\27%[[%d;]*m", "")
	for line in string.gmatch(text, "[^\r\n]+") do
		-- pesde prints an update notice in a box before its version; skip those lines.
		if not string.find(line, "┃", 1, true) and string.match(line, "%d+%.%d+") then
			return (string.gsub(line, "^%s+", ""))
		end
	end
	return nil
end

return Tools
