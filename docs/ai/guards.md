# Hydrogen.Guards (cooldowns, roles, permissions, range checks, predicates)

> Server-side game rules for incoming network traffic, written as middleware: attach a guard with `:Use()`, `:UseRequest()` or `Hydrogen.useMiddleware`. A rejected event is dropped; a rejected function request errors back to the client with the reason. Cooldowns and roles also work from game code.

## Use it when / Don't use it when

Use it when:
- An action has a cooldown, charges, or a shared/global cooldown ("Ability1 every 5 s", "2 dashes").
- Only some players may send something: admins, moderators, group ranks, game-pass owners, a custom list.
- A client names a target (position, part, model, player) that must be near their character.
- Any other per-message rule: write `Guards.check(fn)` and combine with `Guards.all` / `Guards.any`.

Don't use it when:
- Limiting volume: use `Hydrogen.rateLimit` (see `middleware.md`). Use both together.
- Validating payload shapes: GreenTea schemas already do that, after incoming middleware.
- The rule depends on state the handler changes (mana, inventory): check and spend inside the handler; you can still call `cooldown:use(player)` there.

## Quick start

```luau
-- ReplicatedStorage/Network/Combat.luau (shared)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Fireball = Hydrogen.clientEvent("Fireball", gt.Vector3()),
	Ban = Hydrogen.clientFunction("Ban", gt.args(gt.number()), gt.returns(gt.boolean())),
}
```

```luau
-- ServerScriptService/Systems/Combat.luau (server)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Combat = require(ReplicatedStorage.Network.Combat)
local Guards = Hydrogen.Guards

-- Define roles and permissions once, at module top level.
Guards.defineRole("admin", Guards.userIds({ 12345, 67890 }))
Guards.defineRole("mod", Guards.groupRank(4242, 200), "admin")
Guards.definePermission("ban", { "admin", "mod" })

local fireballCooldown = Guards.cooldown(5, { name = "Fireball", charges = 2 })

return Hydrogen.define(function()
	local CombatSystem = {}

	function CombatSystem:init()
		Combat.Fireball:Use(Guards.all(Guards.range(60), fireballCooldown:guard()))
		Combat.Fireball:On(function(player: Player, target: Vector3)
			-- only fireballs that passed every guard get here
		end)

		Combat.Ban:UseRequest(Guards.permission("ban"))
		Combat.Ban:On(function(player: Player, userId: number): boolean
			return true
		end)
	end

	return CombatSystem
end)
```

A client calling `Combat.Ban:Fire(1)` without the permission gets the error `[HYDROGEN] Ban request rejected: missing permission "ban"`.

## API

All guards are server-side: they act only on incoming events and function requests that have a `context.player`, and pass everything else through. `Guard` is `Hydrogen.AnyMiddleware`.

```luau
type GuardOptions = { reason: string?, onReject: ((context: Hydrogen.MiddlewareContext, reason: string) -> ())? }

-- Cooldowns (server, or client for prediction)
Guards.cooldown(seconds: number, options: CooldownOptions?): Cooldown
type CooldownOptions = { name: string?, charges: number?, gap: number?, group: { Cooldown }? }
cooldown:guard(options: GuardOptions?): Guard     -- drops unless ready; uses it when the message passes
cooldown:ready(player: Player): boolean            -- this cooldown and its group
cooldown:use(player: Player): boolean              -- uses it (and its group) if ready; false = nothing changed
cooldown:remaining(player: Player): number         -- seconds until ready, 0 when ready (max over the group)
cooldown:charges(player: Player): number           -- charges left, this cooldown only
cooldown:reset(player: Player?): ()                -- all charges back; nil = every player
cooldown.name: string?, cooldown.seconds: number, cooldown.maxCharges: number, cooldown.gap: number

-- Roles and permissions (server)
Guards.defineRole(name: string, ...: RoleSource): () -> ()       -- returns a remover; errors if already defined
Guards.definePermission(name: string, roles: { string }): () -> ()
type RoleSource = ((player: Player) -> boolean?) | string        -- resolver, or another role's name
Guards.userIds(ids: { number }): RoleResolver
Guards.groupRank(groupId: number, minRank: number): RoleResolver  -- YIELDS first time (GetRankInGroup)
Guards.gamePass(passId: number): RoleResolver                     -- YIELDS first time (Receipts.owns)
Guards.hasRole(player: Player, role: string): boolean             -- YIELDS on first check per player+role, then cached
Guards.can(player: Player, permission: string): boolean           -- YIELDS like hasRole
Guards.rolesOf(player: Player): { string }                        -- every defined role held, sorted; YIELDS like hasRole
Guards.invalidate(player: Player?): ()                            -- drop cached answers (one player, or everyone); resends Hydrogen.Commands lists
Guards.role(name: string, options: GuardOptions?): Guard
Guards.permission(name: string, options: GuardOptions?): Guard

-- Range (server)
Guards.range(studs: number, options: RangeOptions?): Guard
type RangeOptions = GuardOptions & { arg: number?, target: ((player: Player, ...any) -> any)?, slack: number? }
Guards.inRange(player: Player, target: any, studs: number, slack: number?): boolean
Guards.distance(player: Player, target: any): (number?, string?)  -- nil, "no character" | "invalid target"
Guards.configure(options: { position: ((player: Player) -> Vector3?)?, slack: number? }): ()
Guards.resetConfiguration(): ()                                   -- default position lookup, slack 4

-- Predicates and composition (server)
Guards.check(predicate: (player: Player, ...any) -> (boolean, string?), options: GuardOptions?): Guard
Guards.all(...: Guard): Guard
Guards.any(...: Guard): Guard
Guards.onReject(hook: (context: Hydrogen.MiddlewareContext, reason: string) -> ()): () -> ()  -- every rejection
Guards.isGuard(value: any): boolean
```

Exported types: `Hydrogen.Guard`, `Hydrogen.GuardOptions`, `Hydrogen.GuardRejectHook`, `Hydrogen.Cooldown`, `Hydrogen.CooldownOptions`, `Hydrogen.RoleResolver`, `Hydrogen.RoleSource`, `Hydrogen.GuardPredicate`, `Hydrogen.RangeOptions`, `Hydrogen.GuardsConfigureOptions`.

Reasons sent by built-in guards: `<name> is on cooldown (2.5s left)` (or `on cooldown (...)` without a name), `missing role "<role>"`, `missing permission "<permission>"`, `target out of range (31.2 studs, at most 24)`, `invalid target`, `no character`, `not allowed` (a `check` with no reason, or one that errored).

## Rules

- **Rejection:** an event is dropped (`Hydrogen.DROP`). A function request raises `[HYDROGEN] <name> request rejected: <reason>`, which the client's `Fire` re-raises. `options.reason` replaces `<reason>`.
- **onReject** (per guard) runs first, then every `Guards.onReject` hook. Each runs in its own thread, so they can yield or kick. Errors are warned (`Guards onReject failed for ...`), and the message is still rejected. In `all`, the onReject of the guard that failed runs. In `any`, the last guard's runs, and its reason is the one sent.
- **Incoming middleware runs before schema validation.** Predicates, `range`'s `target` function and the arg `range` reads get raw client values. Built-ins type-check what they read. Your `Guards.check` must too.
- **Cooldowns are used last and atomically.** A guard (or `Guards.all`) runs every check first, then checks every cooldown and uses them all in one step that can't yield. So a failing role check never costs a charge, and two messages can't take the last one. A cooldown shared by several guards in one `all` is used once. Inside `Guards.any`, a branch's cooldowns are used as soon as that branch passes, so put `any(...)` last inside an `all`.
- **Charges** come back one at a time, `seconds` after each use (token bucket). `gap` is a minimum spacing between uses, even with charges left. `group` cooldowns must be ready too, and are used too. The group is fixed at creation, so it can't form a cycle.
- **Cooldown time** is `Hydrogen.Clock.now()`, read at call time, so `t:advance` works. State written under another clock (a fake clock came or went) is discarded instead of blocking forever.
- **Roles:** a role is held when any source says so, checked in order. A resolver returns `true` (held, cached), `false` (not held, cached) or `nil` (not held, not cached). A resolver that errors counts as `nil` and is warned. `Guards.gamePass` returns `nil` instead of `false`, so a pass bought in game counts at once: `Receipts.owns` keeps its own cache and updates it on purchase.
- **Caching:** answers are cached per player for the session. Checks made while a role resolves wait for the same answer instead of resolving again. An answer is not cached if the player left meanwhile, or if `invalidate` or `defineRole` ran meanwhile. `invalidate(player)` drops every cached role for that player, including roles held through other roles.
- **Unknown names error:** `Guards.hasRole` / `Guards.role` with an undefined role, or `can` / `permission` with an undefined permission, raise `[HYDROGEN] Unknown role ...` when checked. Inside middleware the message is lost and the error is printed. Define roles before players can send.
- **Defining twice errors.** Define roles at module top level, not in `init`, because `init` runs again in every test. Use the returned remover to redefine.
- **Range:** distance is from the sender's character position (`HumanoidRootPart`, else `PrimaryPart`, or `Guards.configure({ position })`) to the target, and passes when it is at most `studs + slack`. Default slack is 4 studs. Targets can be `Vector3`, `CFrame`, `BasePart`, `Model` (pivot), `Attachment` (`WorldPosition`) or a `Player` (their character). NaN or infinite positions, other types, and Instances that error are `invalid target`. No character means `no character`.
- **Cleanup:** cooldown state and cached roles for a player are cleared when they leave (`Players.PlayerRemoving`, or the loopback's leave). Nothing new is stored for a player who has left. Tracking starts on first use, so a game that never uses Guards pays nothing.
- **Cost:** a cooldown is one number per player (two with `gap`). A cached role check is two table lookups. Passing messages allocate nothing.

## Recipes

**Global cooldown shared by every ability, plus per-ability cooldowns.**

```luau
local GCD = Guards.cooldown(1, { name = "Global cooldown" })
local Fireball = Guards.cooldown(5, { name = "Fireball", group = { GCD } })
local Frost = Guards.cooldown(8, { name = "Frost", group = { GCD } })

Combat.Fireball:Use(Fireball:guard())
Combat.Frost:Use(Frost:guard())
```

**Admins skip the cooldown; everyone else is rate- and cooldown-limited.**

```luau
Combat.Fireball:Use(Hydrogen.rateLimit({ perSecond = 10 }))
Combat.Fireball:Use(Guards.any(Guards.role("admin"), Fireball:guard()))
```

**Kick on obviously impossible requests, log the rest.**

```luau
Guards.onReject(function(context, reason)
	print(`[guards] {context.name} from {context.player}: {reason}`)
end)

Combat.Teleport:Use(Guards.range(500, {
	onReject = function(context, _reason)
		if context.player then
			context.player:Kick("Invalid teleport")
		end
	end,
}))
```

**Roles granted at runtime (e.g. by an admin command).**

```luau
local granted: { [Player]: boolean } = {}
Guards.defineRole("helper", function(player: Player): boolean?
	return granted[player] == true
end)

local function grantHelper(player: Player)
	granted[player] = true
	Guards.invalidate(player) -- cached "false" must go
end
```

**Range check on a target inside a table argument, with type checks.**

```luau
-- Interact = Hydrogen.clientEvent("Interact", gt.table({ part = gt.Instance() }))
Remotes.Interact:Use(Guards.range(12, {
	target = function(_player: Player, payload: any): any
		return if type(payload) == "table" then payload.part else nil
	end,
}))
```

**Cooldown spent only when the handler succeeds.**

```luau
local Craft = Guards.cooldown(2)
Remotes.Craft:On(function(player: Player, recipe: string)
	if not Craft:ready(player) or not canCraft(player, recipe) then
		return
	end
	Craft:use(player)
	craft(player, recipe)
end)
```

## Mistakes

- Don't hand-roll `if not ADMINS[player.UserId] then return Hydrogen.DROP end` in every middleware. Use `Guards.role("admin")`, which caches and gives function callers a reason.
- Don't call `Guards.defineRole` inside a system's `init`. It runs once per app and errors the second time, for example in the next test. Define roles at module top level.
- Don't put a cooldown guard on its own before other guards in separate `:Use` calls and expect atomicity. Combine them in one `Guards.all(...)`, which uses cooldowns only when everything passes.
- Don't index raw arguments in `Guards.check` without type checks. Do `if type(amount) ~= "number" then return false, "bad amount" end`.
- Don't use `Guards.gamePass` without adding `Hydrogen.Receipts` to the app. Without it, every check for a non-owner calls `UserOwnsGamePassAsync`, which yields.
- Don't forget `Guards.invalidate(player)` after changing what a custom resolver reads.
- Don't wrap a cooldown object itself in `Guards.all`. Pass `cooldown:guard()`.

## Testing

Under `Hydrogen.test`, guards see loopback players and the fake clock:

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt
local Guards = Hydrogen.Guards

local Cast = Hydrogen.clientEvent("Test/Cast", gt.number())
local Ask = Hydrogen.clientFunction("Test/Ask", gt.args(gt.number()), gt.returns(gt.string()))
local admins: { [Player]: boolean } = {}
Guards.defineRole("test-admin", function(player: Player): boolean?
	return admins[player] == true
end)

Hydrogen.test({ players = { "Alice", "Bob" } }, function(t, alice, bob)
	local fireball = Guards.cooldown(5, { charges = 2 })
	Cast:On(function() end)
	Cast:Use(fireball:guard())
	t:as(alice, function()
		Cast:Fire(1); Cast:Fire(2); Cast:Fire(3)
	end)
	t:expect(Cast):firedTimes(2)
	t:advance(5)
	assert(fireball:charges(alice) == 1)

	admins[alice] = true
	Ask:On(function(_player: Player, n: number): string
		return tostring(n)
	end)
	Ask:UseRequest(Guards.role("test-admin"))
	local ok, err = t:as(bob, function()
		return pcall(Ask.Fire, Ask, 1)
	end)
	assert(not ok and string.find(tostring(err), `missing role "test-admin"`, 1, true))
end)
```

- Fake players have no `Character` and no `GetRankInGroup`. Use `Guards.configure({ position = function(player) return positions[player] end })` (then `Guards.resetConfiguration()`), and either function roles or `(player :: any).GetRankInGroup = function(_, groupId) return 200 end`.
- `Guards.gamePass` in tests: `Receipts.configure({ marketplace = Receipts.fakeMarketplace() })`, then `market:setOwnsGamePass(player, passId, true)`.
- Role definitions and cached answers outlive a test. Call `Guards.invalidate()` at the start of tests that change resolver inputs.
- Cooldown state for a player is cleared when the harness closes, because every fake player leaves.
- Under Lune, the harness compares `Vector3` arguments by identity. Match them with `t.any` and compare `t:deliveries(obj)[1].args[1]` yourself.

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] <name> request rejected: <reason>` | A guard rejected a function request. Expected; the client sees it. |
| `[HYDROGEN] Unknown role "<role>"; define it with Guards.defineRole(...)` | Typo, or the role is defined after it is checked. |
| `[HYDROGEN] Unknown permission "<p>"; define it with Guards.definePermission(...)` | Same, for permissions. |
| `[HYDROGEN] Role "<role>" is already defined; ...` | Defined twice. Move it to module top level, or call the remover first. |
| `[HYDROGEN] Role "<role>" includes itself through other roles; remove the cycle` | Role names refer to each other in a loop. |
| `[HYDROGEN] Role "<role>" needs at least one resolver ...` / `resolver <i> must be a function or a role name` | Bad `defineRole` arguments. |
| `[HYDROGEN] Permission "<p>" needs a list of role names ...` | Bad `definePermission` arguments. |
| `[HYDROGEN] Role "<role>" resolver failed for <player>; treating it as not having the role: <err>` (warning) | Your resolver errored. The answer is not cached. Fix the resolver. |
| `[HYDROGEN] Couldn't get <player>'s rank in group <id>: <err>` (warning) | `GetRankInGroup` failed. The answer is not cached and is retried next check. |
| `[HYDROGEN] Guards.check predicate failed on <name>; rejecting: <err>` (warning) | Your predicate errored, usually from indexing an unvalidated value. |
| `[HYDROGEN] Guards.range target function failed on <name>: <err>` (warning) | Your `target` function errored. Rejected as `invalid target`. |
| `[HYDROGEN] Guards position function failed; ...` (warning) | `configure({ position })` errored. Treated as no character. |
| `[HYDROGEN] Guards onReject failed for <name>: <err>` (warning) | A hook errored. The message is still rejected. |
| `[HYDROGEN] Guards.all expects guards made by Hydrogen.Guards ...` / `Guards.any ...` | You passed a plain function or a cooldown. Wrap logic in `Guards.check(fn)` and use `cooldown:guard()`. |
| `[HYDROGEN] Guards.all needs at least one guard` / `Guards.any needs at least one guard` | Empty combinator. |
| `[HYDROGEN] Guards.cooldown expects a positive number of seconds ...` / `charges must be a whole number ...` / `gap must be ...` / `group must hold cooldowns ...` | Fix the cooldown options. |
| `[HYDROGEN] Guards.range expects a non-negative number of studs ...` / `arg must be an argument position ...` / `slack must be ...` | Fix the range options. |
| `[HYDROGEN] Guards.userIds ...` / `Guards.groupRank ...` / `Guards.gamePass ...` | Wrong resolver argument types or a rank outside 1-255. |

## Works with

`middleware.md` (ordering, `DROP`, `rateLimit`), `network.md`, `receipts.md` (`owns` behind `Guards.gamePass`), `testing.md` (`t:advance`, `t:as`, expectations), `clock.md`.

- `commands.md`: a command's `permission = "name"` is answered by `Guards.can` when you defined a permission with that name, or `Guards.hasRole` for a role with that name. `Guards.invalidate(player)` (and defining or removing a role) resends command lists, so `help` and autocomplete stay right.
- `debug.md`: define the permission `"debug"` (`Guards.definePermission("debug", { "staff" })`) to let those players open the overlay's server data in live servers.
- `character.md` / character hooks: range checks read `player.Character`, which the harness's `t:spawnCharacter` sets, so range guards work in tests with fake characters.
- `config.md`: a Config segment can be a role (`segments = { Staff = function(player) return Guards.hasRole(player, "staff") end }`); call `Config.reevaluate(player)` after `Guards.invalidate(player)`.
