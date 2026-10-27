--!strict

export type Kind = "ClientEvent" | "ServerEvent" | "ClientFunction" | "ServerFunction"

export type Context = {
	-- Name the network object was created with.
	name: string,
	kind: Kind,
	-- "outgoing" runs before data is sent, "incoming" runs before it reaches listeners/handlers.
	direction: "outgoing" | "incoming",
	-- Functions carry a request and a response; events only carry "event".
	payload: "event" | "request" | "response",
	-- The single remote player involved, when there is one (server side only).
	player: Player?,
	-- Every target of an outgoing server event (server side only).
	players: { Player }?,
}

export type Middleware<T...> = (context: Context, T...) -> T...
export type AnyMiddleware = (context: Context, ...any) -> ...any

export type LoggerOptions = {
	-- Return false to skip logging a message.
	filter: ((context: Context) -> boolean)?,
	-- Where log lines go. Defaults to print.
	output: ((message: string) -> ())?,
}

local Middleware = {
	global = {} :: { AnyMiddleware },
}

local function forward(chain: { AnyMiddleware }, index: number, context: Context, ...: any): ...any
	local middleware = chain[index]
	if not middleware then
		return ...
	end

	return forward(chain, index + 1, context, middleware(context, ...))
end

local function backward(chain: { AnyMiddleware }, index: number, context: Context, ...: any): ...any
	local middleware = chain[index]
	if not middleware then
		return ...
	end

	return backward(chain, index - 1, context, middleware(context, ...))
end

-- Middleware layers like an onion: outgoing runs object middleware then global,
-- incoming runs global then object middleware, each in reverse order of adding.
-- Incoming data has not been validated yet, so middleware must not trust its types.
function Middleware.run(
	chain: { any },
	kind: Kind,
	name: string,
	direction: "outgoing" | "incoming",
	payload: "event" | "request" | "response",
	player: Player?,
	players: { Player }?,
	...: any
): ...any
	local global = Middleware.global

	-- Most objects have no middleware; skip the context allocation on that hot path.
	if #chain == 0 and #global == 0 then
		return ...
	end

	local context: Context = {
		name = name,
		kind = kind,
		direction = direction,
		payload = payload,
		player = player,
		players = players,
	}

	-- Cloned so middleware that removes itself mid-run doesn't skip the next one.
	local objectChain = table.clone(chain) :: { AnyMiddleware }
	local globalChain = table.clone(global)

	if direction == "outgoing" then
		return forward(globalChain, 1, context, forward(objectChain, 1, context, ...))
	end

	return backward(objectChain, #objectChain, context, backward(globalChain, #globalChain, context, ...))
end

-- Appends to a chain and returns a function that removes it again.
function Middleware.add<T>(chain: { T }, middleware: T): () -> ()
	table.insert(chain, middleware)

	return function()
		local index = table.find(chain, middleware)
		if index then
			table.remove(chain, index)
		end
	end
end

-- Adds middleware that runs on every network object.
function Middleware.use(middleware: AnyMiddleware): () -> ()
	return Middleware.add(Middleware.global, middleware)
end

local MAX_DEPTH = 2
local MAX_ENTRIES = 8
local MAX_STRING = 200

local function formatValue(value: any, depth: number): string
	local valueType = typeof(value)

	if valueType == "string" then
		if #value > MAX_STRING then
			return string.format("%q", string.sub(value, 1, MAX_STRING)) .. `... ({#value} chars)`
		end
		return string.format("%q", value)
	elseif valueType == "Instance" then
		return `{value.ClassName}({value.Name})`
	elseif valueType ~= "table" then
		return tostring(value)
	end

	if depth >= MAX_DEPTH then
		return "{...}"
	end

	local parts = {}
	local count = 0
	for key, entry in value do
		count += 1
		if count > MAX_ENTRIES then
			table.insert(parts, "...")
			break
		end

		if type(key) == "number" and key == count then
			table.insert(parts, formatValue(entry, depth + 1))
		else
			local keyText = if type(key) == "string" then key else "[" .. formatValue(key, depth + 1) .. "]"
			table.insert(parts, `{keyText} = {formatValue(entry, depth + 1)}`)
		end
	end

	return `\{{table.concat(parts, ", ")}}`
end

local function formatArgs(...: any): string
	local parts = {}
	for index = 1, select("#", ...) do
		table.insert(parts, formatValue((select(index, ...)), 0))
	end
	return table.concat(parts, ", ")
end

local function formatPeer(context: Context): string
	local preposition = if context.direction == "outgoing" then "to" else "from"

	if context.player then
		return ` {preposition} {context.player.Name}`
	elseif context.players then
		local players = context.players
		if #players == 1 then
			return ` {preposition} {players[1].Name}`
		end
		return ` {preposition} {#players} players`
	end

	return ""
end

-- Builds a middleware that logs every message passing through it, unchanged.
function Middleware.logger(options: LoggerOptions?): AnyMiddleware
	local filter = options and options.filter
	local output = (options and options.output) or print

	return function(context: Context, ...: any): ...any
		if filter and not filter(context) then
			return ...
		end

		local arrow = if context.direction == "outgoing" then "->" else "<-"
		local payload = if context.payload == "event" then "" else ` {context.payload}`

		output(`[HYDROGEN] {arrow} {context.name}{payload}{formatPeer(context)}: {formatArgs(...)}`)
		return ...
	end
end

return Middleware
