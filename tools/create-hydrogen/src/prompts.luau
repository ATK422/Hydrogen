--!strict

-- Interactive questions. The wizard only talks to a Prompter, so tests can script the answers.

local stdio = require("@lune/stdio")

export type Validate = (value: string) -> (boolean, string?)

export type Prompter = {
	text: (message: string, default: string, validate: Validate?) -> string,
	confirm: (message: string, default: boolean) -> boolean,
	-- options[1] is the default.
	select: (message: string, options: { string }) -> number,
	multiselect: (message: string, options: { string }) -> { number },
}

local Prompts = {}

local function ask(kind: string, message: string, extra: any): any
	local ok, result = pcall(stdio.prompt :: any, kind, message, extra)
	if not ok then
		error(
			"Can't ask questions here (no interactive terminal). Pass --yes to use the defaults, "
				.. "or give each value as a flag (see --help).",
			0
		)
	end
	return result
end

Prompts.terminal = {
	text = function(message: string, default: string, validate: Validate?): string
		while true do
			local value = ask("text", message, if default ~= "" then default else nil)
			value = string.match(value or "", "^%s*(.-)%s*$") :: string
			if value == "" then
				value = default
			end
			if not validate then
				return value
			end
			local ok, err = validate(value)
			if ok then
				return value
			end
			stdio.write(stdio.color("red") .. `  {err}\n` .. stdio.color("reset"))
		end
	end,
	confirm = function(message: string, default: boolean): boolean
		return ask("confirm", message, default) :: boolean
	end,
	select = function(message: string, options: { string }): number
		local chosen = ask("select", message, options)
		if chosen == nil then
			error("Cancelled.", 0)
		end
		return chosen :: number
	end,
	multiselect = function(message: string, options: { string }): { number }
		return (ask("multiselect", message, options) or {}) :: { number }
	end,
} :: Prompter

-- A Prompter that answers from a list, in order, and errors on a question it has no answer
-- for. Each answer is a string (text), boolean (confirm), number (select) or table (multiselect).
function Prompts.scripted(answers: { any }): (Prompter, { string })
	local asked: { string } = {}
	local index = 0
	local function nextAnswer(message: string): any
		table.insert(asked, message)
		index += 1
		if index > #answers then
			error(`unexpected question: {message}`, 0)
		end
		return answers[index]
	end

	local prompter: Prompter = {
		text = function(message, default, validate)
			local value = nextAnswer(message)
			if value == "" then
				value = default
			end
			if validate then
				local ok, err = validate(value)
				if not ok then
					error(`scripted answer '{value}' for '{message}' is invalid: {err}`, 0)
				end
			end
			return value
		end,
		confirm = function(message, _default)
			return nextAnswer(message)
		end,
		select = function(message, _options)
			return nextAnswer(message)
		end,
		multiselect = function(message, _options)
			return nextAnswer(message)
		end,
	}
	return prompter, asked
end

return Prompts
