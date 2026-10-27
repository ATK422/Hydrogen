local gt = require("../../roblox_packages/gt")
local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ClientEvent<T...> = Runtime.InnerNetworkInfo<T...> & {
    _listeners: { (Player, T...) -> () },
    On: (self: ClientEvent<T...>, callback: (Player, T...) -> ()) -> () -> (),
    Fire: (self: ClientEvent<T...>, T...) -> (),
    Use: (self: ClientEvent<T...>, middleware: Middleware.Middleware<T...>) -> () -> (),
}

local ClientEvent = {}

function ClientEvent.new<T...>(name: string, ...: T...): ClientEvent<T...>
    local event = {} :: ClientEvent<T...>

    event._name = name
    event._middleware = {}
    event._listeners = {}
    event._schema = gt.build(...)

    -- Payloads come from clients, so they are validated here and dropped if invalid.
    local function deliver(player: Player, ...: any)
        local ok, cause = event._schema:matches(...)
        if not ok then
            warn(`[HYDROGEN] Dropped invalid {name} from {player.Name}: {cause:formatErr()}`)
            return
        end

        -- Cloned so a listener that disconnects itself doesn't skip the next one.
        for _, listener in table.clone(event._listeners) do
            listener(player, ...)
        end
    end

    function event:On(callback: (Player, T...) -> ()): () -> ()
        return Middleware.add(self._listeners, callback)
    end

    function event:Fire(...: T...)
        self._schema:assert(...)
        Runtime:fireServerEvent(self._name, Middleware.run(self._middleware, "ClientEvent", name, "outgoing", "event", nil, nil, ...))
    end

    function event:Use(middleware: Middleware.Middleware<T...>): () -> ()
        return Middleware.add(self._middleware, middleware)
    end

    Runtime:registerNetworkObject(name)
    Runtime:registerEventHandler(name, function(player: Player, ...)
        deliver(player, Middleware.run(event._middleware, "ClientEvent", name, "incoming", "event", player, nil, ...))
    end)

    return event
end

return ClientEvent
