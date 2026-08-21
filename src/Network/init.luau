local ClientEvent = require("@self/ClientEvent")
local ServerEvent = require("@self/ServerEvent")
local ClientFunction = require("@self/ClientFunction")
local ServerFunction = require("@self/ServerFunction")
local Runtime = require("@self/Runtime")

export type ClientEvent<T...> = ClientEvent.ClientEvent<T...>
export type ClientFunction<A..., R...> = ClientFunction.ClientFunction<A..., R...>
export type ServerEvent<T...> = ServerEvent.ServerEvent<T...>
export type ServerFunction<A..., R...> = ServerFunction.ServerFunction<A..., R...>

local Network = {}

Network.clientEvent = ClientEvent.new
Network.clientFunction = ClientFunction.new
Network.serverEvent = ServerEvent.new
Network.serverFunction = ServerFunction.new

function Network.init()
    Runtime:init()
end

return Network
