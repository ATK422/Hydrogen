--!strict

-- The network objects Commands uses. They're registered by the Commands system's init on the
-- server and the Commands.Client system's init on the client, so a game that adds neither
-- registers nothing, and both sides register the same names when both are added.

local gt = require("../../roblox_packages/gt")
local Network = require("../Network")
local Runtime = require("../Network/Runtime")

export type Wire = {
	-- client -> server: the line the player typed.
	run: Network.ClientEvent<string>,
	-- server -> client: one line of output.
	output: Network.ServerEvent<string, string>,
	-- server -> client: the commands this player may run.
	catalog: Network.ServerEvent<{ any }>,
}

local ArgInfo = gt.table({
	name = gt.string(),
	type = gt.string(),
	optional = gt.boolean(),
	rest = gt.boolean(),
	choices = gt.optional(gt.array(gt.string())),
})

local CommandInfo = gt.table({
	name = gt.string(),
	aliases = gt.array(gt.string()),
	description = gt.string(),
	usage = gt.string(),
	args = gt.array(ArgInfo),
	restricted = gt.boolean(),
})

local Wire = {}

local current: Wire? = nil

-- The network objects, registered on first use. Registering needs the network not to be running
-- yet; afterwards this returns nil and the caller warns.
function Wire.get(): Wire?
	local wire = current
	-- Hydrogen's own suite clears the registry between suites; register again then.
	if wire and Runtime.Objects[wire.run] then
		return wire
	end
	if Runtime.Initialized then
		return nil
	end
	local namespace = Network.namespace("Hydrogen/Commands")
	wire = {
		run = namespace.clientEvent("Run", gt.string()),
		output = namespace.serverEvent("Output", gt.string(), gt.string()),
		catalog = namespace.serverEvent("Catalog", gt.array(CommandInfo)),
	} :: any
	current = wire
	return wire
end

-- The objects if they're registered, without registering them.
function Wire.peek(): Wire?
	local wire = current
	if wire and Runtime.Objects[wire.run] then
		return wire
	end
	return nil
end

return Wire
