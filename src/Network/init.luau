local ClientEvent = require("@self/ClientEvent")
local ServerEvent = require("@self/ServerEvent")
local ClientFunction = require("@self/ClientFunction")
local ServerFunction = require("@self/ServerFunction")
local Runtime = require("@self/Runtime")
local Loopback = require("@self/Loopback")
local Middleware = require("@self/Middleware")

export type ClientEvent<T...> = ClientEvent.ClientEvent<T...>
export type ClientFunction<A..., R...> = ClientFunction.ClientFunction<A..., R...>
export type ServerEvent<T...> = ServerEvent.ServerEvent<T...>
export type ServerFunction<A..., R...> = ServerFunction.ServerFunction<A..., R...>
export type MiddlewareContext = Middleware.Context
export type Middleware<T...> = Middleware.Middleware<T...>
export type AnyMiddleware = Middleware.AnyMiddleware
export type LoggerOptions = Middleware.LoggerOptions
export type RateLimitOptions = Middleware.RateLimitOptions
export type Loopback = Loopback.Loopback

export type Namespace = {
    clientEvent: typeof(ClientEvent.new),
    clientFunction: typeof(ClientFunction.new),
    serverEvent: typeof(ServerEvent.new),
    serverFunction: typeof(ServerFunction.new),
    namespace: (prefix: string) -> Namespace,
}

local Network = {}

Network.clientEvent = ClientEvent.new
Network.clientFunction = ClientFunction.new
Network.serverEvent = ServerEvent.new
Network.serverFunction = ServerFunction.new
Network.useMiddleware = Middleware.use
Network.logger = Middleware.logger
Network.rateLimit = Middleware.rateLimit
Network.DROP = Middleware.DROP
Network.loopback = Loopback.new

-- Prefixes every name with "prefix/", so places can reuse names without clashing.
function Network.namespace(prefix: string): Namespace
    if type(prefix) ~= "string" or prefix == "" then
        error(`[HYDROGEN] Namespace prefix must be a non-empty string`, 2)
    end

    local namespace = {} :: Namespace

    function namespace.clientEvent<T...>(name: string, ...: T...): ClientEvent<T...>
        return ClientEvent.new(`{prefix}/{name}`, ...)
    end

    function namespace.clientFunction<A..., R...>(name: string, args: (A...) -> (), returns: () -> R...): ClientFunction<A..., R...>
        return ClientFunction.new(`{prefix}/{name}`, args, returns)
    end

    function namespace.serverEvent<T...>(name: string, ...: T...): ServerEvent<T...>
        return ServerEvent.new(`{prefix}/{name}`, ...)
    end

    function namespace.serverFunction<A...>(name: string, ...: A...): ServerFunction.ServerFunctionBuilder<A...>
        return ServerFunction.new(`{prefix}/{name}`, ...)
    end

    function namespace.namespace(inner: string): Namespace
        if type(inner) ~= "string" or inner == "" then
            error(`[HYDROGEN] Namespace prefix must be a non-empty string`, 2)
        end
        return Network.namespace(`{prefix}/{inner}`)
    end

    return namespace
end

-- Counts the network objects reachable from a module's return value.
function Network.countObjects(value: any): number
    return Runtime:countObjects(value)
end

-- The open loopback, if a test opened one.
function Network.activeLoopback(): Loopback?
    return Runtime.Loopback :: any
end

function Network.init(options: Runtime.InitOptions?)
    Runtime:init(options)
end

return Network
