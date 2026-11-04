# Hydrogen network (`clientEvent`, `serverEvent`, `clientFunction`, `serverFunction`)

> Typed, schema-checked remote events and functions, declared once in shared modules that both sides require. Hydrogen owns the actual remotes; you never create a RemoteEvent yourself.

## Use it when / Don't use it when

- Use it for all communication between server and client.
- Don't use it to talk between systems on the same side. Call the other system directly through `use`.
- Don't create `RemoteEvent` or `RemoteFunction` instances by hand in a Hydrogen game.

Names describe **who fires it**: a `clientEvent` is fired by the client and heard by the server, and a `serverEvent` is fired by the server and heard by clients.

## Quick start

```luau
-- ReplicatedStorage/Network/Chat.luau (required by BOTH sides through app:addNetwork)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	SendMessage = Hydrogen.clientEvent("SendMessage", gt.string()),
	MessagePosted = Hydrogen.serverEvent("MessagePosted", gt.string(), gt.string()),
	GetHistory = Hydrogen.clientFunction("GetHistory", gt.args(gt.number()), gt.returns(gt.array(gt.string()))),
	Ping = Hydrogen.serverFunction("Ping", gt.number())(gt.number()),
}
```

```luau
-- server system
function ChatServer:start()
	Chat.SendMessage:On(function(player, text)
		Chat.MessagePosted:FireAll(player.Name, text)
	end)
	Chat.GetHistory:On(function(player, count)
		return table.move(history, math.max(1, #history - count + 1), #history, 1, {})
	end)
end
```

```luau
-- client system
function ChatClient:start()
	Chat.MessagePosted:On(function(author, text)
		print(`{author}: {text}`)
	end)
	Chat.SendMessage:Fire("hello")
	local recent = Chat.GetHistory:Fire(10) -- yields
end
```

## API

Constructors (also available on `Hydrogen.namespace(prefix)`):

| Signature | |
| --- | --- |
| `Hydrogen.clientEvent<T...>(name: string, ...schemas): ClientEvent<T...>` | client → server |
| `Hydrogen.serverEvent<T...>(name: string, ...schemas): ServerEvent<T...>` | server → client(s) |
| `Hydrogen.clientFunction<A..., R...>(name: string, gt.args(...), gt.returns(...)): ClientFunction<A..., R...>` | client asks, server answers |
| `Hydrogen.serverFunction<A...>(name: string, ...argSchemas)(...returnSchemas): ServerFunction<A..., R...>` | server asks one client. **Curried.** |
| `Hydrogen.namespace(prefix: string): Namespace` | The same four constructors (plus `.namespace`), with every name prefixed by `prefix/`. |
| `Hydrogen.gt` | GreenTea. Always write schemas with this copy. |

Methods:

| Object | Fire side | Listen side |
| --- | --- | --- |
| `ClientEvent<T...>` | client: `:Fire(...: T...)` | server: `:On(fn: (Player, T...) -> ()): () -> ()` |
| `ServerEvent<T...>` | server: `:Fire(player: Player \| {Player}, ...: T...)`, `:FireAll(...)`, `:FireExcept(player \| {Player}, ...)` | client: `:On(fn: (T...) -> ()): () -> ()` |
| `ClientFunction<A..., R...>` | client: `:Fire(...: A...): R...` (yields) | server: `:On(fn: (Player, A...) -> R...): () -> ()` |
| `ServerFunction<A..., R...>` | server: `:Fire(player: Player, ...: A...): R...` (yields, times out) | client: `:On(fn: (A...) -> R...): () -> ()` |

Chainable modifiers, which return the object (put them in the shared definition):

- `:Unreliable()` (events only)
- `:Encode()` (all four kinds)
- `:SetTimeout(seconds)` (`serverFunction` only; the default is 10)

See `network-performance.md` for `:Unreliable()` and `:Encode()`.

Middleware: `:Use(mw)` on events, and `:UseRequest(mw)` / `:UseResponse(mw)` on functions. See `middleware.md`.

## Rules

- **Shared definitions.** Put every network object in a module under a folder that both sides pass to `app:addNetwork`.
- **Register before start.** Create every object before `app:start()`. Later registrations are ignored.
- **The same names on both sides.** Wire ids come from the names sorted alphabetically. A name that exists on one side only shifts every id after it and produces `NETWORK MISMATCH`.
- **Unique names.** Registering a name twice errors. Use `Hydrogen.namespace("Lobby")` to separate places that share code. The prefixed name (`"Lobby/Play"`) is the name everywhere.
- **Validation.** Firing with values that don't match the schema errors at the call site. An incoming event that doesn't match is **dropped** with a warning, and listeners never see it. That's your protection against exploiters. Functions validate their arguments and returns on both ends; a bad request errors back to the caller.
- **Events are queued; functions are not.** Events fired before the network starts (e.g. in `init`) are queued and sent once it does. Server events to a client that hasn't finished its handshake are held until it has. Calling a function before the network starts errors, so call functions from `start` or later.
- **Leaving players.** Sends to a player who has left, or is leaving, are dropped silently. You don't need `player.Parent` checks.
- **Listeners.** Events can have many listeners. Functions have one handler, so calling `:On` again replaces it. Every `:On` returns a disconnect function.
- **Server function timeout.** `serverFunction:Fire` errors after 10 s by default. A client can simply never answer, so call it in its own thread (`task.spawn`) if a slow client shouldn't block the system. `:SetTimeout(math.huge)` waits forever, which is dangerous.
- **Incoming data on the server is untrusted.** The schema checks its shape; your handler still checks game rules (does the player own the item, are they in range, has the cooldown passed).

## Recipes

**Several values in one event.**

```luau
Damage = Hydrogen.serverEvent("Damage", gt.number(), gt.Vector3()),
-- server: Remotes.Damage:Fire(player, 25, hitPosition)
-- client: Remotes.Damage:On(function(amount, position) end)
```

**Optional and structured payloads.**

```luau
local Item = gt.table({ id = gt.string(), count = gt.number({ integer = true }) })
Equip = Hydrogen.clientEvent("Equip", Item, gt.optional(gt.string())),
```

**Namespaced definitions for a multi-place game.**

```luau
local Lobby = Hydrogen.namespace("Lobby")
return {
	Play = Lobby.clientEvent("Play", gt.string()),                        -- "Lobby/Play"
	Joined = Lobby.namespace("Queue").serverEvent("Joined", gt.number()), -- "Lobby/Queue/Joined"
}
```

**Asking one client a question, safely.**

```luau
Confirm = Hydrogen.serverFunction("Confirm", gt.string())(gt.boolean()):SetTimeout(30),

task.spawn(function()
	local ok, accepted = pcall(Remotes.Confirm.Fire, Remotes.Confirm, player, "Accept trade?")
	if ok and accepted then
		-- ...
	end
end)
```

**Temporary listener.**

```luau
local disconnect = Remotes.RoundEnded:On(onRoundEnded)
-- later
disconnect()
```

## Mistakes

- Don't define network objects inside a system or a server-only module. The client must register the same names.
- Don't write `serverFunction("X", gt.number(), gt.number())` and expect returns. It's curried: `serverFunction("X", args...)(returns...)`.
- Don't wrap `clientFunction` schemas without `gt.args(...)` and `gt.returns(...)`.
- Don't install GreenTea separately. Use `Hydrogen.gt` so the schemas match the validator.
- Don't trust values in a server handler beyond their shape. Check ownership, range and cooldowns yourself.
- Don't fire a function from `init`. It errors; use `start`.
- Don't call `serverFunction:Fire` inline on a hot path without `pcall`. It can time out, and then it errors.
- Don't rely on a table's metatable or identity surviving the wire. Tables are copied.

## Testing

`Hydrogen.loopback()` runs the network in one VM, with the same ids, validation, queues and handshake (see `loopback.md`).

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] Dropped invalid <name> from <player>: ...` | The incoming payload failed the schema, so it was dropped. Expected for exploit attempts; otherwise the definitions differ between sides. |
| `[HYDROGEN] Dropped invalid <name> from server: ...` | The same, on the client. |
| `[HYDROGEN] Network object <name> is already registered; names must be unique ...` | Rename one, or use `Hydrogen.namespace`. |
| `[HYDROGEN] Network already initialized ignoring <name> registration` | Created after `app:start()`. Move it into an `addNetwork` folder. |
| `[HYDROGEN] NETWORK MISMATCH ...` | The sides registered different names. `addNetwork` the same folders on both sides. |
| `[HYDROGEN] Network function <name> called before the network started; ...` | Call functions from `start` or later. |
| `[HYDROGEN] Network function <name> timed out after Ns waiting for <player>` | The client didn't answer. `pcall` it, raise `:SetTimeout`, or avoid asking clients. |
| `[HYDROGEN] Dropped event with unknown network id <id>` | An id mismatch between versions or definitions. |
| `[HYDROGEN] No callbacks registered for event <name>` | An event arrived with no `:On` listener. Add one, or stop firing it. |
| `[HYDROGEN] Network object ... was never generated, are you sure you initalized network on the server?` | The client started but the server app never did. |
| `[HYDROGEN] Namespace prefix must be a non-empty string` | Bad prefix. |

## Works with

- `middleware.md`: logging, rate limiting, transforms.
- `network-performance.md`: unreliable events, batching, buffer encoding.
- `state.md`: replicated state built on this network. Prefer it over hand-rolled "sync this value" events.
