local gt = require("../../roblox_packages/gt")
local Runtime = require("./Runtime")

export type ServerEvent<T...> = Runtime.InnerNetworkInfo<T...> & {
    On: (self: ServerEvent<T...>, callback: (T...) -> ()) -> () -> (),
    Fire: (self: ServerEvent<T...>, player: Player | { Player }, T...) -> (),
    FireAll: (self: ServerEvent<T...>, T...) -> (),
    FireExcept: (self: ServerEvent<T...>, player: Player | { Player }, T...) -> (),
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

    function event:Fire(player: Player | { Player }, ...: T...)
        self._schema:assert(...)
        Runtime:fireClientEvent(self._name, toPlayers(player), ...)
    end

    function event:FireAll(...: T...)
        self._schema:assert(...)
        Runtime:fireClientEvent(self._name, game:GetService("Players"):GetPlayers(), ...)
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

        Runtime:fireClientEvent(self._name, players, ...)
    end

    Runtime:registerNetworkObject(name)
    Runtime:registerEventListeners(name, event._listeners)

    return event
end

return ServerEvent
