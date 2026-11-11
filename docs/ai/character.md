# Character hooks (`characterAdded` / `characterRemoving`)

> Optional system hooks that run for every player's character in dependency order, on the server and the client, with a scope per character (`Hydrogen.Scope.of(self, character)`) that is cleaned when the character goes. Reach for them instead of connecting `player.CharacterAdded` yourself.

## Use it when / Don't use it when

Use it when:
- A system sets something up on each character (health bars, nametags, tools, hitboxes, `Humanoid.Died` handlers) and must undo it when the character respawns, is destroyed or the player leaves.
- A system's character logic needs another system's per-player state (`use(PlayerData)`): `characterAdded` runs only after every `playerAdded` for that player returned, so the data is loaded.
- A client system decorates other players' characters, which arrive late and stream in and out.

Don't use it when:
- You need the moment the humanoid dies. That's `humanoid.Died`; connect it in `characterAdded` on the character scope. `characterRemoving` runs when the character is replaced or removed, not when it dies.
- You only need a player-lifetime thing (data, leaderstats). Use `playerAdded` / `playerRemoving`.
- You want to spawn characters. Keep calling `player:LoadCharacter()` (server); the hooks follow it.

## Quick start

```luau
-- ServerScriptService/Systems/Combat.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Scope = Hydrogen.Scope
local PlayerDataStore = require(script.Parent.PlayerData) -- a Hydrogen.Data.player store

return Hydrogen.define(function(use)
	local PlayerData = use(PlayerDataStore) -- its playerAdded (the load) runs before our characterAdded

	local Combat = {}

	function Combat:characterAdded(player: Player, character: Model)
		-- Destroyed right after Combat's characterRemoving for this character.
		local scope = Scope.of(self, character)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.MaxHealth = 100 + PlayerData:get(player).level * 10
		humanoid.Health = humanoid.MaxHealth

		scope:connect(humanoid.Died, function()
			PlayerData:update(player, function(data)
				data.deaths += 1
				return nil
			end)
		end)
	end

	function Combat:characterRemoving(player: Player, character: Model)
		-- Still a live character here; Combat's scope for it is destroyed after this returns.
	end

	return Combat
end)
```

Nothing else to set up: the app runs the hooks as soon as one of its systems defines one of them.

## API

| Signature | Notes |
| --- | --- |
| `system:characterAdded(player: Player, character: Model)` | Optional hook. Server and client. Runs in dependency order, after every `playerAdded` for `player` returned. May yield. |
| `system:characterRemoving(player: Player, character: Model)` | Optional hook. Server and client. Runs in **reverse** dependency order, after every `characterAdded` for that character returned, before any `playerRemoving` for the player. |
| `Hydrogen.Scope.of(system, character: Model): Scope` | The system's scope for that character. Destroyed right after the system's `characterRemoving` for it; a destroyed scope afterwards. Errors for a model the app never added. |
| `t:spawnCharacter(player: Player, character: Model?): Model` | Harness, tests only. Like `LoadCharacter`: removes the current character first, sets `player.Character`, runs `characterAdded`. Without a model it builds one (Model named after the player, `Humanoid` with `Health` and `MaxHealth` 100, anchored `HumanoidRootPart` at the origin, parented to `workspace` when `workspace` is an Instance; `create_hydrogen`'s test runtime makes it a stand-in, and then the model stays unparented). |
| `t:removeCharacter(player: Player)` | Harness, tests only. Runs `characterRemoving`, sets `player.Character = nil`, destroys a model `spawnCharacter` built. |
| `t:streamCharacter(player: Player, streamedIn: boolean)` | Harness, tests only. Moves the character out of the DataModel (`false`: `characterRemoving`) or back in (`true`: `characterAdded` again), as streaming does on a client. |
| `Hydrogen.Character.spawnFake(player, character: Model?): Model` | The same as `t:spawnCharacter`, for `Hydrogen.loopback()` without the harness. Loopback players only. |
| `Hydrogen.Character.removeFake(player)` / `Hydrogen.Character.streamFake(player, streamedIn: boolean)` | Same as `t:removeCharacter` / `t:streamCharacter`. |

Types: the hooks are part of `Hydrogen.Lifecycle`, and `use(System)` strips them like the other hooks.

## Rules

- **When `characterAdded` runs:** for a character that exists when the app starts (or when the player is added), and for every later `CharacterAdded` (respawn, `LoadCharacter`). Never before that player's `playerAdded` hooks have all returned; it waits for them.
- **When `characterRemoving` runs:** on `CharacterRemoving` (respawn, `LoadCharacter`, leaving), when the character leaves the DataModel without it (destroyed, or streamed out on a client), and for the player's character before their `playerRemoving` when they leave or the app stops.
- **Order per player:** `playerAdded` → `characterAdded(c1)` → `characterRemoving(c1)` → `characterAdded(c2)` → … → `characterRemoving(cN)` → `playerRemoving`. A character's hooks for one player run one after another in one thread: a yielding `characterAdded` delays that character's later systems, and the next character's hooks wait for the previous character's `characterRemoving` to return. Different players don't wait for each other.
- Every system sees `characterAdded` exactly once before `characterRemoving` for the same character. If removal comes while `characterAdded` hooks are still running, it waits for them.
- **A character removed before its first hook ran gets no hooks at all.** That happens when the player respawns, or the character is destroyed, while their `playerAdded` is still running (a slow DataStore load). Only the character they have when `playerAdded` finishes is added.
- A hook that errors is warned (`[HYDROGEN] characterAdded failed in system <name>: ...`) and the remaining systems still run.
- `Scope.of(self, character)` is per system and per character. It's live from the first `characterAdded` until that system's `characterRemoving` returns, so in reverse dependency order. It is separate from the player scope `Scope.of(self, player)`, which outlives the character.
- **Clients:** the hooks run in client apps too, for every player's character, including the local player's. On a client, other players' characters arrive when they replicate, so `characterAdded` can run seconds after the player joined, and their parts may stream in after it: use `character:WaitForChild(...)` or `FindFirstChild`, never assume a part exists. With streaming, a character that streams out counts as removed (`characterRemoving`, its scopes destroyed) and gets `characterAdded` again when it streams back in. The model is the same Instance both times.
- A system added after `app:start()` gets `playerAdded` and then `characterAdded` for the characters that exist.
- Cost: an app with no system defining either hook connects nothing. With them, it's two connections per player plus one `AncestryChanged` per character; nothing runs per frame.
- The character passed is `player.Character` at the time Roblox fired `CharacterAdded`. In `characterRemoving`, `player.Character` may already be the next character; use the `character` argument.

## Recipes

**Nametag on every character, on the client.**

```luau
function Nametags:characterAdded(player: Player, character: Model)
	local head = character:WaitForChild("Head", 10)
	if head == nil then
		return
	end
	local tag = Scope.of(self, character):add(Template:Clone()) -- gone on respawn, leave or stream-out
	tag.Adornee = head
	tag.Parent = head
end
```

**Per-character loop that stops on respawn.**

```luau
function Regen:characterAdded(_player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	Scope.of(self, character):spawn(function()
		while true do
			Hydrogen.Clock.wait(1)
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 1)
		end
	end)
end
```

**State that follows the current character.**

```luau
local roots: { [Player]: BasePart } = {}

function Tracker:characterAdded(player: Player, character: Model)
	roots[player] = character:WaitForChild("HumanoidRootPart") :: BasePart
end

function Tracker:characterRemoving(player: Player, _character: Model)
	-- The next character's characterAdded hasn't started yet, so this can't wipe it.
	roots[player] = nil
end
```

**Recording something before Data saves when a player leaves.** `characterRemoving` runs before every `playerRemoving`, so the store (which saves in `playerRemoving`) is still loaded and writable:

```luau
function Combat:characterRemoving(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health < humanoid.MaxHealth * 0.2 then
		PlayerData:update(player, function(data)
			data.combatLogs += 1
			return nil
		end)
	end
end
```

## Mistakes

- Don't connect `player.CharacterAdded` in `playerAdded`. Do define `characterAdded`: it also covers the character that already exists, waits for loaded data, orders systems, and cleans a scope for you.
- Don't clean per-character things in `playerRemoving`. Do put them in `Scope.of(self, character)` (or clean in `characterRemoving`).
- Don't treat `characterRemoving` as death. Do connect `humanoid.Died` in `characterAdded` on the character scope.
- Don't read `player.Character` inside `characterRemoving` to find the removed character. Do use the `character` argument.
- Don't index character parts directly on a client (`character.Head`). Do `WaitForChild` with a timeout: other players' parts stream in.
- Don't keep a per-player table of character things without clearing it in `characterRemoving`. Do key it by character or store it in the character scope.
- Don't call `t:spawnCharacter` on a real `Player`. Do call `player:LoadCharacter()` in a live game; the helpers are for loopback players.

## Testing

Under `Hydrogen.test`, fake players have no character until you give them one:

```luau
Hydrogen.test({ systems = { Combat }, players = { "alice" } }, function(t, alice)
	local character = t:spawnCharacter(alice)          -- characterAdded runs now
	local humanoid = character:FindFirstChildOfClass("Humanoid") :: Humanoid
	assert(humanoid.MaxHealth == 100)

	local next = t:spawnCharacter(alice)                -- respawn: characterRemoving(old), characterAdded(new)
	t:streamCharacter(alice, false)                     -- a client losing the character to streaming
	t:streamCharacter(alice, true)
	t:removeCharacter(alice)                            -- destroyed
	t:leave(alice)                                      -- characterRemoving (if any) before playerRemoving
end)
```

- Spawn before `t:start()` (with `start = false`) to test characters that exist at boot.
- With a `playerAdded` that waits on the fake clock, `characterAdded` runs during the `t:advance` that finishes it.
- Under Lune, set the root's `CFrame`, not `Position`, to move a character (`(character.PrimaryPart :: BasePart).CFrame = CFrame.new(0, 0, 10)`): Lune keeps them apart and `Position` can't be read until set. Guards range checks read `CFrame`.
- Pass your own model, `t:spawnCharacter(alice, model)`, when the system needs specific parts. The harness destroys only models it built.
- With a bare `Hydrogen.loopback()`, use `Hydrogen.Character.spawnFake(player)`, `removeFake` and `streamFake`, and call `Hydrogen.Character._reset()` at teardown to destroy built models. Every app watching the loopback (server and client apps) gets the hooks.
- `t:leave(player)` destroys the fake character too, as Roblox does.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `[HYDROGEN] characterAdded failed in system <name>: <error>` (warning) | That system's hook errored; the other systems still ran. | Fix the hook. A missing part on the client usually needs `WaitForChild`. |
| `[HYDROGEN] characterRemoving failed in system <name>: <error>` (warning) | Same, on removal. The system's character scope was still destroyed. | Fix the hook. |
| `[HYDROGEN] Scope.of: <model> isn't a character (or other subject) the app has added. Ask for its scope from characterAdded or later` (error) | `Scope.of(system, model)` for a model the app never added: not a player's character, or asked for before the character reached the app (your own `CharacterAdded` connection ran first). | Ask from `characterAdded` or later. |
| `[HYDROGEN] spawnCharacter is for loopback players; for a real player call player:LoadCharacter()` (error) | A test helper got a real `Player`. | Use `player:LoadCharacter()`, or a loopback player. |
| `[HYDROGEN] t:spawnCharacter expects a player from t:join() or the players option` (error) | The player didn't come from this harness. | Use `t:join()` or the `players` option. |
| `[HYDROGEN] spawnCharacter expects a Model as the character, got <type>` (error) | The second argument wasn't a Model. | Pass a `Model`, or nothing. |
| `[HYDROGEN] streamCharacter: <name> has no character; spawn one first` (error) | Nothing to stream. | `t:spawnCharacter(player)` first. |

## Works with

- `systems.md`: the other hooks and their ordering; `characterAdded` sits between `playerAdded` and `playerRemoving`.
- `scope.md`: `Scope.of(system, character)` next to the system and player scopes.
- `data.md` / `player-state.md`: `use` the store so character hooks see loaded data, and write before it saves.
- `testing.md`: `t:spawnCharacter`, `t:removeCharacter`, `t:streamCharacter`.
- `clock.md`: per-character timers through `Hydrogen.Clock` run under the fake clock in tests.
