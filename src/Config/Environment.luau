--!strict

-- Which kind of server this is, so config can override values per environment. Detected once,
-- on first use; tests can pretend to be anywhere with Config.useEnvironment.

export type Kind = "studio" | "private" | "reserved" | "live"

export type Environment = {
	kind: Kind,
	placeId: number,
}

local Environment = {}

Environment.KINDS = table.freeze({ "studio", "private", "reserved", "live" })

local detected: Environment? = nil
local forced: Environment? = nil

-- DataModel properties a runtime may not have (Lune) are read as nil.
local function property(name: string): any
	local ok, value = pcall(function()
		return (game :: any)[name]
	end)
	return if ok then value else nil
end

local function detect(): Environment
	local studio = false
	pcall(function()
		studio = game:GetService("RunService"):IsStudio()
	end)

	local placeId = property("PlaceId")
	local privateServerId = property("PrivateServerId")
	local ownerId = property("PrivateServerOwnerId")

	local kind: Kind = "live"
	if studio then
		kind = "studio"
	elseif type(privateServerId) == "string" and privateServerId ~= "" then
		-- A private (VIP) server has an owner; a reserved server (TeleportService:ReserveServer) has none.
		kind = if type(ownerId) == "number" and ownerId ~= 0 then "private" else "reserved"
	end

	return table.freeze({
		kind = kind,
		placeId = if type(placeId) == "number" then placeId else 0,
	})
end

function Environment.current(): Environment
	if forced then
		return forced
	end
	if not detected then
		detected = detect()
	end
	return detected :: Environment
end

-- nil goes back to the detected environment.
function Environment.force(environment: Environment?)
	forced = environment
end

function Environment.isKind(value: any): boolean
	return table.find(Environment.KINDS, value) ~= nil
end

return Environment
