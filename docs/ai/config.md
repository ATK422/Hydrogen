# Hydrogen.Config
> Typed configuration and feature flags, declared once in a shared module: values with per-environment overrides, flags rolled out per player, and optional live values that change without a deploy. Reach for it for any tunable number, any server secret, and any feature you want to turn on gradually or for some players.

## Use it when / Don't use it when

Use it when:
- A value should differ between Studio, private servers, reserved servers, live servers or specific places (round length, max players, debug switches).
- A feature should be on for some players only: a percentage, staff, testers, group members, or a custom rule.
- Designers or live ops should change values or flags without a code deploy (Experience Configs, a DataStore key).
- The server needs a value clients must never see (API keys, webhook URLs, anti-cheat thresholds).

Don't use it when:
- The value is game state that changes as people play (round phase, coins, scores): use `Hydrogen.State` / `Hydrogen.PlayerState`.
- It is per-player saved data: use `Hydrogen.Data`.
- It is a constant nobody will ever tune: a plain `local` is fine.

## Quick start

```luau
-- ReplicatedStorage/Shared/GameConfig.luau (shared: required on server AND client before app:start)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Config, gt = Hydrogen.Config, Hydrogen.gt

return Config.define("Game", {
	values = {
		RoundLength = Config.value(gt.number({ range = "[10, 600]" }), 180), -- server only
		WebhookUrl = Config.value(gt.string(), ""),                          -- server only; set it from a server-only source
		MaxCoins = Config.shared(gt.number({ integer = true }), 1000),       -- replicated to clients
	},
	segments = {
		Staff = { groups = { 1234567 }, minRank = 200 },
	},
	flags = {
		NewShop = Config.flag({ percent = 10, segments = { "Staff" } }),
		Holiday = Config.flag(false),
	},
	environments = {
		studio = { RoundLength = 20, Holiday = true },
		private = { RoundLength = 60 },
	},
	source = Config.experienceConfigs(), -- optional: live values from Roblox Experience Configs
})
```

```luau
-- Server boot. The client boot must also require the module before app:start()
-- (directly, or by keeping it in a folder passed to app:addNetwork).
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local app = Hydrogen.App.new()
app:addSystem(GameConfig) -- the config is a system: add it on the server
app:addSystemsFolders(script.Parent.Systems)
app:start()
```

```luau
-- ServerScriptService/Systems/Shop.luau
local GameConfigModule = require(ReplicatedStorage.Shared.GameConfig)

return Hydrogen.define(function(use)
	local GameConfig = use(GameConfigModule) -- its playerAdded (flag evaluation) runs before ours
	local Shop = {}

	function Shop:playerAdded(player: Player)
		if GameConfig.flags.NewShop:enabled(player) then
			-- give this player the new shop
		end
		print("round length", GameConfig.values.RoundLength) -- plain table lookup
	end

	return Shop
end)
```

```luau
-- client
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
GameConfig.flags.NewShop:observe(Players.LocalPlayer, function(enabled: boolean)
	shopButton.Visible = enabled -- called now, then on every change
end)
print(GameConfig.values.MaxCoins) -- shared values only; GameConfig.values.RoundLength errors on the client
```

## API

Module (`Hydrogen.Config`):
- `define<V, F>(name: string, spec: ConfigSpec<V, F>): Config<V, F>`: both sides, at module top level, before `app:start()`. Returns a config that is also a system.
- `value<T>(schema: T, default: T): T`: a server-only value. Never replicated; reading it on a client errors.
- `shared<T>(schema: T, default: T): T`: a value the server replicates to every client.
- `flag(rule: FlagRule | boolean): Flag`: a feature flag, used inside `spec.flags`.
- `getFlag(name: string): Flag`: any config's flag by name; errors if none. `findFlag(name: string): Flag?` returns nil instead.
- `environment(): ConfigEnvironment`: `{ kind: "studio" | "private" | "reserved" | "live", placeId: number }` for this server.
- `useEnvironment(environment: { kind: ("studio" | "private" | "reserved" | "live")?, placeId: number? }?): ()`: tests; pretend to run elsewhere (kind defaults to `"live"`); `nil` restores the real one. Re-resolves every config.
- `reevaluate(player: Player?): ()`: server only; evaluates flags again for one player or everyone (after something a custom check reads changed).
- `reset(): ()`: tests; drops overrides, live values, flag results and observers, restores the environment. `Hydrogen.test` calls it on close.
- `experienceConfigs(options: { service: any? }?): ConfigSource`: server only; Roblox Experience Configs (`ConfigService`).
- `dataStore(name: string, options: { key: string?, topic: string?, store: any?, messaging: any? }?): ConfigSource`: server only; one DataStore key (default `"config"`) holding a table of values; `topic` subscribes to MessagingService for instant refresh.
- `memory(initial: { [string]: any }?): MemoryConfigSource`: in-memory source for tests.

Spec (`ConfigSpec<V, F>`):
```luau
{
	values: V?,                                  -- name = Config.value(...) | Config.shared(...)
	flags: F?,                                   -- name = Config.flag(...)
	segments: { [string]: ConfigSegment }?,      -- named player groups that flags can target
	environments: {
		studio: { [string]: any }?, private: { [string]: any }?,
		reserved: { [string]: any }?, live: { [string]: any }?,
		places: { [number]: { [string]: any } }?, -- by place id, on top of the kind
	}?,                                          -- each table: value name = value, or flag name = rule/boolean
	source: ConfigSource?,                       -- live values; off when omitted
	refresh: number?,                            -- seconds between source fetches; default 60
}
```

`Config<V, F>`:
- `name: string`, `values: V` (typed; `GameConfig.values.RoundLength`), `flags: F` (typed; `GameConfig.flags.NewShop`).
- `observe(self, name: string, observer: (value: any, previous: any) -> ()): () -> ()`: both sides (clients: shared values only); calls now, then on every change.
- `override(self, overrides: { [string]: any }): ()`: server only; sets values or flag rules from code, above every other layer; checked like a declaration.
- `clearOverrides(self, names: { string }?): ()`: server only; removes those overrides, or all.
- `refresh(self): boolean`: server only, yields; fetches from the source now; returns whether it worked.
- `replica(self): { [string]: any }`: the shared values this client received (inside `t:as` under loopback). For tests.

`Flag`:
- `name: string`
- `enabled(self, player: Player): boolean`: server: evaluated (cached per player). Client: whether the server said it is on for that player (only its own player is ever sent).
- `observe(self, player: Player, observer: (enabled: boolean) -> ()): () -> ()`: both sides; calls now, then on change.

Rules and segments:
```luau
type FlagRule = {
	enabled: boolean?,      -- false = off for everyone (kill switch). Default true.
	percent: number?,       -- 0..100 of players, by hash of (flag name, UserId)
	users: { number }?,     -- UserIds
	groups: { number }?,    -- members (rank >= 1) of any group
	segments: { string }?,  -- names from spec.segments
	when: ((player: Player) -> boolean)?, -- custom check; server; must not yield; code only
}
-- Config.flag(true) == {} (on for everyone); Config.flag(false) == { enabled = false }.
type ConfigSegment = ((player: Player) -> boolean) | {
	users: { number }?, groups: { number }?, minRank: number?, -- minRank (1..255, default 1) needs groups
	when: ((player: Player) -> boolean)?,
}
```

Sources:
```luau
type ConfigSource = {
	name: string,
	fetch: (self, names: { string }) -> { [string]: any }?, -- may yield; error = keep last good values
	subscribe: ((self, onUpdate: () -> ()) -> () -> ())?,   -- optional push; returns unsubscribe
}
-- MemoryConfigSource adds :set(name, value), :replace(values), :fail(message?), :push(), :fetches()
```

Exported types: `Hydrogen.Config<V, F>`, `Hydrogen.ConfigSpec<V, F>`, `Hydrogen.Flag`, `Hydrogen.FlagRule`, `Hydrogen.ConfigSegment`, `Hydrogen.ConfigEnvironment`, `Hydrogen.ConfigSource`, `Hydrogen.MemoryConfigSource`.

Yields: only `config:refresh()`, and the config's own `start` (first fetch, at most 5 s) and `playerAdded` (group ranks, at most 5 s). Reads, `enabled`, `observe` and `override` never yield.

## Rules

- **Layers, highest first:** `override` (code) → live source → `environments.places[placeId]` → `environments[kind]` → the declared default (values) or rule (flags). Removing a name from a higher layer falls back to the next.
- **Environment kind:** `studio` when `RunService:IsStudio()`; else `private` when `game.PrivateServerId ~= ""` and `PrivateServerOwnerId ~= 0`; `reserved` when `PrivateServerId ~= ""` and owner is 0; else `live`.
- **Define in a shared module required by both sides before `app:start()`.** A config with shared values registers State `Config/<name>`; one with flags registers `Config/<name>/flags` (network names `State/Config/...`). Defining after the network started errors. Config names and flag names are unique (flag names across all configs).
- **Add the config to the app on the server** (`app:addSystem(GameConfig)`, or a systems folder). It is the system that replicates shared values, evaluates flags on join, runs group lookups and the live source. Adding it on the client too is harmless. `use(GameConfig)` from systems that read flags in `playerAdded`, so flags are evaluated first.
- **Server-only is the default.** `Config.value` is never sent. But the shared module's source ships to clients, so a default written in it is public: never write a real secret as a default. Supply secrets from a server-only source: `override` from a ServerStorage module, or a live source.
- **Reads are plain table lookups** on a table that is updated in place. Read `GameConfig.values.X` when you need it (or `observe`); a copied `local x = GameConfig.values.X` doesn't follow live changes. Unknown names error; assigning errors; tables are deep-frozen.
- **Clients** have only shared values, starting from the code value and replaced by the server's in the ready handshake (before client `start`). Reading or observing a server-only value on a client errors.
- **Flags are evaluated on the server**, once per player at join (in the config's `playerAdded`), and again when a flag's rule changes (override, live source, environment), when group lookups finish, or on `Config.reevaluate`. `enabled` on a player not yet evaluated evaluates on the spot.
- **Rule semantics:** `enabled = false` wins. No targeting fields → on for everyone. Otherwise on if the player matches any of `users`, `percent`, `groups`, `segments`, `when`. Percent uses FNV-1a of `"<flag>/<UserId>"` mod 10000: the same on every server, and players in at 10% stay in at 20%. Each flag hashes differently.
- **Groups** are looked up at join with `player:GetRankInGroup`, all groups in parallel. `playerAdded` waits at most 5 s; until then group rules count as "not a member"; late answers still re-evaluate. A failed lookup warns and counts as rank 0.
- **Custom checks (`when`)** run on the server and must not yield. One that yields or errors counts as false and warns. Call `Config.reevaluate(player)` when what it reads changes.
- **Clients see only their own flags**, and only those that are on (`Config/<name>/flags` is per player, owner-only). `enabled(otherPlayer)` on a client is false.
- **Live sources:** fetched once in `start` (boot waits at most 5 s; a late answer still applies), then every `refresh` seconds on `Hydrogen.Clock`, plus whenever the source pushes. Each name is checked against its schema (values) or compiled (flag rules) on its own: an invalid one is rejected with a warning and the last good value kept; a missing one falls back to the lower layers; an unknown one warns. A failed fetch keeps everything. Each distinct warning prints once. Flag rules from a source can't contain functions. `app:stop()` stops refreshing and unsubscribes.
- **Experience Configs:** each value or flag is the config key of the same name (string, number, boolean, or a JSON object for a flag rule such as `{"percent": 25}`). Changes published in the Creator Hub reach running servers within about a minute; the snapshot's `UpdateAvailable` triggers a refresh. Only the global snapshot is used (`GetConfigAsync`); Roblox's own per-player targeting is not.
- **Cost:** nothing at require time. No State, no network names without shared values or flags. No timers without a source. Reads are one table index; `enabled` is one table index after the first evaluation. Idle servers do no per-frame work.
- **Under loopback (tests)** `values` is the server's copy; read the client's view with `t:as(player, GameConfig.replica, GameConfig)`. `flag:enabled(player)` inside `t:as` reads that client's replica.

## Recipes

Secrets from a server-only module:
```luau
-- ServerScriptService/Systems/Secrets.luau
local Secrets = require(game:GetService("ServerStorage").Secrets) -- { WebhookUrl = "https://..." }
return Hydrogen.define(function(use)
	local GameConfig = use(GameConfigModule)
	return {
		init = function()
			GameConfig:override({ WebhookUrl = Secrets.WebhookUrl })
		end,
	}
end)
```

Gradual rollout from the Creator Hub, without a deploy:
```luau
-- In code: off by default.
flags = { NewShop = Config.flag({ percent = 0 }) },
source = Config.experienceConfigs(),
-- In Experience Configs: add key NewShop = {"percent": 10}, publish; later {"percent": 50}; then true.
```

React to a live value change:
```luau
function Rounds:start()
	Hydrogen.Scope.of(self):add(GameConfig:observe("RoundLength", function(seconds: number)
		roundTimer:setLength(seconds)
	end))
end
```

Target a role from another system (custom segment + reevaluate):
```luau
segments = {
	Moderators = function(player: Player): boolean
		return Roles.has(player, "Moderator") -- must not yield
	end,
},
flags = { ModTools = Config.flag({ segments = { "Moderators" } }) },
-- when a role changes:
Roles.changed:Connect(function(player) Hydrogen.Config.reevaluate(player) end)
```

Gate a library feature by flag name (for kit modules that don't own the config):
```luau
local flag = Hydrogen.Config.findFlag("DebugOverlay")
local allowed = flag ~= nil and flag:enabled(player)
```

DataStore source with instant push to every server:
```luau
source = Config.dataStore("LiveConfig", { key = "config", topic = "LiveConfigChanged" }),
-- an admin tool (server):
DataStoreService:GetDataStore("LiveConfig"):SetAsync("config", { RoundLength = 120, Holiday = true })
MessagingService:PublishAsync("LiveConfigChanged", "")
```

## Mistakes

- Don't put a secret as a `Config.value` default in a ReplicatedStorage module; its source is downloaded by clients. Do supply it with `override` from ServerStorage or a live source.
- Don't use `Config.shared` for anything clients mustn't see. Do default to `Config.value` and opt in per value.
- Don't cache `local length = GameConfig.values.RoundLength` at module load. Do read `GameConfig.values.RoundLength` when you use it, or `observe` it.
- Don't assign `GameConfig.values.X = ...`. Do `GameConfig:override({ X = ... })` on the server.
- Don't forget `app:addSystem(GameConfig)` on the server. Without it clients never get shared values or flags, group rules never load and the live source never runs (a warning tells you once the network is up).
- Don't read flags in another system's `playerAdded` without `use(GameConfig)`. Do `use` it so flags are evaluated first.
- Don't yield in `when` checks or segment functions (`GetRankInGroup`, DataStore calls). Do use `groups`/`minRank`, or cache what the check needs and call `Config.reevaluate(player)` when it changes.
- Don't define the config in a server-only or client-only module. Do define it in a shared module both sides require before `app:start()`.
- Don't call `flag:enabled()` without a player. Do `flag:enabled(player)`; on the client pass `Players.LocalPlayer`.

## Testing

```luau
local GameConfig = require(ReplicatedStorage.Shared.GameConfig) -- source = Config.memory() in tests, or define a test config
Hydrogen.test({ systems = { GameConfig, Shop }, players = { "Alice", "Bob" } }, function(t, alice, bob)
	-- Environment overrides
	Hydrogen.Config.useEnvironment({ kind = "studio" })
	assert(GameConfig.values.RoundLength == 20)

	-- Force a flag or value for this test (server)
	GameConfig:override({ NewShop = { users = { alice.UserId } }, RoundLength = 5 })
	assert(GameConfig.flags.NewShop:enabled(alice) and not GameConfig.flags.NewShop:enabled(bob))

	-- What a client sees: flush State with t:advance(0), then read inside t:as
	t:advance(0)
	assert(t:as(alice, GameConfig.flags.NewShop.enabled, GameConfig.flags.NewShop, alice))
	assert(t:as(alice, GameConfig.replica, GameConfig).RoundLength == nil) -- server-only: never sent
end) -- closing resets overrides, live values, the environment and flags
```
- Live sources: give the config `source = Config.memory()` (keep a reference). `memory:set(name, value)` then `t:advance(refresh)` applies it on the schedule; `memory:push()` applies at once; `memory:fail("msg")` makes fetches error. Rejections are warnings: `t:expectWarning("rejected <Name>")`.
- Group rules: fake players are tables; give one a method before the app starts (`start = false`, then `t:start()`): `(alice :: any).GetRankInGroup = function(_, groupId) return 255 end`.
- Percent rollouts are deterministic: a fake player's result depends only on the flag name and its (negative) UserId.
- `Config.reset()` runs on harness close. Outside `Hydrogen.test`, call it between tests.
- A source that yields in `fetch` makes `t:start()` wait up to 5 s of fake time: start the app in `task.spawn` with `start = false` and `t:advance(5)`.

## Errors and warnings

Errors (at the caller's line):
| Message | Meaning / fix |
| --- | --- |
| `Config.value expects a GreenTea schema (Hydrogen.gt), got <type>` | Pass `Hydrogen.gt.<type>(...)`. |
| `Config.value: the default doesn't match the schema: ...` | Fix the default or the schema (`gt.optional` for nil). |
| `Config.flag expects a boolean or a rule table` | Pass `true`, `false` or a `FlagRule`. |
| `Config <name>: values.<X> must be Config.value(schema, default) or Config.shared(schema, default)` | Wrap the value. |
| `Config <name>: flags.<X> must be Config.flag(rule)` | Wrap the rule. |
| `Config <name>: environments.<kind> sets <X>, which isn't a declared value or flag` / `... which doesn't match the schema: ...` / `... which <rule problem>` | Typo or wrong type in an environment table. |
| `Config <name>: unknown environment <x> (expected studio, private, reserved, live or places)` | Use one of those keys. |
| `Config <name>: environments.places must be keyed by place id numbers` | `places = { [123456] = { ... } }`. |
| `Config <name>: flags.<X>: percent must be a number from 0 to 100` / `unknown rule field ...` / `segment <S> isn't declared in this config's segments` / `users must be an array of UserIds` / `groups must be an array of group ids` / `when must be a function` | Fix the rule. |
| `Config <name>: segment <S>: minRank needs groups` / `minRank must be a rank from 1 to 255` / `unknown segment field ...` | Fix the segment. |
| `Config <name>: <X> is both a value and a flag; names must be unique` | Rename one. |
| `Config <name>: a flag named <X> already exists in config <other>; flag names are global` | Rename one. |
| `Config <name>: flags.<X> is already part of config <other>` | Call `Config.flag` again for each flag. |
| `Config <name> is already defined` | Require the shared module instead of redefining. |
| `Config <name> was defined after the network started` | Define it in a shared module required before `app:start()`. |
| `Config <name>: unknown field <x>` / `refresh must be a positive number of seconds` / `source must have a fetch method` | Fix the spec. |
| `Config <name> has no value named <X>` / `has no flag named <X>` / `<X> is a flag; read it with flags.<X>:enabled(player)` | Typo, or use the flag API. |
| `Config <name>: <X> is server-only, so clients can't read it. Declare it with Config.shared(...)` | On a client; make it shared or read it on the server. |
| `Config <name>: values are read-only` / `flags are read-only` | Use `override`. |
| `Config <name>: override sets <X>, which ...` | The override is invalid; same checks as declarations. |
| `Config <name>: override|clearOverrides|refresh only works on the server` | Call on the server. |
| `Config <name> has no live source` | `refresh` needs `source`. |
| `Flag <X>: pass the player (:enabled(player, ...))` | Pass a Player. |
| `This flag isn't part of a config yet` | Put it in `Config.define`'s `flags` first. |
| `No feature flag named <X>` | `getFlag` found nothing; use `findFlag` for optional flags. |
| `Config.useEnvironment: kind must be ...` / `placeId must be a number` | Fix the argument. |
| `Config.reevaluate only works on the server` / `expects a player or nil` | As stated. |

Warnings:
| Message | Meaning / fix |
| --- | --- |
| `Config <name>: rejected <X> from live source <src>: it ...; keeping the last good value|the value from code` | The remote value failed its schema or rule check. Fix it at the source. |
| `Config <name>: live source <src> sent <X>, which isn't a declared value or flag; ignored` | Remove it remotely, or declare it. |
| `Config <name>: live source <src> failed: <error>; keeping the last good values` | Fetch errored (e.g. no Experience Configs published yet, DataStore outage). Retries on schedule. |
| `Config <name>: live source <src> returned a <type>, not a table of values` / `key <k> holds a <type>, not a table of values` | The DataStore key holds the wrong shape. |
| `Config <name>: live source <src> could not subscribe: ...` / `could not subscribe to topic <t>` | Push failed; scheduled refresh still works. |
| `Config <name>: could not look up <player>'s rank in group <id>: ...` | Group service error; they count as outside the group. |
| `Config <name>: flag|segment <X>'s when failed|yielded for <player>` | Fix the custom check; it counted as false. |
| `Config <name> isn't in the app, so clients never see its flags and group rules never load` | `app:addSystem(GameConfig)` on the server. |
| `Observer of Config <name>.<X> failed` / `Observer of flag <X> failed` | Your observer errored; others still ran. |
| `Config <name>: the server sent <X>, which isn't a shared value here` / `the server sent an invalid <X>` | Client and server require different config modules. |
| `Config <name>: stopping the live source failed` | The source's unsubscribe errored. |

## Works with

- **State (`state.md`):** shared values are a `State.map("Config/<name>")`; each player's on-flags are a `State.playerMap("Config/<name>/flags")` (owner-only). State gives the handshake snapshot, per-frame batching, owner-only visibility and per-client replicas under loopback.
- **Systems (`systems.md`):** a config is a system (`Hydrogen.Config/<name>`); `use` it for boot order.
- **Clock (`clock.md`):** refreshes and the 5 s waits run on `Hydrogen.Clock`, so `t:advance` drives them.
- **Scope (`scope.md`):** `observe` returns a disconnect function: `Hydrogen.Scope.of(self, player):add(flag:observe(player, fn))`.
- **Testing (`testing.md`):** `Hydrogen.test` resets Config on close; use `Config.memory()` and `Config.useEnvironment` in tests.
- **Other kit modules:** gate features by flag name with `Config.findFlag(name)`; express roles as segments with a `when` function plus `Config.reevaluate(player)`.
