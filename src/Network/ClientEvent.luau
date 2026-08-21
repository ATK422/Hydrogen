local gt = require("../../roblox_packages/gt")
local Runtime = require("./Runtime")

export type ClientEvent<T...> = Runtime.InnerNetworkInfo<T...> & {
    On: (self: ClientEvent<T...>, callback: (T...) -> ()) -> () -> (),
    Fire: (self: ClientEvent<T...>, T...) -> (),
}

local ClientEvent = {}

function ClientEvent.new<T...>(name: string, ...: T...): ClientEvent<T...>
    local event = {} :: ClientEvent<T...>

    event._name = name
    event._outgoingMiddleware = {}
    event._incomingMiddleware = {}
    event._listeners = {}
    event._schema = gt.build(...)

    function event:On(callback: (T...) -> ()): () -> ()
        table.insert(self._listeners, callback)

        return function()
            local index = table.find(self._listeners, callback)
            if index then
                table.remove(self._listeners, index)
            end
        end
    end

    function event:Fire(...: T...)
        self._schema:assert(...)
        Runtime:fireServerEvent(self._name, ...)
    end

    Runtime:registerNetworkObject(name)
    Runtime:registerEventListeners(name, event._listeners)

    return event
end

return ClientEvent
