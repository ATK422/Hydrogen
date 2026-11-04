# Hydrogen network middleware (`Use`, `useMiddleware`, `logger`, `rateLimit`, `DROP`)

> Middleware sees every network payload going out or coming in, and can pass it on, replace it, or drop it. Hydrogen ships a traffic logger and a per-player rate limiter.

## Use it when / Don't use it when

- Use it for cross-cutting concerns: logging, rate limiting, metrics, auth checks, wire-format transforms.
- Don't use it for game logic that belongs in a listener.
- Don't use it to validate shapes. GreenTea schemas already do that, after incoming middleware.

## Quick start

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Remotes = require(ReplicatedStorage.Network.Remotes)

-- Debugging: log everything on both sides.
Hydrogen.useMiddleware(Hydrogen.logger())

-- Server: no player may send more than 20 messages per second per object.
Hydrogen.useMiddleware(Hydrogen.rateLimit({ perSecond = 20 }))

-- A tighter limit on one event, and kick on abuse.
Remotes.PlaceTower:Use(Hydrogen.rateLimit({
	perSecond = 5,
	burst = 10,
	onLimit = function(context)
		if context.player then
			context.player:Kick("Too many requests")
		end
	end,
}))
```

## API

| Signature | Notes |
| --- | --- |
| `type Middleware<T...> = (context: MiddlewareContext, T...) -> T...` | Return the values to pass on. Return `...` to leave them unchanged. |
| `type AnyMiddleware = (context: MiddlewareContext, ...any) -> ...any` | |
| `event:Use(mw: Middleware<T...>): () -> ()` | Runs on send and on receive. Returns a function that removes it. |
| `fn:UseRequest(mw: Middleware<A...>): () -> ()` | Function arguments. |
| `fn:UseResponse(mw: Middleware<R...>): () -> ()` | Function return values. |
| `Hydrogen.useMiddleware(mw: AnyMiddleware): () -> ()` | Every network object. |
| `Hydrogen.DROP` | Return it instead of values to stop the message. |
| `Hydrogen.logger(options: LoggerOptions?): AnyMiddleware` | `filter: ((context) -> boolean)?`, `output: ((string) -> ())?` (default: `Hydrogen.Log`, level info, tag `HYDROGEN`) |
| `Hydrogen.rateLimit(options: RateLimitOptions): AnyMiddleware` | `perSecond: number`, `burst: number?` (defaults to `perSecond`), `onLimit: ((context) -> ())?` |

`MiddlewareContext` fields:

| Field | Value |
| --- | --- |
| `name` | the object's name, including any namespace prefix |
| `kind` | `"ClientEvent" \| "ServerEvent" \| "ClientFunction" \| "ServerFunction"` |
| `direction` | `"outgoing" \| "incoming"` |
| `payload` | `"event" \| "request" \| "response"` |
| `player` | server only: the single player involved (the sender, or the function target) |
| `players` | server only: every target of an outgoing `serverEvent` |

## Rules

- The same middleware runs on both sides and in both directions. Check `context.direction` when it should act only one way.
- **Onion order.** Outgoing data runs through object middleware in the order added, then global middleware. Incoming data runs through global middleware, then object middleware, each in reverse order. An encode/decode pair therefore undoes itself.
- Schemas are checked **before** outgoing middleware and **after** incoming middleware. A middleware that changes the wire format must convert back on the receiving side.
- **Incoming middleware on the server receives raw client data before validation.** Check types before you touch values.
- Dropping (returning `Hydrogen.DROP`) an event means it is never sent or never delivered. Dropping a function request or response makes the call error, because the caller is waiting.
- Add middleware before firing anything. Messages already queued don't run through middleware added later.
- `rateLimit` gives each player a separate allowance for each object. It only limits what the server receives (incoming events and function requests); everything else passes through. A limited function request errors back to the client.
- `logger` is global middleware, so it logs what is actually on the wire: after your outgoing object middleware, and before your incoming object middleware.
- Without `output`, `logger` lines go through `Hydrogen.Log` at `info` with the tag `HYDROGEN` (text unchanged), so log levels, sinks, buffers and `t:expectLog` see them. `Hydrogen.Log.setLevel("warn", "HYDROGEN")` hides them along with other Hydrogen info lines. See log.md.
- With `:Encode()`, middleware still sees plain values. Encoding happens after outgoing middleware.

## Recipes

**Logging everything except noisy events.**

```luau
Hydrogen.useMiddleware(Hydrogen.logger({
	filter = function(context)
		return context.name ~= "MouseMoved"
	end,
}))
```

**Admin-only event (server).**

```luau
local ADMINS = { [12345] = true }

Remotes.Ban:Use(function(context, ...)
	if context.direction == "incoming" and not (context.player and ADMINS[context.player.UserId]) then
		return Hydrogen.DROP
	end
	return ...
end)
```

**Counting traffic per object.**

```luau
local counts: { [string]: number } = {}

Hydrogen.useMiddleware(function(context, ...)
	counts[context.name] = (counts[context.name] or 0) + 1
	return ...
end)
```

**Temporary middleware.**

```luau
local remove = Hydrogen.useMiddleware(Hydrogen.logger())
task.delay(30, remove)
```

## Mistakes

- Don't forget `return ...`. A middleware that returns nothing replaces the payload with no values, which then fails validation.
- Don't index incoming values on the server without type checks. They haven't been validated yet.
- Don't change the wire format on one side only. Both sides must undo each other's transforms.
- Don't use `rateLimit` as an anti-cheat for game rules. It limits volume, not legality.
- Don't add middleware after `app:start()` and expect it to see messages already queued.

## Testing

Under `Hydrogen.loopback()`, messages go through middleware in both directions. `net:close()` removes the middleware added since the loopback opened (see `loopback.md`).

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] <name> <request\|response> was dropped by middleware` | A function payload was dropped, so the call errors. Expected when a rate limit or auth middleware rejects it. |
| `[HYDROGEN] rateLimit perSecond must be a positive number` | Fix the options. |
| `[HYDROGEN] -> Name: ...` / `<- Name from Player: ...` | Logger output, not an error. |

## Works with

`network.md`, `network-performance.md`.
