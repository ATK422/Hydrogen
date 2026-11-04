local gt = require("../../roblox_packages/gt")

local Codec = require("./Codec")
local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ClientFunction<A..., R...> = Runtime.InnerNetworkFunction<A..., R...> & {
    _callback: ((Player, A...) -> R...)?,
    _argsCodec: Codec.Codec?,
    _returnsCodec: Codec.Codec?,
    Encode: (self: ClientFunction<A..., R...>) -> ClientFunction<A..., R...>,
    On: (self: ClientFunction<A..., R...>, callback: (Player, A...) -> R...) -> () -> (),
    Fire: (self: ClientFunction<A..., R...>, A...) -> R...,
    UseRequest: (self: ClientFunction<A..., R...>, middleware: Middleware.Middleware<A...>) -> () -> (),
    UseResponse: (self: ClientFunction<A..., R...>, middleware: Middleware.Middleware<R...>) -> () -> (),
}

local ClientFunction = {}

function ClientFunction.new<A..., R...>(name: string, args: (A...) -> (), returns: () -> R...): ClientFunction<A..., R...>
    local fn = {} :: ClientFunction<A..., R...>

    fn._name = name
    fn._kind = "ClientFunction"
    fn._requestMiddleware = {}
    fn._responseMiddleware = {}
    fn._callback = nil
    fn._argsSchema = gt.build(args)
    fn._returnsSchema = gt.build(returns)
    fn._argsCodec = nil
    fn._returnsCodec = nil

    local function handle(player: Player?, ...: any): ...any
        return fn._returnsSchema:assert((fn._callback :: any)(player, ...))
    end

    -- Runs on the server.
    local function respond(player: Player, ...: any): ...any
        return Codec.encodeWith(fn._returnsCodec, Middleware.unlessDropped(name, "response", Middleware.run(
            fn._responseMiddleware,
            "ClientFunction", name, "outgoing", "response", player, nil,
            Runtime:observeCall("ClientFunction", name, player, handle, fn._argsSchema:assert(...))
        )))
    end

    function fn:On(callback: (Player, A...) -> R...): () -> ()
        self._callback = callback

        Runtime:registerFunctionCallback(self._name, function(player: Player, ...)
            return respond(player, Middleware.unlessDropped(name, "request", Middleware.run(
                self._requestMiddleware,
                "ClientFunction", name, "incoming", "request", player, nil,
                Codec.decodeWith(self._argsCodec, name, "request", ...)
            )))
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

        return self._returnsSchema:assert(Middleware.unlessDropped(name, "response", Middleware.run(
            self._responseMiddleware,
            "ClientFunction", name, "incoming", "response", nil, nil,
            Codec.decodeWith(self._returnsCodec, name, "response", Runtime:fireServerFunction(
                self._name,
                Codec.encodeWith(self._argsCodec, Middleware.unlessDropped(name, "request", Middleware.run(self._requestMiddleware, "ClientFunction", name, "outgoing", "request", nil, nil, ...)))
            ))
        )))
    end

    -- Packs arguments and return values into buffers using the schemas. Both sides must agree,
    -- so call it in the shared definition. Middleware and the handler still see the plain values.
    function fn:Encode(): ClientFunction<A..., R...>
        self._argsCodec = Codec.new(self._argsSchema, name)
        self._returnsCodec = Codec.new(self._returnsSchema, name)
        return self
    end

    function fn:UseRequest(middleware: Middleware.Middleware<A...>): () -> ()
        return Middleware.add(self._requestMiddleware, middleware)
    end

    function fn:UseResponse(middleware: Middleware.Middleware<R...>): () -> ()
        return Middleware.add(self._responseMiddleware, middleware)
    end

    Runtime:registerNetworkObject(name, fn)

    return fn
end

return ClientFunction
