--!strict

-- Typed configuration and feature flags. Declare once in a shared module with Config.define;
-- read values as plain table lookups, gate features per player with flags, override per
-- environment, and optionally take live values from a remote source without a deploy.

local Define = require("@self/Define")
local Environment = require("@self/Environment")
local Rules = require("@self/Rules")
local Sources = require("@self/Sources")

export type Config<V, F> = Define.Config<V, F>
export type Spec<V, F> = Define.Spec<V, F>
export type Flag = Define.Flag
export type FlagRule = Rules.FlagRule
export type Segment = Rules.Segment
export type Overrides = Define.Overrides
export type Environments = Define.Environments
export type Environment = Environment.Environment
export type EnvironmentKind = Environment.Kind
export type Source = Sources.Source
export type MemorySource = Sources.MemorySource
export type ExperienceConfigsOptions = Sources.ExperienceConfigsOptions
export type DataStoreOptions = Sources.DataStoreOptions

local Config = {
	-- Config.define(name, { values, flags, segments, environments, source, refresh }): a config,
	-- which is also a system; add it to the app on the server.
	define = Define.define,
	-- A value only the server can read. Never replicated.
	value = Define.value,
	-- A value the server replicates to every client.
	shared = Define.shared,
	-- A feature flag: true, false or a rollout rule.
	flag = Define.flag,
	-- A flag from any config by name: errors if there is none, or nil from findFlag.
	getFlag = Define.getFlag,
	findFlag = Define.findFlag,
	-- Where this server runs: { kind = "studio" | "private" | "reserved" | "live", placeId }.
	environment = Define.environment,
	-- Tests: pretend to run in another environment (nil for the real one).
	useEnvironment = Define.useEnvironment,
	-- Server: evaluates flags again for a player (or everyone), after something a custom check
	-- or segment reads has changed.
	reevaluate = Define.reevaluate,
	-- Tests: overrides, live values, flag results and observers dropped. Hydrogen.test calls it.
	reset = Define.reset,
	-- Live sources.
	experienceConfigs = Sources.experienceConfigs,
	dataStore = Sources.dataStore,
	memory = Sources.memory,
}

return Config
