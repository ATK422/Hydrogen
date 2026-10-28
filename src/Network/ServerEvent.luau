local gt = require("../../roblox_packages/gt")
local Codec = require("./Codec")
local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ServerEvent<T...> = Runtime.InnerNetworkInfo<T...> & {
    _listeners: { (T...) -> () },
    _codec: Codec.Codec?,
    On: (self: ServerEvent<T...>, callback: (T...) -> ()) -> () -> (),
    Fire: (self: ServerEvent<T...>, player: Player | { Player }, T...) -> (),
    FireAll: (self: ServerEvent<T...>, T...) -> (),
    FireExcept: (self: ServerEvent<T...>, player: Player | { Player }, T...) -> (),
    Use: (self: ServerEvent<T...>, middleware: Middleware.Middleware<T...>) -> () -> (),
    Unreliable: (self: ServerEvent<T...>) -> ServerEvent<T...>,
    Encode: (self: ServerEvent<T...>) -> ServerEvent<T...>,
}

local function toPlayers(player: Player | { Player }): { Player }
    if typeof(player) == "Instance" then
        return { player :: Player }
    end

    return player
end

local ServerEvent = {}

function ServerEvent.new<T...>(name: string, ...: T...): ServerEvent<T...>
    local event = {} :: ServerEvent<T...>

    event._name = name
    event._middleware = {}
    event._listeners = {}
    event._schema = gt.build(...)
    event._codec = nil

    local function forward(players: { Player }, ...: any)
        if Middleware.dropped(...) then
            return
        end
        Runtime:fireClientEvent(name, players, Codec.encodeWith(event._codec, ...))
    end

    local function send(players: { Player }, ...: any)
        forward(players, Middleware.run(event._middleware, "ServerEvent", name, "outgoing", "event", nil, players, ...))
    end

    local function deliver(...: any)
        if Middleware.dropped(...) then
            return
        end

        local ok, cause = event._schema:matches(...)
        if not ok then
            warn(`[HYDROGEN] Dropped invalid {name} from server: {cause:formatErr()}`)
            return
        end

        -- Cloned so a listener that disconnects itself doesn't skip the next one.
        for _, listener in table.clone(event._listeners) do
            listener(...)
        end
    end

    function event:On(callback: (T...) -> ()): () -> ()
        return Middleware.add(self._listeners, callback)
    end

    function event:Fire(player: Player | { Player }, ...: T...)
        self._schema:assert(...)
        send(toPlayers(player), ...)
    end

    function event:FireAll(...: T...)
        self._schema:assert(...)
        send(game:GetService("Players"):GetPlayers(), ...)
    end

    function event:FireExcept(player: Player | { Player }, ...: T...)
        self._schema:assert(...)

        local skip: { [Player]: boolean } = {}
        for _, except in toPlayers(player) do
            skip[except] = true
        end

        local players = {}
        for _, target in game:GetService("Players"):GetPlayers() do
            if not skip[target] then
                table.insert(players, target)
            end
        end

        send(players, ...)
    end

    -- Sends over an UnreliableRemoteEvent: may be dropped or arrive out of order, and is
    -- never queued. For data the next message replaces, such as per-frame state.
    function event:Unreliable(): ServerEvent<T...>
        Runtime.Unreliable[name] = true
        return self
    end

    -- Packs payloads into a buffer using the schema. Both sides must agree, so call it in the
    -- shared definition. Middleware and listeners still see the plain values.
    function event:Encode(): ServerEvent<T...>
        self._codec = Codec.new(self._schema, name)
        return self
    end

    function event:Use(middleware: Middleware.Middleware<T...>): () -> ()
        return Middleware.add(self._middleware, middleware)
    end

    local function receive(...: any)
        deliver(Middleware.run(event._middleware, "ServerEvent", name, "incoming", "event", nil, nil, ...))
    end

    local function receiveDecoded(ok: boolean, ...: any)
        if not ok then
            warn(`[HYDROGEN] Dropped undecodable {name} from server: {(...)}`)
            return
        end
        receive(...)
    end

    Runtime:registerNetworkObject(name, event)
    Runtime:registerEventHandler(name, function(...)
        local codec = event._codec
        if codec then
            receiveDecoded(pcall(codec.decode, ...))
        else
            receive(...)
        end
    end)

    return event
end

return ServerEvent
