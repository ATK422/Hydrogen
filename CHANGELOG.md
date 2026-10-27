# Changelog

All notable changes to Hydrogen are listed here. Versions follow [Semantic Versioning](https://semver.org); while the version is `0.x`, a minor bump can contain breaking changes.

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
