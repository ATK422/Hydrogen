--!strict

-- What the wizard can ask for, and the defaults. Adding a choice here makes it show up as a
-- prompt and a flag; the template folders it names are copied when it's chosen.

export type Choice = {
	id: string,
	label: string,
	-- Template overlay folders (under template/) copied when this choice is on.
	overlays: { string }?,
}

export type KitModule = Choice & {
	-- The Hydrogen version requirement the module needs. The generated pesde.toml uses the
	-- highest requirement among the chosen modules and the base one.
	hydrogen: string,
}

export type Answers = {
	directory: string,
	name: string,
	package: string,
	description: string,
	author: string,
	license: string,
	examples: boolean,
	ci: boolean,
	tools: { [string]: boolean },
	kit: { [string]: boolean },
	git: boolean,
	install: boolean,
	force: boolean,
}

local Options = {}

Options.licenses = {
	{ id = "MIT", label = "MIT" },
	{ id = "Apache-2.0", label = "Apache 2.0" },
	{ id = "MPL-2.0", label = "Mozilla Public License 2.0" },
	{ id = "None", label = "None (all rights reserved, no LICENSE file)" },
} :: { Choice }

-- Tooling. Each one adds a Rokit pin, its config files, editor settings and a CI step.
Options.tools = {
	{ id = "stylua", label = "StyLua (formatter)", overlays = { "stylua" } },
	{ id = "selene", label = "Selene (linter)", overlays = { "selene" } },
	{ id = "luau_lsp", label = "luau-lsp CLI (type checking from the command line and CI)" },
} :: { Choice }

-- Extension point for the Tier 1 kit. When a module ships in a Hydrogen release, add it here:
--
--   {
--       id = "data",
--       label = "Hydrogen.Data: saved player data with session locking",
--       hydrogen = "^0.5.0",
--       overlays = { "kit/data" }, -- e.g. template/kit/data/src/server/Systems/PlayerData.luau
--   },
--
-- The wizard then asks "Which Hydrogen modules do you want?", accepts --kit data,..., copies
-- the overlay and raises the Hydrogen requirement. Templates can test `kit_data` in {{#if}}.
-- Keep the list empty until the module is released: the template may only use released API.
Options.kit = {} :: { KitModule }

Options.defaults = {
	description = "A Roblox game built with Hydrogen",
	license = "MIT",
	examples = true,
	ci = true,
	tools = { stylua = true, selene = true, luau_lsp = true },
	git = true,
	install = true,
}

function Options.find(list: { Choice }, id: string): Choice?
	local wanted = string.lower(id)
	for _, choice in list do
		if string.lower(choice.id) == wanted or string.lower(string.gsub(choice.id, "_", "-")) == wanted then
			return choice
		end
	end
	return nil
end

function Options.ids(list: { Choice }): { string }
	local ids = {}
	for _, choice in list do
		table.insert(ids, (string.gsub(choice.id, "_", "-")))
	end
	return ids
end

return Options
