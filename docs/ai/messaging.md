# Hydrogen.Messaging

> Server-only, typed `MessagingService` topics: `Messaging.topic(name, schema)` gives `publish(value)`, which checks the value against a GreenTea schema and MessagingService's size limit before sending and retries failures, and `subscribe(fn)`, which only ever sees values that pass the schema.

## Use it when / Don't use it when

Use it when:
- Servers of one experience tell each other things: global announcements, a server opening a reserved dungeon, a ban to apply everywhere, "friend X is in server Y".
- Several places of one game must react to an event at roughly the same time.

Don't use it when:
- The message must arrive (currency, items, purchases, anything you'd be sad to lose): MessagingService delivery is best effort. Write it to a DataStore or MemoryStore queue, and use a message only as a hint to read it.
- You need shared state many servers change at once (a global counter, matchmaking queues): use MemoryStoreService.
- Server to client, or system to system on one server: use the network (`network.md`) or `Hydrogen.Signal`.
- The payload is larger than about 950 bytes as JSON: send an id and look the rest up.

## Quick start

```luau
-- ServerScriptService/Shared/Topics.luau (required by every server system that uses them)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local gt = Hydrogen.gt

return {
	Announcements = Hydrogen.Messaging.topic("Announcements", gt.table({
		text = gt.string(),
		seconds = gt.number({ range = "[1, 60]" }),
	})),
}
```

```luau
-- ServerScriptService/Systems/Announcer.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Topics = require(ServerScriptService.Shared.Topics)
local Remotes = require(ReplicatedStorage.Network.Announcements) -- Show = serverEvent("Show", gt.string(), gt.number())

return Hydrogen.define(function(use)
	use(Hydrogen.Messaging) -- adds it to the app: app:stop() drops its subscriptions
	local Announcer = {}

	function Announcer:start()
		Hydrogen.Scope.of(self):add(Topics.Announcements:subscribe(function(value, info)
			Remotes.Show:FireAll(value.text, value.seconds) -- every server, this one included
		end))
	end

	function Announcer.announce(text: string)
		task.spawn(function() -- publish yields
			Topics.Announcements:publish({ text = text, seconds = 10 })
		end)
	end

	return Announcer
end)
```

## API

`Messaging` is `Hydrogen.Messaging`, a system (`use(Hydrogen.Messaging)` adds it to the app). Topics are server-only: `publish` and `subscribe` error on a client.

```luau
Messaging.topic<T>(name: string, schema: T, options: Hydrogen.MessagingTopicOptions?): Hydrogen.MessagingTopic<T>
-- Defines a topic. name: 1-80 characters, unique per server VM. No MessagingService call.

topic:publish(value: T): (boolean, string?)
-- YIELDS. Server-only. Errors at once (before sending) if value fails the schema, can't be JSON,
-- or is over 1000 bytes as JSON. Then waits for the publish budget and sends, retrying failures;
-- returns true once MessagingService accepted it, or false and the error (also warned).

topic:subscribe(callback: (value: T, info: Hydrogen.MessageInfo) -> ()): () -> ()
-- Server-only. Doesn't yield: the topic's MessagingService subscription is made in the background
-- on the first subscriber. Returns unsubscribe (idempotent; scope:add accepts it).

topic.name: string

Messaging.configure(config: Hydrogen.MessagingConfig): ()  -- service and publish attempts
Messaging.serverId(): string                                -- this server's id in messages (game.JobId, or generated)
Messaging.memoryBus(): Hydrogen.MessagingMemoryBus          -- stand-in MessagingService for tests
```

```luau
export type MessagingTopicOptions = {
	ignoreSelf: boolean?,  -- don't deliver this server's own messages to its subscribers; default false
}
export type MessageInfo = {
	sent: number,            -- MessagingService's Sent timestamp
	serverId: string,        -- the sender's Messaging.serverId()
	fromThisServer: boolean,
}
export type MessagingConfig = {
	service: MessagingBackend?, -- default: MessagingService on a live server, a VM-wide memory bus under Lune/loopback
	attempts: number?,          -- PublishAsync attempts per publish; default 3
}
-- The injectable service: MessagingService's own shape.
export type MessagingBackend = {
	PublishAsync: (self, topic: string, message: any) -> (),
	SubscribeAsync: (self, topic: string, callback: (message: MessagingMessage) -> ()) -> { Disconnect: (self) -> () },
}
export type MessagingMessage = { Data: any, Sent: number }
```

## Rules

Limits (MessagingService's, and what Hydrogen does about each)
- **Size:** a message is at most 1000 bytes of JSON, counting Hydrogen's envelope `{"s":"<server id>","v":<value>}` (about 50 bytes). `publish` measures it (exactly in a game, with `HttpService:JSONEncode`) and errors if it's over.
- **JSON only:** numbers (not NaN or infinite), strings, booleans and tables (arrays without holes, or string keys, not both). No Instances, Vector3, CFrame or Color3: send their numbers. `publish` errors otherwise.
- **Publish rate:** 600 + 240 × players publishes per server per minute. `publish` waits (yields) when this server would pass it.
- **Receive rate** (per topic: 10 + 20 × servers per minute; per experience: 100 + 50 × servers per minute) and **subscriptions** (20 + 8 × players per server) aren't visible to one server, so they aren't enforced. Keep topics few and messages rare; local subscribers to one topic share one subscription.
- **Delivery is best effort:** messages can be lost, arrive late, and arrive in any order. Design for that (idempotent handlers, timestamps in the value).
- **Topic names:** 1 to 80 characters.

Behaviour
- **Lazy:** defining a topic does nothing. The first `subscribe` on a topic makes one MessagingService subscription in the background; more subscribers share it; the last unsubscribe drops it. Messages sent before the subscription completes are missed. A failed subscribe is retried after 1, 2, 4 ... 30 s (warned each time) while the topic has subscribers.
- **Publish retries:** `attempts` (3) in all, after 1 and 2 s (backoff doubles, max 8 s). The final failure is warned and returned.
- **Validation on receive:** a message without Hydrogen's envelope, or whose value fails the schema, is dropped. Warnings are rate-limited to one per topic per 10 s, with a count of the others.
- **Own messages:** MessagingService delivers a server's own messages to it. Subscribers see them with `info.fromThisServer = true`, unless the topic has `ignoreSelf = true`.
- **Values are frozen** and shared by every subscriber of the message.
- **Each subscriber runs in its own thread;** an error is warned and the others still run. Subscribers may yield.
- **Cleanup:** with `Hydrogen.Messaging` in the app, `app:stop()` (bound to `BindToClose`) drops every subscription and stops publish retries. For shorter lifetimes, `scope:add(topic:subscribe(fn))` (e.g. `Scope.of(self, player)`). Without the system in the app, only unsubscribe functions and scopes clean up.
- **One definition per topic:** a second `Messaging.topic` with the same name errors. Define topics in a module and require it.
- **Server-only:** `publish` and `subscribe` error on a client. Defining a topic in a shared module is harmless.
- **`configure`** moves existing subscriptions to the new service and resets the publish budget.
- **Time** goes through `Hydrogen.Clock`, so `t:advance` drives retries, the budget and the warning window.

## Recipes

Send an id, not the record:

```luau
local GuildChanged = Hydrogen.Messaging.topic("GuildChanged", gt.table({ guildId = gt.string() }))

GuildChanged:subscribe(function(value)
	if Guilds:isLoaded(value.guildId) then
		Guilds:unload(value.guildId) -- reload on next use (Hydrogen.Data key store)
	end
end)
GuildChanged:publish({ guildId = guildId })
```

Only react to other servers:

```luau
local ServerOpened = Hydrogen.Messaging.topic("ServerOpened", gt.table({ code = gt.string(), placeId = gt.number() }), {
	ignoreSelf = true,
})
ServerOpened:subscribe(function(value, info)
	openServers[value.code] = { placeId = value.placeId, from = info.serverId, at = info.sent }
end)
```

A ban applied in every server:

```luau
local Banned = Hydrogen.Messaging.topic("Banned", gt.table({ userId = gt.number({ integer = true }) }))
Banned:subscribe(function(value)
	local player = game:GetService("Players"):GetPlayerByUserId(value.userId)
	if player then
		player:Kick("Banned")
	end
end)
-- the ban itself goes in a DataStore first; the message just makes it immediate
```

Per-player subscription that ends when they leave:

```luau
function Friends:playerAdded(player: Player)
	Hydrogen.Scope.of(self, player):add(FriendOnline:subscribe(function(value)
		if isFriend(player, value.userId) then
			Remotes.FriendOnline:Fire(player, value.name)
		end
	end))
end
```

Fire and forget without blocking the caller:

```luau
task.spawn(Topics.Announcements.publish, Topics.Announcements, { text = "Event starting", seconds = 5 })
```

## Mistakes

- Don't grant items or currency from a message. Do write the grant to a DataStore or MemoryStore, and use the message as a "go check" hint.
- Don't send a whole record. Do send ids; the 1000-byte limit includes the envelope.
- Don't put Vector3, CFrame or Instances in a value. Do send numbers or names.
- Don't call `publish` inline in a hot path or a remote handler without expecting it to yield. Do `task.spawn` it.
- Don't call `MessagingService:SubscribeAsync` per player or per round. Do subscribe once per topic per server (or add per-player subscribers: they share one subscription).
- Don't define a topic inside a function that runs twice. Do define it at module top level.
- Don't rely on order or delivery. Do include a timestamp or version in the value and ignore stale ones.
- Don't forget to unsubscribe temporary subscribers. Do `scope:add(topic:subscribe(fn))`.

## Testing

`Messaging.memoryBus()` plays MessagingService in one VM: a publish is delivered at once to every subscriber of the topic, this server's included.

```luau
local bus = Hydrogen.Messaging.memoryBus()
Hydrogen.Messaging.configure({ service = bus })
local Announcements = Hydrogen.Messaging.topic("Announcements", gt.table({ text = gt.string() }))

Hydrogen.test({ systems = { Hydrogen.Messaging } }, function(t)
	local seen: { string } = {}
	Announcements:subscribe(function(value)
		table.insert(seen, value.text)
	end)
	assert(Announcements:publish({ text = "hi" }))
	bus:send("Announcements", { text = "from another server" }, "server-b")
	bus:send("Announcements", { text = 42 })        -- fails the schema: dropped, warned
	assert(#seen == 2)
	t:expectWarning("dropped a message")
end)
assert(bus:subscriptions() == 0)                  -- app:stop() unsubscribed
```

`MessagingMemoryBus` (methods with `:`):
- `published: { { topic: string, data: any } }`: every accepted publish, oldest first; `data` is the envelope (`data.v` is the value).
- `send(topic, value, serverId?)`: deliver as if another server published `value` (default server id `"memory-bus-server"`).
- `sendRaw(topic, data)`: deliver `data` without the envelope (malformed or foreign messages).
- `failPublishes(count, message?)`, `failSubscribes(count, message?)`: the next calls error.
- `subscriptions(topic?): number` (open), `subscribeCalls(topic?): number` (made).

Tips:
- Topic names are VM-wide: use a distinct name per test, or define topics once at the top of the test file.
- Retries and the rate-limit wait yield: `task.spawn` the publish, then `t:advance(seconds)`.
- Without `configure`, topics use a VM-wide memory bus under Lune and `Hydrogen.loopback()`; configure a fresh bus per test for isolation.
- To fake a topic in another system's test, replace the system that owns it, or pass the topic in.

## Errors and warnings

Errors (at the call):
- `Messaging.topic needs a name of 1 to 80 characters`.
- `Messaging topic <name> is already defined; define each topic once, in a module, and require that`.
- `Messaging topic <name> needs a GreenTea schema (Hydrogen.gt), got <type>`; `Messaging topic <name>: options must be a table`.
- `Messaging topic <name>: can't publish a value that doesn't match the schema: <cause>`.
- `Messaging topic <name>: can't publish it: the value.<path> is a <type>, which JSON can't hold; ...` (also `contains itself`, `mixes array items and string keys`, `is an array with holes`, `is nan`/`inf`).
- `Messaging topic <name>: the message is <n> bytes as JSON, over MessagingService's 1000-byte limit; send ids and look the rest up (DataStore, MemoryStore)`.
- `Messaging topic <name>:publish is server-only: MessagingService talks between servers` (and `:subscribe`).
- `Messaging topic <name>:subscribe expects a function, got <type>`.
- `Messaging.configure expects a table`; `Messaging.configure: service is missing PublishAsync` / `SubscribeAsync`; `attempts must be a number, at least 1`.

Warnings:
- `Messaging topic <name> dropped a message: it doesn't match the topic's schema: <cause>` / `it wasn't published through Hydrogen.Messaging (no envelope)`, with `(<n> more dropped since the last warning)`: another server runs older code with a different schema, or something else publishes on the topic.
- `Messaging couldn't publish to topic <name>: <err>`: every attempt failed; `publish` returned false.
- `Messaging couldn't subscribe to topic <name> (attempt <n>), retrying in <s>s: <err>`: MessagingService is down or the subscription limit is reached.
- `Messaging couldn't unsubscribe from topic <name>: <err>`.
- `Messaging topic <name> subscriber failed: <traceback>`: fix the callback; other subscribers ran.

## Works with

- `Hydrogen.Teleport` (teleport.md): announce a reserved server (`result.reservedCode`) so other servers can send players to it.
- `Hydrogen.Scope` (scope.md): `scope:add(topic:subscribe(fn))` ties a subscription to a system, player or round.
- `Hydrogen.Data` (data.md): keep anything that must persist in Data; use a message to tell the server that holds a key store's key to `unload` it.
- `Hydrogen.Clock` and `Hydrogen.test` (clock.md, testing.md): retries, budget waits and warning windows run on the fake clock.
- GreenTea via `Hydrogen.gt` (network.md): the same schemas as network objects.
