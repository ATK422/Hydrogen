--!strict

-- Chat-bar commands through TextChatService. Each command the player may run becomes a
-- TextChatCommand (/give, /kick) created on this client only, so the chat's autocomplete shows a
-- player just their own commands. Triggered fires on this client with the whole message, which
-- goes to the server like a line typed in the console. Studio-only: there is no chat under Lune.

local TextChatService = game:GetService("TextChatService")

local Types = require("./Types")

type CommandInfo = Types.CommandInfo
type OutputKind = Types.OutputKind

export type Binding = {
	update: (self: Binding, catalog: { CommandInfo }) -> (),
	display: (self: Binding, kind: OutputKind, text: string) -> (),
	destroy: (self: Binding) -> (),
}

local TextChat = {}

local ESCAPES = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&apos;",
}

local function escape(text: string): string
	return (string.gsub(text, "[&<>\"']", ESCAPES))
end

-- Aliases other TextChatCommands already use (Roblox's defaults, the game's own), lowercased.
local function takenAliases(folder: Instance): { [string]: boolean }
	local taken = {}
	for _, descendant in TextChatService:GetDescendants() do
		if descendant:IsA("TextChatCommand") and not descendant:IsDescendantOf(folder) then
			local command = descendant :: TextChatCommand
			for _, alias in { command.PrimaryAlias, command.SecondaryAlias } do
				if alias ~= "" then
					taken[string.lower(alias)] = true
				end
			end
		end
	end
	return taken
end

-- nil when the game uses the legacy chat.
function TextChat.bind(run: (text: string) -> ()): Binding?
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return nil
	end

	local folder = Instance.new("Folder")
	folder.Name = "HydrogenCommands"
	folder.Parent = TextChatService

	local binding = {} :: Binding

	function binding:update(catalog: { CommandInfo })
		folder:ClearAllChildren()
		local taken = takenAliases(folder)
		for _, info in catalog do
			local free = {}
			for _, word in { info.name, table.unpack(info.aliases) } do
				local alias = `/{word}`
				if not taken[alias] and #free < 2 then
					taken[alias] = true
					table.insert(free, alias)
				end
			end
			if #free == 0 then
				-- Roblox already owns every name (e.g. /help); the console still has it.
				continue
			end
			local command = Instance.new("TextChatCommand")
			command.Name = info.name
			command.PrimaryAlias = free[1]
			command.SecondaryAlias = free[2] or ""
			command.Triggered:Connect(function(_source: TextSource, text: string)
				run(text)
			end)
			command.Parent = folder
		end
	end

	function binding:display(kind: OutputKind, text: string)
		local channels = TextChatService:FindFirstChild("TextChannels")
		local system = channels and channels:FindFirstChild("RBXSystem")
		if not (system and system:IsA("TextChannel")) then
			return
		end
		local body = escape(text)
		if kind == "error" then
			body = `<font color="#ff6b6b">{body}</font>`
		end
		pcall(function()
			(system :: TextChannel):DisplaySystemMessage(body)
		end)
	end

	function binding:destroy()
		folder:Destroy()
	end

	return binding
end

return TextChat
