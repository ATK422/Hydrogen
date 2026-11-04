local Definition = require("@self/Definition")
local App = require("@self/App")
local Network = require("@self/Network")
local Data = require("@self/Data")
local PlayerState = require("@self/PlayerState")
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

export type PlayerStore<T> = Data.PlayerStore<T>
export type KeyStore<T> = Data.KeyStore<T>
export type DataBackend = Data.Backend
export type MemoryBackend = Data.MemoryBackend
export type UpdateOnceResult = Data.UpdateOnceResult
export type PlayerState<S> = PlayerState.PlayerState<S>

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
	-- Return this from a middleware to stop the message.
	DROP = Network.DROP,
	-- The GreenTea instance Hydrogen validates with, so schemas always match its version.
	gt = gt,
	-- Session-locked DataStore persistence: Data.player, Data.store, Data.memory.
	Data = Data,
	-- Per-player state from Data or runtime, replicated per field: PlayerState.new.
	PlayerState = PlayerState,
}
