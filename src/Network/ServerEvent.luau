local gt = require("../../roblox_packages/gt")
local Middleware = require("./Middleware")
local Runtime = require("./Runtime")

export type ServerEvent<T...> = Runtime.InnerNetworkInfo<T...> & {
    _listeners: { (T...) -> () },
    On: (self: ServerEvent<T...>, callback: (T...) -> ()) -> () -> (),
    Fire: (self: ServerEvent<T...>, player: Player | { Player }, T...) -> (),
    FireAll: (self: ServerEvent<T...>, T...) -> (),
    FireExcept: (self: ServerEvent<T...>, player: Player | { Player }, T...) -> (),
    Use: (self: ServerEvent<T...>, middleware: Middleware.Middleware<T...>) -> () -> (),
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

    local function send(players: { Player }, ...: any)
        Runtime:fireClientEvent(name, players, Middleware.run(event._middleware, "ServerEvent", name, "outgoing", "event", nil, players, ...))
    end

    local function deliver(...: any)
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

    function event:Use(middleware: Middleware.Middleware<T...>): () -> ()
        return Middleware.add(self._middleware, middleware)
    end

    Runtime:registerNetworkObject(name)
    Runtime:registerEventHandler(name, function(...)
        deliver(Middleware.run(event._middleware, "ServerEvent", name, "incoming", "event", nil, nil, ...))
    end)

    return event
end

return ServerEvent
