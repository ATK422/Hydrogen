local gt = require("../../roblox_packages/gt")

local Runtime = require("./Runtime")

export type ClientFunction<A..., R...> = Runtime.InnerNetworkFunction<A..., R...> & {
    _callback: ((Player, A...) -> R...)?,
    On: (self: ClientFunction<A..., R...>, callback: (Player, A...) -> R...) -> () -> (),
    Fire: (self: ClientFunction<A..., R...>, A...) -> R...,
}

local ClientFunction = {}

function ClientFunction.new<A..., R...>(name: string, args: (A...) -> (), returns: () -> R...): ClientFunction<A..., R...>
    local fn = {} :: ClientFunction<A..., R...>

    fn._name = name
    fn._outgoingMiddleware = {}
    fn._incomingMiddleware = {}
    fn._callback = nil
    fn._argsSchema = gt.build(args)
    fn._returnsSchema = gt.build(returns)

    function fn:On(callback: (Player, A...) -> R...): () -> ()
        self._callback = callback

        Runtime:registerFunctionCallback(self._name, function(player: Player, ...)
            return self._returnsSchema:assert(callback(player, self._argsSchema:assert(...)))
        end)

        return function()
            if self._callback == callback then
                self._callback = nil
                Runtime:registerFunctionCallback(self._name, nil)
            end
        end
    end

    function fn:Fire(...: A...): R...
        return self._returnsSchema:assert(Runtime:fireServerFunction(self._name, self._argsSchema:assert(...)))
    end

    Runtime:registerNetworkObject(name)

    return fn
end

return ClientFunction
