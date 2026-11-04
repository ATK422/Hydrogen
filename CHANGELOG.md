# Changelog

All notable changes to Hydrogen are listed here. Versions follow [Semantic Versioning](https://semver.org); while the version is `0.x`, a minor bump can contain breaking changes.

## Unreleased

### Added

- `Hydrogen.Scope` and the `Scope` type: cleanup tied to lifetimes. A scope tracks functions, threads, connections, Instances, other scopes and objects with `Destroy`, `Disconnect` or `cancel`, and cleans them newest first; a task that errors is warned about and the rest still run. `scope:connect`, `scope:spawn`, `scope:delay` and `scope:child` create and track in one call. A destroyed scope cleans anything added to it straight away.
- System and player scopes: a hook that declares a trailing parameter (`function S:start(scope)`, `function S:playerAdded(player, scope)`) receives the system's scope, or its scope for that player. Player scopes are destroyed right after the system's `playerRemoving` for that player (reverse dependency order); system scopes right after the system's `stop` hook on `app:stop()`, or when the boot fails. `Hydrogen.Scope.of(system, player?)` returns the same scopes from anywhere. Systems that don't ask create no scope.

## 0.4.0

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
- `app:replace(original, fake)`: before `start`, swap a system for a fake. The fake's hooks run in the original's place in the boot order, and while the app runs the original table forwards reads and writes to the fake, so dependents that already hold it reach the fake. `app:stop()` (or a failed boot) restores the original.
- `Hydrogen.loopback()` and the `Loopback` type: in-memory remotes and fake players, so one VM can run server and client systems together in a headless test. Messages still go through middleware, validation and the ready handshake. `join`, `leave`, `as` and `client` control the fake clients; `close` removes listeners and middleware added since it opened and stops the network for the next test.
- README section "Testing your systems", including why `replace` redirects the original rather than having `use` return a proxy.
- `App.new({ batching = true })`: events fired during a frame are collected per target and sent on `Heartbeat` as one remote call per target. They are dispatched in order on the receiving side. Reliable and unreliable events batch separately, and unreliable batches are split to stay under an estimated 900 bytes. Calling a function sends that target's pending events first. Skipped under `Hydrogen.loopback()`. Off by default.
- `:Encode()` on all four network object kinds: payloads are packed into a `buffer` using the GreenTea schema (numbers, with 1, 2 or 4-byte integers when an integer range allows it; strings; booleans; `Vector3`; `CFrame`; buffers; arrays; tables; dictionaries; optionals; literals; tuples and varargs). Types it can't pack travel as plain values beside the buffer. Validation still runs on the decoded values, and middleware sees plain values. Off by default.

### Changed

- **Breaking:** registering a network name twice errors. It used to warn and keep the first object, so the second module silently talked to the wrong one.
- `app:addNetwork` takes several instances, like `addSystemsFolders`. Given a ModuleScript, both now require the module itself as well as its descendants. Previously a ModuleScript on its own registered nothing.
- `app:addNetwork` and `app:addSystemsFolders` accept any `Instance`, so `WaitForChild` results need no cast.
- Dependency warnings and cycle errors name systems by their module's full name, and carry the `[HYDROGEN]` prefix.
- **Breaking:** `serverFunction:Fire` times out after 10 seconds by default instead of waiting forever. Use `:SetTimeout(math.huge)` for the old behaviour.
- An error in a system's `init` or `start` is reported as `[HYDROGEN] System <name> failed in <hook>: ...` with the traceback. Boot still stops at the first error.
- The server also creates `ReplicatedStorage.HydrogenNetworkUnreliableRemoteEvent`, and the ready handshake now carries the names fingerprint. Server and client must run the same Hydrogen version.
- The README states that Hydrogen supports one app per side.
- Network id `0` on the event remotes now marks a batch, so a receiver understands batches whether or not its own app batches.
- The test runner exits explicitly once the suites finish, so a test that leaves a thread waiting can't keep Lune running.

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
