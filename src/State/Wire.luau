--!strict

-- The network side of a state definition: one serverEvent per state, named State/<name>, whose
-- schema is the kind's payload. Registered when the state is defined, so wire ids line up on both
-- sides exactly as for any network object defined in a shared module.

local gt = require("../../roblox_packages/gt")
local Network = require("../Network")
local Runtime = require("../Network/Runtime")
local Store = require("./Store")

export type Event = Network.ServerEvent<...any>

local Wire = {}

Wire.build = gt.build

function Wire.networkStarted(): boolean
	return Runtime.Initialized
end

-- What one message carries for each kind. Everyone-visible per-player state puts the owner's
-- UserId in front.
local function fields(kind: string, wireSchema: any, keySchema: any): { any }
	if kind == "value" then
		return { wireSchema }
	elseif kind == "map" then
		return { gt.boolean(), gt.array(keySchema), gt.array(wireSchema), gt.array(keySchema) }
	end
	return { gt.boolean(), gt.array(gt.number({ integer = true })), gt.array(wireSchema) }
end

-- One event for every player leaving, so clients drop that player's state in all states at once.
local function ensureLeftEvent()
	if Store.leftEvent then
		return
	end
	local event = Network.serverEvent("Hydrogen/StateLeft", gt.number())
	event:On(Store.receiveLeft)
	Store.leftEvent = event
end

function Wire.event(name: string, kind: string, ownerPrefixed: boolean, wireSchema: any, keySchema: any, encode: boolean): Event
	local schemas = fields(kind, wireSchema, keySchema)
	if ownerPrefixed then
		table.insert(schemas, 1, gt.number())
		ensureLeftEvent()
	end

	local event = Network.serverEvent(`State/{name}`, table.unpack(schemas))
	if encode then
		event:Encode()
	end
	return event
end

return Wire
