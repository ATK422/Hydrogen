# Hydrogen systems (`Hydrogen.define`)

> A system is a ModuleScript that returns `Hydrogen.define(...)`: a singleton with optional lifecycle hooks (`init`, `start`, `playerAdded`, `playerRemoving`, `characterAdded`, `characterRemoving`, `stop`) that Hydrogen runs in dependency order. Every piece of game logic in a Hydrogen game is a system.

## Use it when / Don't use it when

- Use it for any server or client module that has setup, talks to other systems, or reacts to players joining and leaving.
- Use `use(Other)` instead of a plain `require` when your system calls another system. This records the dependency, so the other system boots first.
- Don't use it for pure helpers (math, formatting, constants). Plain ModuleScripts are fine for those.
- Don't use it for network definitions. Those are shared modules that return network objects (see `network.md`).

## Quick start

```luau
-- ServerScriptService/Systems/Coins.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function(use)
	local Coins = {}
	local balances: { [Player]: number } = {}

	function Coins:playerAdded(player: Player)
		balances[player] = 0
	end

	function Coins:playerRemoving(player: Player)
		balances[player] = nil
	end

	function Coins.get(player: Player): number
		return balances[player] or 0
	end

	function Coins.add(player: Player, amount: number)
		balances[player] = Coins.get(player) + amount
	end

	return Coins
end)
```

```luau
-- ServerScriptService/Systems/Rewards.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local CoinsSystem = require(script.Parent.Coins)

return Hydrogen.define(function(use)
	local Coins = use(CoinsSystem) -- Coins boots first; its playerAdded runs before ours

	local Rewards = {}

	function Rewards:playerAdded(player: Player)
		Coins.add(player, 100) -- Coins:playerAdded already ran for this player
	end

	return Rewards
end)
```

## API

| Signature | Notes |
| --- | --- |
| `Hydrogen.define<T>(constructor: (use) -> T): Defined<T>` | The id is the calling ModuleScript's name. Call it once, at the top level of the module. |
| `Hydrogen.define<T>(id: string, constructor: (use) -> T): Defined<T>` | Explicit id. Required when `define` is called through a wrapper function. |
| `use<T>(other: Defined<T>): System<T>` | Records a dependency and returns `other`, typed without its lifecycle fields. Synchronous, inside the constructor only. |
| `system:init()` | Optional. Runs after sorting, before the network starts. Sets up the system's own state. |
| `system:start()` | Optional. Runs after every `init` and after the network starts. The client yields for the network before this. |
| `system:playerAdded(player: Player)` | Optional. Runs in dependency order, for players already present and for later joins. Runs on the client too, for every player. |
| `system:playerRemoving(player: Player)` | Optional. Runs in **reverse** dependency order. |
| `system:characterAdded(player: Player, character: Model)` | Optional. Runs in dependency order for each character, after that player's `playerAdded` hooks. Server and client. See `character.md`. |
| `system:characterRemoving(player: Player, character: Model)` | Optional. Reverse dependency order, before that player's `playerRemoving`. See `character.md`. |
| `system:stop()` | Optional. Runs in reverse dependency order on `app:stop()`, which the server binds to `BindToClose`. |

Types: `Hydrogen.Defined<T>` (a system with its hooks), `Hydrogen.System<T>` (without them), `Hydrogen.Lifecycle`.

## Rules

- Hooks are called with `:`, so they receive the system as `self`. Every hook is optional.
- Boot order: sort by dependencies, run every `init`, start the network, run every `start`, then start the player hooks. On the server it also binds `app:stop()` to `BindToClose`.
- Systems with no dependency between them boot in the order they were added.
- An error in `init` or `start` stops the boot: `[HYDROGEN] System <full name> failed in <hook>: <traceback>`.
- An error in `playerAdded`, `playerRemoving` or `stop` is only warned, and the remaining systems still run. One broken system can't stop saving.
- The hooks for one player run one after another, in one thread. A hook that yields (a DataStore call) delays the later systems' hooks **for that player**. Different players don't wait for each other.
- A system's `playerAdded` runs only after the `playerAdded` of every system it `use`s has returned. That's how dependents see loaded state.
- `playerRemoving` waits for that player's `playerAdded` hooks to finish. Each system sees `playerAdded` exactly once, then `playerRemoving` exactly once.
- `stop` first runs `playerRemoving` for every remaining player, waits for all of them to return, then runs the `stop` hooks.
- A system added after `app:start()` gets `init`, `start` and then `playerAdded` for players already in the game.
- A system you `use` is added to the app for you at `app:start()` (or with the system, when it's added after start) if you didn't add it, and boots first. With `debug = true` the app prints `[HYDROGEN] Added <Y>: <X> uses it`. A system replaced with `app:replace` doesn't bring its own dependencies: the fake stands in for it.
- `characterAdded` / `characterRemoving` follow the same guarantees as the player hooks, per character (see `character.md`).
- Messages name systems by their module's full name (e.g. `ServerScriptService.Lobby.Systems.Data`), so two systems with the same name can be told apart.

## Recipes

**Per-player state with cleanup.**

```luau
function Combat:playerAdded(player: Player)
	health[player] = 100
end

function Combat:playerRemoving(player: Player)
	health[player] = nil
end
```

**Recording something before data saves.** `playerRemoving` runs in reverse order, so a system that `use`s Data runs its hook before Data saves:

```luau
local Data = use(DataSystem)

function Match:playerRemoving(player: Player)
	if inMatch[player] then
		Data.recordForfeit(player) -- Data:playerRemoving (the save) runs after this
	end
end
```

**Listening to the network.** Register listeners in `start`. The network is live there, and `init` is too early for functions.

```luau
function ChatServer:start()
	Remotes.SendMessage:On(function(player, text)
		Remotes.MessagePosted:FireAll(player.Name, text)
	end)
end
```

**Explicit id inside a wrapper.**

```luau
local function makeSpawner(id: string)
	return Hydrogen.define(id, function(use)
		return {}
	end)
end
```

## Mistakes

- Don't call `use` in a hook or after a yield; call it synchronously in the constructor.
- Don't `require` another system and call it without `use`. The boot order isn't guaranteed then, so it may not be initialized yet.
- Don't copy fields out of a dependency (`local add = use(Coins).add`). `app:replace` can't redirect a copied function in tests. Keep the table and call `Coins.add(...)`.
- Don't call another system's runtime state from `init`, because it may not have run yet. Wait until `start` or a player hook.
- Don't connect `Players.PlayerAdded` / `PlayerRemoving` yourself. Use the hooks: they're ordered, they cover players already in the game, and they keep running after an error in another system.
- Don't yield for a long time in `playerAdded` unless later systems need that work done first. Use `task.spawn` for work they don't depend on.
- Don't connect `player.CharacterAdded` yourself. Define `characterAdded` / `characterRemoving` (see `character.md`).
- Don't `table.freeze` a system table or lock its metatable, or it can't be replaced in tests.
- Don't create cycles (`A` uses `B` uses `A`). Move the shared part into a third system.

## Testing

Use `app:replace(original, fake)` to swap a dependency, and `Hydrogen.loopback()` to run the server and clients in one VM. See `loopback.md`, and `testing.md` for the test harness.

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] System X depends on system Y which was not added to the app` | Only for a system replaced with `app:replace`: the fake stands in for `X`, so `X`'s dependencies aren't added. Add `Y` yourself if something else needs it, or ignore it in tests. Used systems are otherwise added for you. |
| `[HYDROGEN] Cyclic system dependency: A -> B -> A` | Break the cycle; move the shared logic into a third system. |
| `[HYDROGEN] System <name> failed in init/start: ...` | Your hook errored and the boot stopped. Fix the error shown in the traceback. |
| `[HYDROGEN] playerAdded/playerRemoving/characterAdded/characterRemoving/stop failed in system <name>: ...` | Your hook errored. The other systems still ran. |
| `[HYDROGEN] define(id, constructor) needs a non-empty id and a constructor function` | Wrong arguments to `define`. |
| `[HYDROGEN] Tried to collect "system" but it was not a valid system: <path>` | A ModuleScript in a systems folder doesn't return `Hydrogen.define(...)`. Move it out, or define it as a system. |

## Works with

- `app.md`: adding systems and booting.
- `character.md`: the character hooks and per-character scopes.
- `network.md`: listeners are registered from `start`.
- The kit modules (`data.md`, `player-state.md`, `state.md`, `scope.md`, `receipts.md`) are systems or factories for systems. `use` them like any other system.
