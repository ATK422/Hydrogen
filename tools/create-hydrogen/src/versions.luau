--!strict

-- Every version a generated project pins, in one place. Bump these when a tool or Hydrogen
-- releases, then run the generator tests (they build a project with these pins).

return {
	-- The generator's own version, printed by --version. Keep it in step with pesde.toml.
	cli = "0.1.1",

	-- pesde dependency requirement for Hydrogen in the generated pesde.toml.
	hydrogen = "^0.5.0",

	-- Rokit tools: rokit.toml entries are `<name> = "<repo>@<version>"`.
	tools = {
		rojo = { repo = "rojo-rbx/rojo", version = "7.7.1" },
		pesde = { repo = "pesde-pkg/pesde", version = "0.7.4+registry.0.2.3" },
		lune = { repo = "lune-org/lune", version = "0.10.4" },
		stylua = { repo = "JohnnyMorganz/StyLua", version = "2.6.0" },
		selene = { repo = "Kampfkarren/selene", version = "0.32.0" },
		luau_lsp = { repo = "JohnnyMorganz/luau-lsp", version = "1.70.1" },
	},

	-- pesde [engines] in the generated pesde.toml. Lune must match the rokit pin above.
	engines = {
		pesde = "^0.7.4",
		lune = "^0.10.4",
	},

	-- pesde dev dependencies of the generated project.
	devDependencies = {
		scripts_rojo = "^0.2.0",
		rojo = "^7.5.1",
		frktest = "^0.0.4",
	},

	-- GitHub Actions used by the generated CI workflow.
	actions = {
		checkout = "actions/checkout@v5",
		setupRokit = "CompeyDev/setup-rokit@v0.2.1",
	},
}
