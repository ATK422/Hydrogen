local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local gt = require("../../roblox_packages/gt")
local Middleware = require("./Middleware")

-- Reserved so named events keep 1-based ids from assignIds.
local PROTOCOL_READY = 0

export type InnerNetworkInfo<T...> = {
    _name: string,
    _middleware: { Middleware.Middleware<T...> },
    _schema: gt.Type,
}

export type InnerNetworkFunction<A..., R...> = {
    _name: string,
    _requestMiddleware: { Middleware.Middleware<A...> },
    _responseMiddleware: { Middleware.Middleware<R...> },
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
    UnreliableRemoteEvent = nil :: UnreliableRemoteEvent?,
    RemoteFunction = nil :: RemoteFunction?,
    -- Events whose sender uses the UnreliableRemoteEvent; receivers listen on both.
    Unreliable = {} :: {[string]: boolean},
    UnprocessedNames = {} :: {[number]: string},
    RegisteredNames = {} :: {[string]: boolean},
    Objects = {} :: {[any]: string},
    NameToIdMap = {} :: {[string]: number},
    IdToNameMap = {} :: {[number]: string},
    EventHandlers = {} :: {[string]: (...any) -> ()},
    FunctionCallbacks = {} :: {[string]: (...any) -> ...any},
    OutgoingQueue = {} :: { OutgoingEvent },
    PlayerQueues = {} :: { [Player]: { QueuedClientEvent } },
    ReadyPlayers = {} :: { [Player]: boolean },
    -- Weak so players who left can still be garbage collected.
    DepartedPlayers = setmetatable({}, { __mode = "k" }) :: { [Player]: boolean },
}

local function unpackArgs(args: PackedArgs): ...any
    return table.unpack(args, 1, args.n or #args)
end

-- when writing the docs, ensure you say that this can yield on the client
function getNetworkObjectOfType(networkType: "RemoteEvent" | "UnreliableRemoteEvent" | "RemoteFunction"): Instance
    local event = (Runtime[networkType] or ReplicatedStorage:FindFirstChild(`HydrogenNetwork{networkType}`)) :: Instance?

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
    return event :: any
end

-- when writing the docs, ensure you say that this can yield on the client (remotes + ready handshake)
function Runtime:init()
    if Runtime.Initialized then
        warn(`[HYDROGEN] Network already initialized`)
        return
    end

    Runtime.RemoteEvent = getNetworkObjectOfType("RemoteEvent") :: RemoteEvent
    Runtime.UnreliableRemoteEvent = getNetworkObjectOfType("UnreliableRemoteEvent") :: UnreliableRemoteEvent
    Runtime.RemoteFunction = getNetworkObjectOfType("RemoteFunction") :: RemoteFunction
    Runtime:assignIds()

    if RunService:IsClient() then
        (Runtime.RemoteEvent :: RemoteEvent).OnClientEvent:Connect(function(id, ...)
            Runtime:handleEvent(id, ...)
        end);

        (Runtime.UnreliableRemoteEvent :: UnreliableRemoteEvent).OnClientEvent:Connect(function(id, ...)
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

        (Runtime.UnreliableRemoteEvent :: UnreliableRemoteEvent).OnServerEvent:Connect(function(player, id, ...)
            Runtime:handleEvent(id :: number, player, ...)
        end);

        (Runtime.RemoteFunction :: RemoteFunction).OnServerInvoke = function(player, id, ...)
            if id == PROTOCOL_READY then
                return Runtime:markPlayerReady(player, ...)
            end

            return Runtime:handleFunction(id, player, ...)
        end

        Players.PlayerRemoving:Connect(function(player)
            Runtime:removePlayer(player)
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

function Runtime:registerEventHandler(name: string, handler: (...any) -> ())
    Runtime.EventHandlers[name] = handler
end

function Runtime:registerNetworkObject(event: string, object: any)
    if Runtime.Initialized then
        warn(`[HYDROGEN] Network already initialized ignoring {event} registration`)
        return
    end

    -- Keeping the first object would leave the second module silently talking to the wrong one.
    if Runtime.RegisteredNames[event] then
        error(`[HYDROGEN] Network object {event} is already registered; names must be unique (use Hydrogen.namespace to separate places)`, 3)
    end

    Runtime.RegisteredNames[event] = true
    Runtime.Objects[object] = event
    table.insert(Runtime.UnprocessedNames, event)
end

-- Counts the registered network objects reachable from a module's return value.
function Runtime:countObjects(value: any, seen: { [any]: boolean }?): number
    if type(value) ~= "table" then
        return 0
    end

    if Runtime.Objects[value] then
        return 1
    end

    local visited = seen or {}
    if visited[value] then
        return 0
    end
    visited[value] = true

    local count = 0
    for _, child in value do
        count += Runtime:countObjects(child, visited)
    end
    return count
end

-- nil until assignIds has run for this name.
function Runtime:getNetworkId(event: string): number?
    return Runtime.NameToIdMap[event]
end

-- Functions can't be queued, so they need the network running and a real id.
function Runtime:getFunctionId(name: string): number
    if not Runtime.Initialized then
        error(`[HYDROGEN] Network function {name} called before the network started; call functions from start or later`)
    end

    local id = Runtime:getNetworkId(name)
    if not id then
        error(`[HYDROGEN] Network function {name} not found`)
    end

    return id
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

-- A player who has left (or is leaving) gets nothing; a queue made for them would never be cleared.
function Runtime:isDeparted(player: Player): boolean
    return Runtime.DepartedPlayers[player] == true or player.Parent == nil
end

function Runtime:removePlayer(player: Player)
    Runtime.DepartedPlayers[player] = true
    Runtime.ReadyPlayers[player] = nil
    Runtime.PlayerQueues[player] = nil
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

-- A fingerprint of the registered names in id order. Ids come from sorting names, so if the
-- two sides' fingerprints differ, a name exists on one side only and later ids are shifted.
function Runtime:namesHash(): string
    local hash = 5381
    for id = 1, #Runtime.IdToNameMap do
        local name = Runtime.IdToNameMap[id]
        for index = 1, #name do
            hash = (hash * 33 + string.byte(name, index)) % 4294967296
        end
        -- Separator, so "ab","c" and "a","bc" differ.
        hash = (hash * 33) % 4294967296
    end

    return `{#Runtime.IdToNameMap}:{hash}`
end

-- Returns the events queued for the player, and whether the client's names matched the server's.
function Runtime:markPlayerReady(player: Player, clientHash: unknown?): ({ QueuedClientEvent }, boolean)
    local serverHash = Runtime:namesHash()
    local matches = clientHash == nil or clientHash == serverHash

    -- Only the first handshake counts, so a client repeating it can't flood the log.
    if Runtime.ReadyPlayers[player] then
        return {}, matches
    end

    if not matches then
        warn(`[HYDROGEN] NETWORK MISMATCH with {player.Name}: the client registered different network names than the server (client {string.sub(tostring(clientHash), 1, 32)}, server {serverHash}). Ids come from sorted names, so a name on one side only sends messages to the wrong objects. Register the same modules with addNetwork on both sides.`)
    end

    Runtime.ReadyPlayers[player] = true
    local queue = Runtime.PlayerQueues[player]
    Runtime.PlayerQueues[player] = nil
    return queue or {}, matches
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

    local batch, matches = remote:InvokeServer(PROTOCOL_READY, Runtime:namesHash())
    if matches == false then
        warn(`[HYDROGEN] NETWORK MISMATCH: this client registered different network names than the server ({Runtime:namesHash()} here). Messages will reach the wrong objects. Register the same modules with addNetwork on both sides.`)
    end
    if not batch then
        return
    end

    for _, packet in batch do
        Runtime:handleEvent(packet.id, unpackArgs(packet.args))
    end
end

function Runtime:fireClientEvent(name: string, players: { Player }, ...: any)
    local args = table.pack(...) :: PackedArgs
    local unreliable = Runtime.Unreliable[name] == true

    -- Unreliable events are never queued: a backlog of stale frames is worse than none.
    if not Runtime.Initialized then
        if unreliable then
            return
        end
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
        if Runtime:isDeparted(player) then
            continue
        elseif Runtime.ReadyPlayers[player] then
            if unreliable then
                local remote = Runtime.UnreliableRemoteEvent
                if not remote then
                    error(`[HYDROGEN] Network object UnreliableRemoteEvent not found`)
                end

                remote:FireClient(player, id, unpackArgs(args))
            else
                local remote = Runtime.RemoteEvent
                if not remote then
                    error(`[HYDROGEN] Network object RemoteEvent not found`)
                end

                remote:FireClient(player, id, unpackArgs(args))
            end
        elseif not unreliable then
            Runtime:queueForPlayer(player, id, args)
        end
    end
end

function Runtime:fireServerEvent(name: string, ...: any)
    local args = table.pack(...) :: PackedArgs
    local unreliable = Runtime.Unreliable[name] == true

    if not Runtime.Initialized then
        if unreliable then
            return
        end
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

    if unreliable then
        local remote = Runtime.UnreliableRemoteEvent
        if not remote then
            error(`[HYDROGEN] Network object UnreliableRemoteEvent not found`)
        end

        remote:FireServer(id, unpackArgs(args))
        return
    end

    local remote = Runtime.RemoteEvent
    if not remote then
        error(`[HYDROGEN] Network object RemoteEvent not found`)
    end

    remote:FireServer(id, unpackArgs(args))
end

--For safety, you can only fire to one client at a time.
-- InvokeClient waits for the client forever, and a client can simply never answer,
-- so a finite timeout errors in the caller instead of leaving its thread hanging.
function Runtime:fireClientFunction(name: string, player: Player, timeout: number, ...: any): ...any
    local id = Runtime:getFunctionId(name)

    local networkObject = getNetworkObjectOfType("RemoteFunction")
    if not networkObject then
        error(`[HYDROGEN] Network object RemoteFunction not found`)
    end

    local remote = networkObject :: RemoteFunction
    if timeout == math.huge then
        return remote:InvokeClient(player, id, ...)
    end

    local caller = coroutine.running()
    local args = table.pack(...) :: PackedArgs
    local result: { [number]: any, n: number }? = nil
    local waiting = false

    local function finish(packed: { [number]: any, n: number })
        if result then
            return
        end
        result = packed
        if waiting then
            task.spawn(caller)
        end
    end

    task.spawn(function()
        finish(table.pack(pcall(remote.InvokeClient, remote, player, id, unpackArgs(args))))
    end)

    -- InvokeClient can fail without yielding (e.g. the player already left).
    if not result then
        local timer = task.delay(timeout, finish, table.pack(false, `[HYDROGEN] Network function {name} timed out after {timeout}s waiting for {player.Name}`))
        waiting = true
        coroutine.yield()
        if coroutine.status(timer) == "suspended" then
            task.cancel(timer)
        end
    end

    local packed = result :: { [number]: any, n: number }
    if not packed[1] then
        error(packed[2], 0)
    end
    return table.unpack(packed, 2, packed.n)
end

function Runtime:fireServerFunction(name: string, ...: any): any
    local id = Runtime:getFunctionId(name)

    local networkObject = getNetworkObjectOfType("RemoteFunction")
    if not networkObject then
        error(`[HYDROGEN] Network object RemoteFunction not found`)
    end

    local remote = networkObject :: RemoteFunction
    return remote:InvokeServer(id, ...)
end

-- On the server the id comes straight from a client, so unknown ids are dropped rather than erroring.
function Runtime:handleEvent(id: number, ...: any)
    local name = Runtime.IdToNameMap[id]
    if not name then
        warn(`[HYDROGEN] Dropped event with unknown network id {id}`)
        return
    end

    local handler = Runtime.EventHandlers[name]
    if not handler then
        warn(`[HYDROGEN] No callbacks registered for event {name}`)
        return
    end

    handler(...)
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
