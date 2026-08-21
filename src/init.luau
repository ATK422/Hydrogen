local Definition = require("@self/Definition")
local App = require("@self/App")
local Network = require("@self/Network")

return {
	App = App,
	define = Definition.define,
    clientEvent = Network.clientEvent,
    serverEvent = Network.serverEvent,
    clientFunction = Network.clientFunction,
    serverFunction = Network.serverFunction,
}
