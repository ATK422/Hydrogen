local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local gt = require("../../roblox_packages/gt")

-- Reserved so named events keep 1-based ids from assignIds.
local PROTOCOL_READY = 0

export type InnerNetworkInfo<T...> = {
    _name: string,
    _outgoingMiddleware: { (T...) -> T... },
    _incomingMiddleware: { (T...) -> T... },
    _listeners: { (T...) -> () },
    _schema: gt.Type,
}

export type InnerNetworkFunction<A..., R...> = {
    _name: string,
    _outgoingMiddleware: { (A...) -> A... },
    _incomingMiddleware: { (A...) -> A... },
    _argsSchema: gt.Type,
    _returnsSchema: gt.Type,
}

export type PackedArgs = { [number]: any, n: number }

export type OutgoingEvent = {
    name: string,
    players: { Player }?,
    args: PackedArgs,
}

export type QueuedClientEvent = {
    id: number,
    args: PackedArgs,
}

local Runtime = {
    Initialized = false,
    RemoteEvent = nil :: RemoteEvent?,
    RemoteFunction = nil :: RemoteFunction?,
    UnprocessedNames = {} :: {[number]: string},
    NameToIdMap = {} :: {[string]: number},
    IdToNameMap = {} :: {[number]: string},
    EventCallbacks = {} :: {[string]: { (...any) -> () }},
    FunctionCallbacks = {} :: {[string]: (...any) -> ...any},
    OutgoingQueue = {} :: { OutgoingEvent },
    PlayerQueues = {} :: { [Player]: { QueuedClientEvent } },
    ReadyPlayers = {} :: { [Player]: boolean },
}

local function unpackArgs(args: PackedArgs): ...any
    return table.unpack(args, 1, args.n or #args)
end

-- when writing the docs, ensure you say that this can yield on the client
function getNetworkObjectOfType(networkType: "RemoteEvent" | "RemoteFunction"): RemoteEvent | RemoteFunction
    local event = (Runtime[networkType] or ReplicatedStorage:FindFirstChild(`HydrogenNetwork{networkType}`)) :: RemoteEvent | RemoteFunction | nil

    if not event and RunService:IsClient() then
        local s, _ = pcall(function()
            event = ReplicatedStorage:WaitForChild(`HydrogenNetwork{networkType}`)
        end)

        if not s then
            error(`[HYDROGEN] Network object {networkType} was never generated, are you sure you initalized network on the server?`)
        end
    end

    if not event and RunService:IsServer() then
        event = Instance.new(networkType)
        event.Name = `HydrogenNetwork{networkType}`
        event.Parent = ReplicatedStorage
    end

    --Event must exist so this is safe
    return (event :: any) :: RemoteEvent | RemoteFunction
end

-- when writing the docs, ensure you say that this can yield on the client (remotes + ready handshake)
function Runtime:init()
    if Runtime.Initialized then
        warn(`[HYDROGEN] Network already initialized`)
        return
    end

    Runtime.RemoteEvent = getNetworkObjectOfType("RemoteEvent") :: RemoteEvent
    Runtime.RemoteFunction = getNetworkObjectOfType("RemoteFunction") :: RemoteFunction
    Runtime:assignIds()

    if RunService:IsClient() then
        (Runtime.RemoteEvent :: RemoteEvent).OnClientEvent:Connect(function(id, ...)
            Runtime:handleEvent(id, ...)
        end);

        (Runtime.RemoteFunction :: RemoteFunction).OnClientInvoke = function(id, ...)
            return Runtime:handleFunction(id, ...)
        end
    end

    if RunService:IsServer() then
        (Runtime.RemoteEvent :: RemoteEvent).OnServerEvent:Connect(function(player, id, ...)
            Runtime:handleEvent(id :: number, player, ...)
        end);

        (Runtime.RemoteFunction :: RemoteFunction).OnServerInvoke = function(player, id, ...)
            if id == PROTOCOL_READY then
                return Runtime:markPlayerReady(player)
            end

            return Runtime:handleFunction(id, player, ...)
        end

        Players.PlayerRemoving:Connect(function(player)
            Runtime.ReadyPlayers[player] = nil
            Runtime.PlayerQueues[player] = nil
        end)
    end

    Runtime.Initialized = true
    Runtime:flushOutgoingQueue()
    Runtime:requestReady()
end

function Runtime:assignIds()
    table.sort(Runtime.UnprocessedNames)
    for id, name in Runtime.UnprocessedNames do
        Runtime.NameToIdMap[name] = id
        Runtime.IdToNameMap[id] = name
    end
end

function Runtime:registerEventListeners(name: string, listeners: { (...any) -> () })
    Runtime.EventCallbacks[name] = listeners
end

function Runtime:registerNetworkObject(event: string)
    if Runtime.Initialized then
        warn(`[HYDROGEN] Network already initialized ignoring {event} registration`)
        return
    end

    if Runtime.NameToIdMap[event] then
        warn(`[HYDROGEN] Network object {event} already registered, ignoring registration`)
        return
    end

    table.insert(Runtime.UnprocessedNames, event)
    Runtime.NameToIdMap[event] = 0
end

function Runtime:getNetworkId(event: string)
    return Runtime.NameToIdMap[event]
end

function Runtime:getNameFromId(id: number): string
    local name = Runtime.IdToNameMap[id]
    if not name then
        error(`[HYDROGEN] Network id {id} not found`)
    end

    return name
end

function Runtime:registerFunctionCallback(name: string, callback: ((...any) -> ...any)?)
    Runtime.FunctionCallbacks[name] = callback :: any
end

function Runtime:flushOutgoingQueue()
    local queue = Runtime.OutgoingQueue
    Runtime.OutgoingQueue = {}

    for _, packet in queue do
        if packet.players then
            Runtime:fireClientEvent(packet.name, packet.players, unpackArgs(packet.args))
        else
            Runtime:fireServerEvent(packet.name, unpackArgs(packet.args))
        end
    end
end

function Runtime:queueForPlayer(player: Player, id: number, args: PackedArgs)
    local queue = Runtime.PlayerQueues[player]
    if not queue then
        queue = {}
        Runtime.PlayerQueues[player] = queue
    end

    table.insert(queue, {
        id = id,
        args = args,
    })
end

function Runtime:markPlayerReady(player: Player): { QueuedClientEvent }
    if Runtime.ReadyPlayers[player] then
        return {}
    end

    Runtime.ReadyPlayers[player] = true
    local queue = Runtime.PlayerQueues[player]
    Runtime.PlayerQueues[player] = nil
    return queue or {}
end

-- Client asks the server for every event queued before this runtime started.
function Runtime:requestReady()
    if not RunService:IsClient() then
        return
    end

    local remote = Runtime.RemoteFunction
    if not remote then
        error(`[HYDROGEN] Network object RemoteFunction not found`)
    end

    local batch = remote:InvokeServer(PROTOCOL_READY) :: { QueuedClientEvent }?
    if not batch then
        return
    end

    for _, packet in batch do
        Runtime:handleEvent(packet.id, unpackArgs(packet.args))
    end
end

function Runtime:fireClientEvent(name: string, players: { Player }, ...: any)
    local args = table.pack(...) :: PackedArgs

    if not Runtime.Initialized then
        table.insert(Runtime.OutgoingQueue, {
            name = name,
            players = players,
            args = args,
        })
        return
    end

    local id = Runtime:getNetworkId(name)
    if not id or id == PROTOCOL_READY then
        error(`[HYDROGEN] Network event {name} not found`)
    end

    for _, player in players do
        if Runtime.ReadyPlayers[player] then
            local remote = Runtime.RemoteEvent
            if not remote then
                error(`[HYDROGEN] Network object RemoteEvent not found`)
            end

            remote:FireClient(player, id, unpackArgs(args))
        else
            Runtime:queueForPlayer(player, id, args)
        end
    end
end

function Runtime:fireServerEvent(name: string, ...: any)
    local args = table.pack(...) :: PackedArgs

    if not Runtime.Initialized then
        table.insert(Runtime.OutgoingQueue, {
            name = name,
            args = args,
        })
        return
    end

    local id = Runtime:getNetworkId(name)
    if not id or id == PROTOCOL_READY then
        error(`[HYDROGEN] Network event {name} not found`)
    end

    local remote = Runtime.RemoteEvent
    if not remote then
        error(`[HYDROGEN] Network object RemoteEvent not found`)
    end

    remote:FireServer(id, unpackArgs(args))
end

--For safety, you can only fire to one client at a time
function Runtime:fireClientFunction(name: string, player: Player, ...: any): any
    local id = Runtime:getNetworkId(name)
    if not id then
        error(`[HYDROGEN] Network function {name} not found`)
    end

    local networkObject = getNetworkObjectOfType("RemoteFunction")
    if not networkObject then
        error(`[HYDROGEN] Network object RemoteFunction not found`)
    end

    local remote = networkObject :: RemoteFunction
    return remote:InvokeClient(player, id, ...)
end

function Runtime:fireServerFunction(name: string, ...: any): any
    local id = Runtime:getNetworkId(name)
    if not id then
        error(`[HYDROGEN] Network function {name} not found`)
    end

    local networkObject = getNetworkObjectOfType("RemoteFunction")
    if not networkObject then
        error(`[HYDROGEN] Network object RemoteFunction not found`)
    end

    local remote = networkObject :: RemoteFunction
    return remote:InvokeServer(id, ...)
end

function Runtime:handleEvent(id: number, ...: any)
    local name = Runtime:getNameFromId(id)
    local callbacks = Runtime.EventCallbacks[name]
    if not callbacks then
        warn(`[HYDROGEN] No callbacks registered for event {name}`)
        return
    end

    for _, callback in callbacks do
        callback(...)
    end
end

function Runtime:handleFunction(id: number, ...: any): any
    local name = Runtime:getNameFromId(id)
    local callback = Runtime.FunctionCallbacks[name]
    if not callback then
        warn(`[HYDROGEN] No callbacks registered for function {name}`)
        return
    end

    return callback(...)
end

return Runtime
