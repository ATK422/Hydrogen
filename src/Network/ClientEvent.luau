local gt = require("../../roblox_packages/gt")
local Log = require("../Log")
local Codec = require("./Codec")
local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ClientEvent<T...> = Runtime.InnerNetworkInfo<T...> & {
    _listeners: { (Player, T...) -> () },
    _codec: Codec.Codec?,
    On: (self: ClientEvent<T...>, callback: (Player, T...) -> ()) -> () -> (),
    Fire: (self: ClientEvent<T...>, T...) -> (),
    Use: (self: ClientEvent<T...>, middleware: Middleware.Middleware<T...>) -> () -> (),
    Unreliable: (self: ClientEvent<T...>) -> ClientEvent<T...>,
    Encode: (self: ClientEvent<T...>) -> ClientEvent<T...>,
}

local ClientEvent = {}

function ClientEvent.new<T...>(name: string, ...: T...): ClientEvent<T...>
    local event = {} :: ClientEvent<T...>

    event._name = name
    event._kind = "ClientEvent"
    event._middleware = {}
    event._listeners = {}
    event._schema = gt.build(...)
    event._codec = nil

    -- Payloads come from clients, so they are validated here and dropped if invalid.
    local function deliver(player: Player, ...: any)
        if Middleware.dropped(...) then
            return
        end

        local ok, cause = event._schema:matches(...)
        if not ok then
            Log.warn(`[HYDROGEN] Dropped invalid {name} from {player.Name}: {cause:formatErr()}`)
            return
        end

        if Runtime.Observer then
            Runtime:observeEvent("ClientEvent", name, player, ...)
        end

        -- Cloned so a listener that disconnects itself doesn't skip the next one.
        for _, listener in table.clone(event._listeners) do
            listener(player, ...)
        end
    end

    function event:On(callback: (Player, T...) -> ()): () -> ()
        return Middleware.add(self._listeners, callback)
    end

    local function send(...: any)
        if Middleware.dropped(...) then
            return
        end
        Runtime:fireServerEvent(name, Codec.encodeWith(event._codec, ...))
    end

    function event:Fire(...: T...)
        self._schema:assert(...)
        send(Middleware.run(self._middleware, "ClientEvent", name, "outgoing", "event", nil, nil, ...))
    end

    -- Sends over an UnreliableRemoteEvent: may be dropped or arrive out of order, and is
    -- never queued. For data the next message replaces, such as per-frame state.
    function event:Unreliable(): ClientEvent<T...>
        Runtime.Unreliable[name] = true
        return self
    end

    -- Packs payloads into a buffer using the schema. Both sides must agree, so call it in the
    -- shared definition. Middleware and listeners still see the plain values.
    function event:Encode(): ClientEvent<T...>
        self._codec = Codec.new(self._schema, name)
        return self
    end

    function event:Use(middleware: Middleware.Middleware<T...>): () -> ()
        return Middleware.add(self._middleware, middleware)
    end

    local function receive(player: Player, ...: any)
        deliver(player, Middleware.run(event._middleware, "ClientEvent", name, "incoming", "event", player, nil, ...))
    end

    local function receiveDecoded(player: Player, ok: boolean, ...: any)
        if not ok then
            Log.warn(`[HYDROGEN] Dropped undecodable {name} from {player.Name}: {(...)}`)
            return
        end
        receive(player, ...)
    end

    Runtime:registerNetworkObject(name, event)
    Runtime:registerEventHandler(name, function(player: Player, ...)
        local codec = event._codec
        if codec then
            receiveDecoded(player, pcall(codec.decode, ...))
        else
            receive(player, ...)
        end
    end)

    return event
end

return ClientEvent
