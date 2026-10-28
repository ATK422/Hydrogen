# Changelog

All notable changes to Hydrogen are listed here. Versions follow [Semantic Versioning](https://semver.org); while the version is `0.x`, a minor bump can contain breaking changes.

## Unreleased

### Added

- Player and shutdown hooks: systems can define `playerAdded`, `playerRemoving` and `stop`. `playerAdded` runs in dependency order; `playerRemoving` and `stop` run in reverse, so a system runs before the systems it `use`s. `playerRemoving` waits for that player's `playerAdded` hooks to finish, and an error in one system's hook is reported without skipping the others.
- `app:stop()`: runs `playerRemoving` for players still in the game, waits for every `playerRemoving` hook, then runs `stop` hooks. Bound to `game:BindToClose` on the server.
- `Hydrogen.namespace(prefix)` and the `Namespace` type: constructors that prefix network names with `prefix/`, so places sharing code can reuse names. Namespaces nest with `namespace.namespace(...)`.
- `app:addNetwork` and `app:addSystemsFolders` warn when they find nothing to register.
- Network mismatch detection: the client sends a fingerprint of its sorted network names in the ready handshake, and both sides warn `[HYDROGEN] NETWORK MISMATCH` when it differs from the server's.
- `serverFunction:SetTimeout(seconds)`. `Fire` errors when the client hasn't answered in time.
- `Hydrogen.rateLimit(options)`: a middleware that drops a player's incoming messages beyond `perSecond` (with `burst` and `onLimit` options), per network object.
- `Hydrogen.DROP`: a middleware can return it to stop a message. Dropped events are not delivered; dropped function payloads error.
- `event:Unreliable()` on server and client events, which sends over an `UnreliableRemoteEvent`. Unreliable events are never queued.
- `Hydrogen.define(id, constructor)`, for an explicit id instead of the calling module's name.
- `App.new({ debug = true })` prints how long each system's `init` and `start` took. `output` changes where it goes.

### Changed

- **Breaking:** registering a network name twice errors. It used to warn and keep the first object, so the second module silently talked to the wrong one.
- `app:addNetwork` takes several instances, like `addSystemsFolders`. Given a ModuleScript, both now require the module itself as well as its descendants. Previously a ModuleScript on its own registered nothing.
- `app:addNetwork` and `app:addSystemsFolders` accept any `Instance`, so `WaitForChild` results need no cast.
- Dependency warnings and cycle errors name systems by their module's full name, and carry the `[HYDROGEN]` prefix.
- **Breaking:** `serverFunction:Fire` times out after 10 seconds by default instead of waiting forever. Use `:SetTimeout(math.huge)` for the old behaviour.
- An error in a system's `init` or `start` is reported as `[HYDROGEN] System <name> failed in <hook>: ...` with the traceback. Boot still stops at the first error.
- The server also creates `ReplicatedStorage.HydrogenNetworkUnreliableRemoteEvent`, and the ready handshake now carries the names fingerprint. Server and client must run the same Hydrogen version.
- The README states that Hydrogen supports one app per side.

### Fixed

- Events sent to a player who has left are dropped. Before, a send after Hydrogen's `PlayerRemoving` handler ran (after a yield, or from a later handler) created a queue for that player that was never cleared.

## 0.3.0

### Added

- Network middleware. Per object with `event:Use`, `fn:UseRequest` and `fn:UseResponse`; for every object with `Hydrogen.useMiddleware`. Each returns a function that removes the middleware.
- `Hydrogen.logger(options?)`, a middleware that logs network traffic for debugging, with `filter` and `output` options.
- `Hydrogen.gt`, the GreenTea instance Hydrogen validates with.
- Exported types from the package entry point: `App`, `Lifecycle`, `System`, `Defined`, `ClientEvent`, `ServerEvent`, `ClientFunction`, `ServerFunction`, `MiddlewareContext`, `Middleware`, `AnyMiddleware`, `LoggerOptions`.

### Changed

- **Breaking:** incoming event payloads are validated against the schema on the receiving side. Invalid payloads (including anything a client sends to the server) are dropped with a warning instead of reaching listeners.
- **Breaking:** calling `clientFunction:Fire` or `serverFunction:Fire` before the network starts now errors with a clear message. Previously it sent the reserved handshake id.
- **Breaking:** the unused `_outgoingMiddleware` and `_incomingMiddleware` fields are replaced by `_middleware` (events) and `_requestMiddleware` / `_responseMiddleware` (functions).
- The type of `clientEvent:On` now includes the sending `player` as the listener's first argument, matching what it receives at runtime.
- Events with an unknown network id are dropped with a warning instead of erroring.
- The development Rojo project now mirrors the layout pesde generates for consumers (`src` and `roblox_packages` side by side), so network modules resolve GreenTea in Studio.

## 0.2.2

- Initial network layer: client/server events and functions, startup queuing, and the client ready handshake.
