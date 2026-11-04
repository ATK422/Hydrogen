--!strict

-- A deliberately small template language, used only in files ending in .tmpl:
--
--   {{name}}                    the value of a string variable
--   {{#if flag}} ... {{/if}}    kept when the boolean variable is true
--   {{#unless flag}} ... {{/unless}}
--
-- A block tag alone on its line takes the whole line with it, so blocks don't leave blank
-- lines behind. Unknown variables and unclosed blocks are errors, so the generator tests
-- catch template typos. Files without .tmpl are copied byte for byte.

local Render = {}

export type Vars = { [string]: string | boolean }

type Token = { kind: "text", value: string } | { kind: "var", name: string } | { kind: "open", block: string, name: string } | { kind: "close", block: string }

local function tag(inner: string, file: string): Token
	local block, name = string.match(inner, "^#(%a+)%s+([%w_]+)$")
	if block then
		if block ~= "if" and block ~= "unless" then
			error(`{file}: unknown block '#{block}'`, 0)
		end
		return { kind = "open", block = block, name = name :: string }
	end
	local closing = string.match(inner, "^/(%a+)$")
	if closing then
		return { kind = "close", block = closing }
	end
	local var = string.match(inner, "^([%w_]+)$")
	if var then
		return { kind = "var", name = var }
	end
	error(file .. ": can't read the tag '{{" .. inner .. "}}'", 0)
end

local function tokenize(source: string, file: string): { Token }
	local tokens: { Token } = {}
	-- Split into lines, keeping each line's newline, so standalone block tags can drop theirs.
	for line in string.gmatch(source, "[^\n]*\n?") do
		if line == "" then
			continue
		end
		local standalone = string.match(line, "^[ \t]*{{([#/][^}]*)}}[ \t]*\r?\n?$")
		if standalone then
			table.insert(tokens, tag(standalone, file))
			continue
		end
		local position = 1
		while true do
			local start, finish, inner = string.find(line, "{{(.-)}}", position)
			if not start then
				table.insert(tokens, { kind = "text", value = string.sub(line, position) })
				break
			end
			table.insert(tokens, { kind = "text", value = string.sub(line, position, start - 1) })
			table.insert(tokens, tag(inner :: string, file))
			position = finish + 1
		end
	end
	return tokens
end

function Render.text(source: string, vars: Vars, file: string?): string
	local fileName = file or "template"
	local out = {}
	-- Each open block pushes whether its body is kept; a body is emitted only if all are.
	local stack: { { block: string, keep: boolean } } = {}
	local keeping = true

	local function recompute()
		keeping = true
		for _, frame in stack do
			keeping = keeping and frame.keep
		end
	end

	for _, token in tokenize(source, fileName) do
		if token.kind == "text" then
			if keeping then
				table.insert(out, token.value)
			end
		elseif token.kind == "var" then
			local value = vars[token.name]
			if type(value) ~= "string" then
				error(`{fileName}: unknown variable '{token.name}'`, 0)
			end
			if keeping then
				table.insert(out, value)
			end
		elseif token.kind == "open" then
			local value = vars[token.name]
			if type(value) ~= "boolean" then
				error(`{fileName}: unknown flag '{token.name}' in #{token.block}`, 0)
			end
			local keep = if token.block == "if" then value else not value
			table.insert(stack, { block = token.block, keep = keep })
			recompute()
		else
			local frame = table.remove(stack)
			if not frame or frame.block ~= token.block then
				error(`{fileName}: '/{token.block}' doesn't close an open block`, 0)
			end
			recompute()
		end
	end

	if #stack > 0 then
		error(`{fileName}: '#{stack[#stack].block}' is never closed`, 0)
	end
	return table.concat(out)
end

-- Template paths name dotfiles "dot-x" (so packaging tools never skip them) and templated files
-- "x.tmpl". Returns the output path and whether to render it.
function Render.path(relative: string): (string, boolean)
	local parts = {}
	for part in string.gmatch(relative, "[^/\\]+") do
		if string.sub(part, 1, 4) == "dot-" then
			part = "." .. string.sub(part, 5)
		end
		table.insert(parts, part)
	end
	local path = table.concat(parts, "/")
	if string.sub(path, -5) == ".tmpl" then
		return string.sub(path, 1, -6), true
	end
	return path, false
end

return Render
