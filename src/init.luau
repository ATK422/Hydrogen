local Definition = require("@self/Definition")
local App = require("@self/App")
local Network = require("@self/Network")
local Clock = require("@self/Clock")
local Testing = require("@self/Testing")
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

export type Harness = Testing.Harness
export type TestOptions = Testing.TestOptions
export type Expectation = Testing.Expectation
export type Delivery = Testing.Delivery
export type FakeClock = Clock.FakeClock
export type FakeClockOptions = Clock.FakeClockOptions

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
}
