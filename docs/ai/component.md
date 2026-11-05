# Hydrogen.Component

> Code bound to CollectionService-tagged instances: `Component.new(tag, options)` is a system that constructs one object, with its own `Hydrogen.Scope`, for every tagged instance in the game, and destroys it when the instance is untagged, destroyed, streamed out or stops passing the component's filters.

## Use it when / Don't use it when

Use it when:
- Behavior belongs to instances placed in the world: coins, doors, lava, spawn pads, NPC spawners, interactables.
- Level designers tag parts in Studio (Tag Editor / Properties → Tags) and code should pick them up wherever they are.
- The client has StreamingEnabled and per-instance code must survive parts streaming out and back in.
- You need per-instance cleanup (connections, tweens, clones) that must not leak when the instance goes away.

Don't use it when:
- The thing is per player, not per instance: use a system's `playerAdded` and `Hydrogen.Scope.of(system, player)`.
- The thing is the player's character: use the `characterAdded` / `characterRemoving` system hooks and `Hydrogen.Scope.of(self, character)` (character.md).
- There is exactly one instance you control: hold a reference in a system instead.
- You need an ECS with queries over many component types per entity: Component binds one tag to one object per instance.

## Quick start

```luau
-- ServerScriptService/Systems/Wallet.luau
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function()
	local Wallet = {}
	local coins: { [Player]: number } = {}

	function Wallet.give(player: Player, amount: number)
		coins[player] = (coins[player] or 0) + amount
	end

	function Wallet:playerRemoving(player: Player)
		coins[player] = nil
	end

	return Wallet
end)
```

```luau
-- ServerScriptService/Systems/Coin.luau
--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local WalletSystem = require(script.Parent.Wallet)
local gt = Hydrogen.gt

return Hydrogen.Component.new("Coin", function(use)
	local Wallet = use(WalletSystem)

	return {
		ancestors = { workspace }, -- not the template in ReplicatedStorage
		attributes = gt.table({ Value = gt.number() }),
		construct = function(coin: BasePart, scope: Hydrogen.Scope, attributes)
			local collected = false
			scope:connect(coin.Touched, function(hit: BasePart)
				local player = hit.Parent and Players:GetPlayerFromCharacter(hit.Parent)
				if player and not collected then
					collected = true
					Wallet.give(player, attributes.Value)
					coin:Destroy() -- destroys this object too
				end
			end)
		end,
	}
end)
```

```luau
-- ServerScriptService/Main.server.luau
local app = Hydrogen.App.new()
app:addSystemsFolders(ServerScriptService.Systems) -- Coin is a system; the folder picks it up
app:start()
```

Tag a part `Coin`, give it a number attribute `Value`, put it in Workspace: each copy gets its own `construct` call and scope.

## API

Constructor (`Hydrogen.Component.new`), called at module top level:

```luau
Hydrogen.Component.new<I, A, T>(tag: string, options: Hydrogen.ComponentOptions<I, A, T>): Hydrogen.Defined<Hydrogen.Component<I, T>>
Hydrogen.Component.new<I, A, T>(tag: string, constructor: (use) -> Hydrogen.ComponentOptions<I, A, T>): Hydrogen.Defined<Hydrogen.Component<I, T>>
-- The result is a system with id "<tag> component". Add it to the app (addSystem / addSystemsFolders) on
-- every side where it should run. The constructor form gets `use`, as in Hydrogen.define.
```

Options (`Hydrogen.ComponentOptions<I, A, T>`):

```luau
{
	construct: (instance: I, scope: Hydrogen.Scope, attributes: A) -> T,  -- required; runs in its own thread, may yield
	destroy: ((object: T, instance: I) -> ())?,       -- before the scope is destroyed; only if construct returned; mustn't yield
	ancestors: { Instance }?,                         -- bind only descendants of one of these (rechecked on reparent)
	children: ({ string } | { [string]: string })?,   -- required direct children: { "Hitbox" } or { Hitbox = "BasePart" } (IsA)
	attributes: A?,                                   -- GreenTea schema: gt.table({ Value = gt.number() }) or { Value = gt.number() }
	timeout: number?,                                 -- seconds before warning about missing children/attributes; default 5
}
```

`I` is inferred from `construct`'s first parameter annotation, `A` from `attributes` (GreenTea schemas are typed as their values, so `attributes.Value` is a `number`), `T` from what `construct` returns.

The component (`Hydrogen.Component<I, T>`), both sides, method syntax:

```luau
Coin.tag: string                                      -- the CollectionService tag
Coin:get(instance: Instance): T?                      -- the object; nil if not constructed (yet) or construct is still running
Coin:has(instance: Instance): boolean                 -- constructed?
Coin:all(): { T }                                     -- every constructed object, no particular order (a new array)
Coin:instances(): { I }                               -- every instance with a constructed object, no particular order
Coin:wait(instance: Instance, timeout: number?): T?   -- YIELDS until constructed; nil after timeout or when the component stops.
                                                      -- No timeout: waits forever, warning once after 5s
```

Before the component's `start` and after its `stop`, `get`/`wait` return nil and `all`/`instances` return `{}`.

## Rules

- **A component is a system.** Add it to the app like any other; it runs where it is added (server app, client app, or both if it lives in a shared folder both apps load). It binds nothing until the app starts.
- **Lifecycle.** The component binds during its own `start` hook, which runs after the `start` of every system it `use`s, so they are ready when `construct` runs. Systems that `use` the component start after it, so `Coin:all()` already holds the instances present at boot. `app:stop()` runs its `stop` hook in reverse dependency order: every object's `destroy` runs, then its scope is destroyed, and the component stops listening. A failed boot also destroys everything constructed.
- **An object exists exactly while all of these hold:** the instance has the tag, it is in the DataModel, it is under one of `ancestors` (if given), it has every required child (if given), and its attributes match the schema (if given). When one stops holding, the object is destroyed. When all hold again, `construct` runs again and makes a **new** object with a new scope. Objects are never reused.
- **Streaming.** On a StreamingEnabled client, streaming out parents the instance to nil, so the object is destroyed, and streaming back in constructs a new one. A part that streams in and out ten times gets ten `construct` calls. Keep state that must survive on the server or in attributes, not in the object. For models with required children, set `ModelStreamingMode` to `Atomic` or `Persistent`, or partial streaming destroys and reconstructs the object as children come and go.
- **`construct` runs in its own thread.** It may yield (a `WaitForChild`, a load). `get` returns nil until it returns. If the instance stops qualifying first, the scope is destroyed, which cancels the yielding thread, and `destroy` is not called. Whatever was added to the scope is cleaned up.
- **The return value is the object.** Return a table (fields, methods) or any value. If `construct` returns nothing, the instance itself is the object, so `get`, `has` and `all` still work.
- **Errors are contained.** An error in `construct` is warned with the instance's full name and traceback. Its scope is cleaned, and every other instance and component carries on. It is not retried until the instance stops qualifying and qualifies again (retagged, streamed back in, a child removed and re-added). An error in `destroy` is warned, and the scope is still destroyed.
- **`destroy` is optional.** Put cleanup in the scope (`scope:connect`, `scope:add(clone)`, `scope:add(function() ... end)`). Use `destroy` for work that needs the object, such as saving its state. It must not yield.
- **Attributes.** `construct` gets the attributes table after validation. While the object exists, Hydrogen updates **that same table in place** on every valid change, so read `attributes.Value` when you need it. A change that breaks the schema destroys the object with a warning, and it is constructed again once the attributes are valid. GreenTea tables accept extra attributes. For optional attributes use `gt.optional(...)`.
- **Children** are direct children found by `Name`, checked with `IsA` when you give a class. Set a child's `Name` before parenting it; renames are not watched. Removing a required child destroys the object with a warning.
- **The timeout only warns.** Waiting for children or attributes goes on after the warning, and the object is constructed whenever they arrive.
- **Signal order doesn't matter.** Every signal re-checks the instance from scratch, so deferred signals, tags added and removed in any order, and reparenting all end in the right state. Changes within one frame can coalesce: an instance tagged and untagged in the same frame may never be constructed.
- **Cost.** In a game a component uses only CollectionService signals, plus per-instance connections only for the options it uses: `ancestors` adds `AncestryChanged`, `children` adds `ChildAdded`/`ChildRemoved`, and `attributes` adds `AttributeChanged`. There is no per-frame work. Requiring `Hydrogen.Component` creates nothing.
- **Under a fake clock (`Hydrogen.test`)** components don't use signals. They re-check tagged instances at the end of every `t:advance`, in Studio and under Lune alike. See Testing.
- **Tags replicate.** Tags set on the server replicate to clients with the instance. Instances or tags created on the client exist only there.
- **Several components may share a tag** (e.g. server logic and client visuals, or two behaviors on one part). Each is its own system with its own objects.

## Recipes

### Object with state and methods, looked up from a remote

```luau
local Doors = Hydrogen.Component.new("Door", {
	ancestors = { workspace },
	children = { Hinge = "BasePart" },
	construct = function(door: Model)
		local hinge = door:FindFirstChild("Hinge") :: BasePart -- guaranteed by children
		local open = false
		return {
			isOpen = function(): boolean
				return open
			end,
			toggle = function()
				open = not open
				hinge.CFrame *= CFrame.Angles(0, math.rad(if open then 90 else -90), 0)
			end,
		}
	end,
})

-- In a server system's init:
OpenDoor:On(function(player: Player, instance: Instance)
	local door = Doors:get(instance) -- nil for anything that isn't a constructed Door
	if door then
		door.toggle()
	end
end)
```

### One loop for every object, not one per object

```luau
-- StarterPlayerScripts/Systems/Spin.luau (client)
local Spinners = Hydrogen.Component.new("Spinner", {
	construct = function(part: BasePart)
		return { part = part, speed = part:GetAttribute("Speed") or 1 }
	end,
})

return Hydrogen.define(function(use)
	local spinners = use(Spinners)
	local Spin = {}
	function Spin:start()
		Hydrogen.Scope.of(self):add(Hydrogen.Clock.heartbeat(function(dt: number)
			for _, spinner in spinners:all() do
				spinner.part.CFrame *= CFrame.Angles(0, spinner.speed * dt, 0)
			end
		end))
	end
	return Spin
end)
```

Add both systems (`Spinners` and `Spin`) to the client app.

### Clone into the world from templates

```luau
-- The template in ReplicatedStorage carries the tag; ancestors keeps it unbound.
local Lava = Hydrogen.Component.new("Lava", {
	ancestors = { workspace },
	construct = function(part: BasePart, scope: Hydrogen.Scope)
		scope:connect(part.Touched, function(hit: BasePart)
			local humanoid = hit.Parent and hit.Parent:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.Health = 0
			end
		end)
	end,
})

local clone = ReplicatedStorage.Templates.LavaPit:Clone() -- tags are cloned
clone.Parent = workspace -- constructed
```

### Typed attributes, kept current

```luau
local Pads = Hydrogen.Component.new("JumpPad", {
	attributes = { Power = gt.number({ range = "[0, inf]" }), Sound = gt.optional(gt.string()) },
	timeout = 2,
	construct = function(pad: BasePart, scope: Hydrogen.Scope, attributes)
		scope:connect(pad.Touched, function(hit: BasePart)
			local root = hit.Parent and hit.Parent:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				root.AssemblyLinearVelocity = Vector3.new(0, attributes.Power, 0) -- current value
			end
		end)
	end,
})
```

### Wait for an instance's object on the client

```luau
DoorOpened:On(function(instance: Instance)
	local door = ClientDoors:wait(instance, 5) -- it may not have streamed in yet
	if door then
		door.playOpenAnimation()
	end
end)
```

### Work that needs the object at the end: destroy

```luau
local Crops = Hydrogen.Component.new("Crop", {
	construct = function(crop: Model)
		return { planted = Hydrogen.Clock.time(), crop = crop }
	end,
	destroy = function(object, crop: Model)
		crop:SetAttribute("PlantedAt", object.planted) -- survives streaming and re-tagging
	end,
})
```

## Mistakes

- Don't keep per-instance state in a table keyed by the instance in your own system. Do return it from `construct` and read it with `Component:get(instance)`. It is cleaned up for you, and under Lune Instances aren't stable table keys.
- Don't connect signals with `instance.Touched:Connect(...)` and forget them. Do use `scope:connect(instance.Touched, ...)`.
- Don't call `CollectionService:GetInstanceAddedSignal` in a system next to a component. Do let the component bind, and use `Component:all()` / `get` from the system.
- Don't call `Coin:get(instance)` inside Coin's own `construct`. It is nil until `construct` returns. Do use the local object you are building.
- Don't assume one `construct` per instance for the whole game. Do expect a new one after every stream-in, retag or re-qualify.
- Don't run per-frame work inside every object (`Clock.heartbeat` per instance). Do run one loop over `Component:all()` in a system.
- Don't yield in `destroy`. Do `task.spawn` the slow part from `destroy` with what it needs captured, or save from a system. (Threads started with `scope:spawn` are cancelled when the object is destroyed.)
- Don't rename a required child after parenting it. Do set `Name` before `Parent`.
- Don't rely on `timeout` to give up. Do treat its warning as a bug report: fix the instance or the template.
- Don't use `get`/`all` with dot syntax (`Coin.get(x)`). Do use `Coin:get(x)`.

## Testing

Under `Hydrogen.test` (fake clock on by default), components don't listen to signals. They re-check tagged instances **at the end of every `t:advance`**, so changes are seen deterministically in Studio and under Lune. Create instances with `Instance.new`, use the real API (`AddTag`, `RemoveTag`, `SetAttribute`, `Parent`, `Destroy`), then call `t:advance(0)`:

```luau
local Gems = Hydrogen.Component.new("Gem", {
	ancestors = { workspace },
	attributes = { Value = gt.number() },
	construct = function(gem: BasePart, _scope, attributes)
		return { value = attributes.Value }
	end,
})

Hydrogen.test({ systems = { Gems } }, function(t)
	local gem = Instance.new("Part")
	gem:AddTag("Gem")
	gem.Parent = workspace
	t:advance(0)
	assert(not Gems:has(gem))            -- no Value attribute yet
	gem:SetAttribute("Value", 10)
	t:advance(0)
	assert((Gems:get(gem) :: any).value == 10)

	gem.Parent = nil                     -- like streaming out
	t:advance(0)
	assert(not Gems:has(gem))
	gem.Parent = workspace               -- back in: a new object
	t:advance(0)
	assert(Gems:has(gem))

	gem:RemoveTag("Gem")
	t:advance(0)
	assert(#Gems:all() == 0)
	t:expectNoWarnings()
	gem:Destroy()
end)
-- app:stop() at the end of the test destroys every object still constructed.
```

Replace the systems a component `use`s as usual (`replace = { [WalletSystem] = fake }`): the system the component holds forwards to the fake.

- Instances present when the test starts are bound during the app's start, as in a game.
- Timeout warnings use `Hydrogen.Clock`: `t:advance(timeout)` triggers them, and `t:expectWarning("has waited")` checks them.
- A yielding `construct` that uses `Hydrogen.Clock.wait` resumes on `t:advance`.
- Clean up the instances a test parents into `workspace` (destroy them); the DataModel is shared across tests in the VM.
- **Under Lune**, Instances have tags, attributes, `Parent`, `FindFirstChild`, `Clone` and `Destroy`, but **no events** (`Touched`, `Changed`, ...). A `construct` that connects one errors there, which is warned as a failed construct. Test that logic in Studio (`Hydrogen.test` works the same there), or keep event wiring thin and test the functions it calls. Lune also hands out a new userdata for the same Instance on each read, so compare Instances with `==`, never use them as table keys, and look objects up with `Component:get`.
- To fake a component in another system's test, `replace = { [Coin] = { get = function() return nil end, all = function() return {} end } }` like any system.

## Errors and warnings

| Message | Meaning | Fix |
| --- | --- | --- |
| `Component.new needs a tag: Component.new("Coin", { construct = ... })` | Tag missing or empty | Pass the CollectionService tag as the first argument |
| `<tag> component: Component.new expects an options table with construct` | Second argument isn't a table or function | Pass options, or `function(use) return options end` |
| `<tag> component needs a construct function: construct = function(instance, scope) ... end` | No `construct` | Add it |
| `<tag> component: destroy must be a function` | `destroy` isn't a function | Fix or remove it |
| `<tag> component: ancestors must be a list of Instances, e.g. { workspace }` (or `got a <type>`) | Empty list, or not Instances (often strings) | Pass the Instances themselves: `{ workspace, workspace.Map }` |
| `<tag> component: children must be a list of names or a table of names to classes` | Wrong `children` shape | `{ "Hitbox" }` or `{ Hitbox = "BasePart" }` |
| `<tag> component: attributes must be a GreenTea schema, e.g. gt.table({ Value = gt.number() })` | Not a schema or a table of schemas | Use `Hydrogen.gt` |
| `<tag> component: timeout must be a number of seconds` | Negative or not a number | Pass seconds |
| `<tag> component: wait expects an Instance, got nil` | `wait(nil)` | Pass the instance |
| warning `<tag> component failed to construct for <full name>: <error + traceback>` | `construct` errored; scope cleaned; not retried until the instance re-qualifies | Fix `construct` (under Lune: often an Instance event that doesn't exist there) |
| warning `<tag> component failed to destroy for <full name>: <error>` | `destroy` errored; scope destroyed anyway | Fix `destroy` |
| warning `<tag> component: <full name> has waited <s>s for child "<name>"` / `for child "<name>" to be a <Class> (it is a <Class>)` / `for attributes matching the schema (<cause>)` + `; it is constructed as soon as that's there...` | Still missing after `timeout`; waiting continues | Add the child or attribute to the instance or its template, fix the class, or raise `timeout` |
| warning `<tag> component: <full name> no longer has <what>; its object is destroyed until it does` | A required child was removed or an attribute changed to an invalid value | Expected during partial streaming; otherwise fix what changed it, or use `ModelStreamingMode = Atomic` |
| warning `<tag> component: still waiting for <full name> after 5s; pass a timeout to wait(instance, timeout) to give up` | `wait` without a timeout is taking long | Pass a timeout, or check the instance is tagged and qualifies |
| warning `<tag> component was still running in another app; stopping it there first` | Started in a second app before the first stopped (usually a test that never stopped its app) | Stop the old app; use `Hydrogen.test` |
| warning `Cleanup failed in scope <tag> component for <full name>: <error>` | Something added to an object's scope errored while cleaning | Fix that cleanup task; the rest still ran |

## Works with

- **Systems** (systems.md): a component is a system. `use` other systems in the constructor form, and `use` the component from systems that query it.
- **Scope** (scope.md): each object's scope is a child of the component's system scope (`Scope.of(Coin)`), so `app:stop()` reaches it either way.
- **GreenTea** (`Hydrogen.gt`): the `attributes` schema, same as network and Data schemas.
- **Network** (network.md): pass instances in events (`gt.Instance()`) and look them up with `Component:get`. Never trust a client's instance: `get` returns nil for anything that isn't a constructed object.
- **Clock** (clock.md) and **Hydrogen.test** (testing.md): timeouts and the fake-clock polling in tests.
- **State** (state.md): for state that must survive streaming or be shown to clients, keep it in State or attributes, keyed by something stable rather than the object.
