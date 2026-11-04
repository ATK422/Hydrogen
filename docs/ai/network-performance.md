# Hydrogen network performance (`:Unreliable()`, batching, `:Encode()`)

> Three opt-in tools for heavy traffic: unreliable events for data the next message replaces anyway, batching to send one remote call per target per frame, and schema-driven buffer encoding to shrink payloads. All of them are off by default. Validation and middleware keep working with each one.

## Use it when / Don't use it when

- `:Unreliable()`: per-tick state where a lost or reordered message doesn't matter (positions, aim, frames). Not for anything that must arrive (purchases, chat, round results).
- Batching (`App.new({ batching = true })`): many events per frame to the same targets. Not worth it for a few events per second.
- `:Encode()`: large or frequent payloads made of numbers, vectors, CFrames and arrays. Not worth it for an occasional short string.
- Measure first (network stats, or a counting middleware). These tools trade CPU and latency for bandwidth.

## Quick start

```luau
-- ReplicatedStorage/Network/Battle.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

local Unit = gt.table({
	id = gt.number({ integer = true, range = "[0, 65535]" }), -- packed in 2 bytes
	position = gt.Vector3(),                                   -- 12 bytes
	hp = gt.number({ integer = true, range = "[0, 255]" }),     -- 1 byte
})

return {
	BattleFrame = Hydrogen.serverEvent("BattleFrame", gt.array(Unit)):Unreliable():Encode(),
}
```

```luau
-- both Main scripts
local app = Hydrogen.App.new({ batching = true })
```

## API

| | |
| --- | --- |
| `serverEvent:Unreliable()` / `clientEvent:Unreliable()` | Sends over an `UnreliableRemoteEvent`. Returns the event. |
| `obj:Encode()` | All four kinds. Packs the payload into a `buffer` laid out by the schema. For functions it covers the arguments and the returns. Returns the object. |
| `App.new({ batching = true })` | Events are collected per target and flushed on `Heartbeat`. |

How `:Encode()` packs each schema:

| Schema | Packed as |
| --- | --- |
| `gt.number()` | 8-byte float |
| `gt.number({ integer = true, range = "[a, b]" })` | the smallest of 1, 2 or 4 bytes that holds the range, else 8 |
| `gt.string()`, `gt.buffer()` | length (1 byte below 128) + bytes |
| `gt.boolean()` | 1 byte |
| `gt.Vector3()` | 12 bytes |
| `gt.CFrame()` | 48 bytes, lossless |
| `gt.array(T)` | count + items |
| `gt.table({...})` | the fields in key order, without the names |
| `gt.dictionary(K, V)` | count + keys and values |
| `gt.optional(T)` | 1 byte + `T` when present |
| `gt.literal(v)` | nothing |
| several values, `gt.vararg(T)` | each in order |

Anything else travels as a plain Luau value beside the buffer and doesn't shrink: unions, `gt.any()`, Instances, EnumItems, `Color3`, and tables with both fields and an indexer.

## Rules

- **Unreliable:** messages can be lost or arrive out of order, and each is limited to about 900 bytes. Unreliable events are **never queued**: sends before the network starts, or to a client that hasn't finished its handshake, are dropped. Only the sender needs the flag, but put it in the shared definition.
- **Batching:** every event waits until the end of its frame, which adds up to one frame of latency. The receiver runs the events in order, each in its own thread. Reliable and unreliable events batch separately, and unreliable batches are split to stay under about 900 bytes. Calling a function first flushes that target's pending events. Only the sender's setting matters, but turn it on for both apps. Batching is skipped under `Hydrogen.loopback()`.
- **Encode:** both sides must call `:Encode()`, so put it in the shared definition. A side that doesn't will reject the other side's messages. Encoded tables carry only the keys the schema declares, so extra keys are lost. Validation runs on the decoded values. Middleware sees plain values.
- Integer ranges are what make `:Encode()` pay off. Give every integer field a tight `range`.

## Recipes

**A position stream from the client.**

```luau
Aim = Hydrogen.clientEvent("Aim", gt.Vector3()):Unreliable():Encode(),
-- client, every frame: Remotes.Aim:Fire(mouseHit)
```

**An encoded function for a large response.**

```luau
GetMap = Hydrogen.clientFunction(
	"GetMap",
	gt.args(),
	gt.returns(gt.array(gt.number({ integer = true, range = "[0, 255]" })))
):Encode(),
```

## Mistakes

- Don't mark an event `:Unreliable()` when it must arrive. Lost purchases or lost round results are bugs.
- Don't send unreliable events from `init` or at join time. They're dropped before the handshake.
- Don't call `:Encode()` in one side's code only. Put it in the shared definition.
- Don't expect extra table keys to survive `:Encode()`. Declare every field in the schema.
- Don't leave integer fields without a `range` when encoding. They fall back to 8 bytes.
- Don't put a big payload in an unreliable event. Over about 900 bytes, Roblox drops it.

## Testing

Under loopback, unreliable events are delivered reliably and batching is skipped. The wire format is covered by Hydrogen's own tests, so test your logic, not the packing.

## Errors and warnings

| Message | Meaning and fix |
| --- | --- |
| `[HYDROGEN] Dropped undecodable <name> from <player>` / `from server` | The two sides disagree on `:Encode()` or on the schema. Fix the shared definition. |
| `[HYDROGEN] Can't encode <name>: ...` | A value is out of its integer range, usually because outgoing middleware changed it after validation. |
| `[HYDROGEN] Can't decode <name> <payload>: ...` | A function payload couldn't be decoded, so the call errors. |
| `[HYDROGEN] Dropped malformed event batch` | Corrupt or forged batch data. |

## Works with

`network.md`, `middleware.md`, `state.md`.
