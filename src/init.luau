local Definition = require("@self/Definition")
local App = require("@self/App")
local Network = require("@self/Network")
local Clock = require("@self/Clock")
local Testing = require("@self/Testing")
local Scope = require("@self/Scope")
local Data = require("@self/Data")
local PlayerState = require("@self/PlayerState")
local State = require("@self/State")
local Receipts = require("@self/Receipts")
local Input = require("@self/Input")
local gt = require("./roblox_packages/gt")

export type App = typeof(App.new())
export type AppOptions = App.AppOptions
export type Lifecycle = Definition.Lifecycle
export type System<T> = Definition.System<T>
export type Defined<T> = Definition.Defined<T>

export type ClientEvent<T...> = Network.ClientEvent<T...>
export type ServerEvent<T...> = Network.ServerEvent<T...>
export type ClientFunction<A..., R...> = Network.ClientFunction<A..., R...>
export type ServerFunction<A..., R...> = Network.ServerFunction<A..., R...>

export type MiddlewareContext = Network.MiddlewareContext
export type Middleware<T...> = Network.Middleware<T...>
export type AnyMiddleware = Network.AnyMiddleware
export type LoggerOptions = Network.LoggerOptions
export type RateLimitOptions = Network.RateLimitOptions
export type Namespace = Network.Namespace
export type Loopback = Network.Loopback
export type Scope = Scope.Scope

export type Harness = Testing.Harness
export type TestOptions = Testing.TestOptions
export type Expectation = Testing.Expectation
export type Delivery = Testing.Delivery
export type FakeClock = Clock.FakeClock
export type FakeClockOptions = Clock.FakeClockOptions

export type PlayerStore<T> = Data.PlayerStore<T>
export type KeyStore<T> = Data.KeyStore<T>
export type DataBackend = Data.Backend
export type MemoryBackend = Data.MemoryBackend
export type UpdateOnceResult = Data.UpdateOnceResult
export type PlayerState<S> = PlayerState.PlayerState<S>

export type StateValue<T> = State.Value<T>
export type StateMap<K, V> = State.Map<K, V>
export type StateList<T> = State.List<T>
export type PlayerValue<T> = State.PlayerValue<T>
export type PlayerMap<K, V> = State.PlayerMap<K, V>
export type PlayerList<T> = State.PlayerList<T>
export type Computed<T> = State.Computed<T>
export type StateOptions = State.Options
export type PlayerStateOptions = State.PlayerOptions
export type StateSerializer = State.Serializer

export type Receipt = Receipts.Receipt
export type PurchaseDecision = Receipts.Decision
export type ProductHandler = Receipts.ProductHandler
export type GamePassHandler = Receipts.GamePassHandler
export type ReceiptStore = Receipts.ReceiptStore
export type ReceiptsOptions = Receipts.ReceiptsOptions
export type Marketplace = Receipts.Marketplace
export type MemoryReceiptStore = Receipts.MemoryStore
export type FakeMarketplace = Receipts.FakeMarketplace

export type InputAction<V> = Input.Action<V>
export type InputContext = Input.Context
export type InputDevice = Input.Device
export type InputKey = Input.Key
export type InputBinding = Input.Binding
export type InputSavedBindings = Input.SavedBindings
export type InputGlyph = Input.Glyph
export type InputConflict = Input.Conflict
export type InputSource<V> = Input.Source<V>

return {
	App = App,
	define = Definition.define,
	clientEvent = Network.clientEvent,
	serverEvent = Network.serverEvent,
	clientFunction = Network.clientFunction,
	serverFunction = Network.serverFunction,
	namespace = Network.namespace,
	useMiddleware = Network.useMiddleware,
	logger = Network.logger,
	rateLimit = Network.rateLimit,
	-- Headless tests: this VM plays the server and fake clients, without real remotes.
	loopback = Network.loopback,
	-- One call per test: loopback, fake clock, app, fakes and players, always torn down.
	test = Testing.test,
	-- The same harness for frameworks with setup/teardown hooks; call t:close() yourself.
	harness = Testing.harness,
	-- Time for Hydrogen and kit modules: Clock.now(), wait, delay, heartbeat; Clock.fake() in tests.
	Clock = Clock,
	-- Return this from a middleware to stop the message.
	DROP = Network.DROP,
	-- The GreenTea instance Hydrogen validates with, so schemas always match its version.
	gt = gt,
	-- Cleanup tied to a lifetime: Scope.new(), or Scope.of(system, player?) for an app's scopes.
	Scope = Scope,
	-- Session-locked DataStore persistence: Data.player, Data.store, Data.memory.
	Data = Data,
	-- Per-player state from Data or runtime, replicated per field: PlayerState.new.
	PlayerState = PlayerState,
	-- Server-authoritative state replicated to clients.
	State = State,
	-- Kit: routes MarketplaceService.ProcessReceipt and grants each purchase once. Add it to the app.
	Receipts = Receipts,
	-- Client input actions: contexts with priorities, rebinding, device glyphs, touch buttons.
	Input = Input,
}
