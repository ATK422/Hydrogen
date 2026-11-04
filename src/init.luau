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
local Log = require("@self/Log")
local Character = require("@self/Character")
local Signal = require("@self/Signal")
local Scheduler = require("@self/Scheduler")
local Component = require("@self/Component")
local Input = require("@self/Input")
local Guards = require("@self/Guards")
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

export type Logger = Log.Logger
export type LogLevel = Log.Level
export type LogThreshold = Log.Threshold
export type LogFields = Log.Fields
export type LogMessage = Log.Message
export type LogLine = Log.Line
export type LogSink = Log.Sink
export type LogBuffer = Log.Buffer
export type LogRateLimitOptions = Log.RateLimitOptions
export type Signal<T...> = Signal.Signal<T...>
export type Connection = Signal.Connection
export type Timer = Scheduler.Timer
export type EveryOptions = Scheduler.EveryOptions
export type FixedOptions = Scheduler.FixedOptions
export type Component<I, T> = Component.Component<I, T>
export type ComponentOptions<I, A, T> = Component.Options<I, A, T>
export type InputAction<V> = Input.Action<V>
export type InputContext = Input.Context
export type InputDevice = Input.Device
export type InputKey = Input.Key
export type InputBinding = Input.Binding
export type InputSavedBindings = Input.SavedBindings
export type InputGlyph = Input.Glyph
export type InputConflict = Input.Conflict
export type InputSource<V> = Input.Source<V>
export type Guard = Guards.Guard
export type GuardOptions = Guards.GuardOptions
export type GuardRejectHook = Guards.RejectHook
export type Cooldown = Guards.Cooldown
export type CooldownOptions = Guards.CooldownOptions
export type RoleResolver = Guards.Resolver
export type RoleSource = Guards.RoleSource
export type GuardPredicate = Guards.Predicate
export type RangeOptions = Guards.RangeOptions
export type GuardsConfigureOptions = Guards.ConfigureOptions

return {
	App = App,
	define = Definition.define,
	clientEvent = Network.clientEvent,
	serverEvent = Network.serverEvent,
	clientFunction = Network.clientFunction,
	serverFunction = Network.serverFunction,
	namespace = Network.namespace,
	useMiddleware = Network.useMiddleware,
	-- Without an output option, traffic lines go through Hydrogen.Log (info, tag HYDROGEN).
	logger = function(options: Network.LoggerOptions?): Network.AnyMiddleware
		if options and options.output then
			return Network.logger(options)
		end
		return Network.logger({
			filter = options and options.filter,
			output = function(message: string)
				Log.line("info", message)
			end,
		})
	end,
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
	-- Tagged, levelled, structured logging: Log.of(system or name, player?), levels, sinks.
	Log = Log.api,
	-- characterAdded / characterRemoving are system hooks; this holds the test helpers for fake characters.
	Character = Character,
	-- Typed in-process signals: Signal.new(), Connect, Once, Wait, Fire.
	Signal = Signal,
	-- Timers tied to lifetimes: after, every, fixed (game loop), debounce, throttle.
	Scheduler = Scheduler,
	-- Code bound to CollectionService-tagged instances, one object and scope each: Component.new(tag, options).
	Component = Component,
	-- Client input actions: contexts with priorities, rebinding, device glyphs, touch buttons.
	Input = Input,
	-- Server-side rules for incoming traffic: cooldowns, roles and permissions, range checks, predicates.
	Guards = Guards,
}
