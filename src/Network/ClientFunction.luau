local gt = require("../../roblox_packages/gt")

local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ClientFunction<A..., R...> = Runtime.InnerNetworkFunction<A..., R...> & {
    _callback: ((Player, A...) -> R...)?,
    On: (self: ClientFunction<A..., R...>, callback: (Player, A...) -> R...) -> () -> (),
    Fire: (self: ClientFunction<A..., R...>, A...) -> R...,
    UseRequest: (self: ClientFunction<A..., R...>, middleware: Middleware.Middleware<A...>) -> () -> (),
    UseResponse: (self: ClientFunction<A..., R...>, middleware: Middleware.Middleware<R...>) -> () -> (),
}

local ClientFunction = {}

function ClientFunction.new<A..., R...>(name: string, args: (A...) -> (), returns: () -> R...): ClientFunction<A..., R...>
    local fn = {} :: ClientFunction<A..., R...>

    fn._name = name
    fn._requestMiddleware = {}
    fn._responseMiddleware = {}
    fn._callback = nil
    fn._argsSchema = gt.build(args)
    fn._returnsSchema = gt.build(returns)

    -- Runs on the server.
    local function respond(player: Player, ...: any): ...any
        return Middleware.run(
            fn._responseMiddleware,
            "ClientFunction", name, "outgoing", "response", player, nil,
            fn._returnsSchema:assert((fn._callback :: any)(player, fn._argsSchema:assert(...)))
        )
    end

    function fn:On(callback: (Player, A...) -> R...): () -> ()
        self._callback = callback

        Runtime:registerFunctionCallback(self._name, function(player: Player, ...)
            return respond(player, Middleware.run(self._requestMiddleware, "ClientFunction", name, "incoming", "request", player, nil, ...))
        end)

        return function()
            if self._callback == callback then
                self._callback = nil
                Runtime:registerFunctionCallback(self._name, nil)
            end
        end
    end

    -- Runs on the client.
    function fn:Fire(...: A...): R...
        self._argsSchema:assert(...)

        return self._returnsSchema:assert(Middleware.run(
            self._responseMiddleware,
            "ClientFunction", name, "incoming", "response", nil, nil,
            Runtime:fireServerFunction(
                self._name,
                Middleware.run(self._requestMiddleware, "ClientFunction", name, "outgoing", "request", nil, nil, ...)
            )
        ))
    end

    function fn:UseRequest(middleware: Middleware.Middleware<A...>): () -> ()
        return Middleware.add(self._requestMiddleware, middleware)
    end

    function fn:UseResponse(middleware: Middleware.Middleware<R...>): () -> ()
        return Middleware.add(self._responseMiddleware, middleware)
    end

    Runtime:registerNetworkObject(name)

    return fn
end

return ClientFunction
