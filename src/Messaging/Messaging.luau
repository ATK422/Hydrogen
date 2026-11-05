--!strict

-- Typed MessagingService topics. publish checks the value against the topic's GreenTea schema
-- and MessagingService's size limit before sending, waits for the publish budget and retries
-- failures. Subscribers get only values that pass the schema. Nothing touches MessagingService
-- until a topic is published to or subscribed.

local RunService = game:GetService("RunService")

local Definition = require("../Definition")
local Network = require("../Network")
local Tables = require("../Data/Tables")
local Time = require("../Clock")
local Log = require("../Log")
local Json = require("./Json")
local Types = require("./Types")
local MemoryBus = require("./MemoryBus")

type Backend = Types.Backend
type Connection = Types.Connection
type Message = Types.Message
type MessageInfo = Types.MessageInfo
type TopicOptions = Types.TopicOptions
type Config = Types.Config

-- MessagingService refuses messages over 1 kB of JSON. Hydrogen's envelope counts.
local MAX_BYTES = 1000
local MAX_NAME = 80
local DEFAULT_ATTEMPTS = 3
-- Publishes per server per minute: 600 + 240 per player in the server.
local PUBLISH_WINDOW = 60
local PUBLISH_BASE = 600
local PUBLISH_PER_PLAYER = 240
-- One warning per topic per this many seconds about dropped messages.
local WARN_WINDOW = 10

type Listener = {
	callback: (value: any, info: MessageInfo) -> (),
}

type TopicState = {
	name: string,
	schema: any,
	ignoreSelf: boolean,
	listeners: { Listener },
	-- The MessagingService subscription while there are listeners.
	connection: Connection?,
	-- Cleared when the subscription is dropped, so late messages on it are ignored.
	live: { on: boolean }?,
	subscribing: boolean,
	-- Rate-limited warnings about dropped messages.
	warnedAt: number?,
	suppressed: number,
}

local options = {
	service = nil :: Backend?,
	attempts = DEFAULT_ATTEMPTS,
}

local topics: { [string]: TopicState } = {}
-- Bumped by stop (shutdown): publishes and subscribes started before it give up.
local generation = 0
-- Clock.now() of each publish request in the last minute, oldest first.
local sent: { number } = {}
local thisServer: string? = nil
local defaultBus: Backend? = nil

local function currentService(): Backend
	if options.service then
		return options.service
	elseif RunService:IsServer() and not Network.activeLoopback() then
		return game:GetService("MessagingService") :: any
	end
	-- Lune and loopback tests without a configured bus: one bus for the VM.
	defaultBus = defaultBus or MemoryBus.new()
	return defaultBus :: Backend
end

local function serverId(): string
	if thisServer then
		return thisServer
	end
	local ok, jobId = pcall(function()
		return game.JobId
	end)
	if ok and type(jobId) == "string" and jobId ~= "" then
		thisServer = jobId
	else
		-- Studio and Lune have no JobId.
		local made, guid = pcall(function()
			return game:GetService("HttpService"):GenerateGUID(false)
		end)
		thisServer = if made and type(guid) == "string"
			then guid
			else string.format("server-%x-%x", math.random(0, 0x7fffffff), math.floor(os.clock() * 1e6) % 0x7fffffff)
	end
	return thisServer :: string
end

local function serverOnly(what: string)
	if RunService:IsClient() and not Network.activeLoopback() then
		error(`[HYDROGEN] {what} is server-only: MessagingService talks between servers`, 3)
	end
end

local function playerCount(): number
	local ok, count = pcall(function()
		return #game:GetService("Players"):GetPlayers()
	end)
	return if ok and type(count) == "number" then count else 0
end

-- Waits until this server may publish again without passing MessagingService's rate limit.
local function waitForBudget(started: number)
	while true do
		local now = Time.now()
		while sent[1] and now - sent[1] >= PUBLISH_WINDOW do
			table.remove(sent, 1)
		end
		if generation ~= started or #sent < PUBLISH_BASE + PUBLISH_PER_PLAYER * playerCount() then
			table.insert(sent, now)
			return
		end
		Time.wait(math.max(sent[1] + PUBLISH_WINDOW - now, 0.05))
	end
end

local function drop(topic: TopicState, why: string)
	local now = Time.now()
	if topic.warnedAt ~= nil and now - topic.warnedAt < WARN_WINDOW then
		topic.suppressed += 1
		return
	end
	local extra = if topic.suppressed > 0 then ` ({topic.suppressed} more dropped since the last warning)` else ""
	topic.warnedAt = now
	topic.suppressed = 0
	Log.warn(`[HYDROGEN] Messaging topic {topic.name} dropped a message: {why}{extra}`)
end

local function deliver(topic: TopicState, listener: Listener, value: any, info: MessageInfo)
	local ok, err = xpcall(listener.callback, debug.traceback, value, info)
	if not ok then
		Log.warn(`[HYDROGEN] Messaging topic {topic.name} subscriber failed: {err}`)
	end
end

local function receive(topic: TopicState, live: { on: boolean }, message: Message)
	if not live.on or #topic.listeners == 0 then
		return
	end
	local data = if type(message) == "table" then message.Data else nil
	if type(data) ~= "table" or type(data.s) ~= "string" then
		drop(topic, "it wasn't published through Hydrogen.Messaging (no envelope)")
		return
	end
	local fromThisServer = data.s == serverId()
	if fromThisServer and topic.ignoreSelf then
		return
	end
	local ok, cause = topic.schema:matches(data.v)
	if not ok then
		drop(topic, `it doesn't match the topic's schema: {cause}`)
		return
	end

	-- One copy shared by every subscriber, so none of them may change it.
	local value = Tables.freeze(data.v)
	local info: MessageInfo = table.freeze({
		sent = if type(message.Sent) == "number" then message.Sent else Time.time(),
		serverId = data.s,
		fromThisServer = fromThisServer,
	})
	for _, listener in table.clone(topic.listeners) do
		task.spawn(deliver, topic, listener, value, info)
	end
end

local function unsubscribe(topic: TopicState)
	local live = topic.live
	if live then
		live.on = false
	end
	topic.live = nil
	local connection = topic.connection
	topic.connection = nil
	if connection then
		local ok, err = pcall(connection.Disconnect, connection)
		if not ok then
			Log.warn(`[HYDROGEN] Messaging couldn't unsubscribe from topic {topic.name}: {err}`)
		end
	end
end

-- Subscribes with MessagingService in the background, retrying with backoff while the topic
-- still has listeners.
local function ensureSubscribed(topic: TopicState)
	if topic.connection or topic.subscribing then
		return
	end
	topic.subscribing = true
	task.spawn(function()
		local attempt = 0
		local started = generation
		while #topic.listeners > 0 and generation == started do
			attempt += 1
			local service = currentService()
			local live = { on = true }
			local ok, result = pcall(service.SubscribeAsync, service, topic.name, function(message: Message)
				receive(topic, live, message)
			end)
			if ok then
				local connection = result :: Connection
				if #topic.listeners == 0 or generation ~= started or currentService() ~= service then
					-- Everyone left (or the service changed) while this subscribed.
					live.on = false
					pcall(connection.Disconnect, connection)
					continue
				end
				topic.connection = connection
				topic.live = live
				break
			end
			local delay = math.min(2 ^ (attempt - 1), 30)
			Log.warn(`[HYDROGEN] Messaging couldn't subscribe to topic {topic.name} (attempt {attempt}), retrying in {delay}s: {result}`)
			Time.wait(delay)
		end
		topic.subscribing = false
	end)
end

local Messaging = {}

-- Sets the service (a memory bus in tests) and the publish attempts. Existing subscriptions
-- move to the new service.
function Messaging.configure(config: Config)
	if type(config) ~= "table" then
		error(`[HYDROGEN] Messaging.configure expects a table`, 2)
	end
	local service = config.service
	if service ~= nil then
		for _, method in { "PublishAsync", "SubscribeAsync" } do
			if type((service :: any)[method]) ~= "function" then
				error(`[HYDROGEN] Messaging.configure: service is missing {method}`, 2)
			end
		end
	end
	if config.attempts ~= nil and (type(config.attempts) ~= "number" or config.attempts < 1) then
		error(`[HYDROGEN] Messaging.configure: attempts must be a number, at least 1`, 2)
	end
	options.service = service
	options.attempts = config.attempts or DEFAULT_ATTEMPTS
	table.clear(sent)
	for _, topic in topics do
		if topic.connection then
			unsubscribe(topic)
		end
		if #topic.listeners > 0 then
			ensureSubscribed(topic)
		end
	end
end

--[=[
	A typed topic. Define each once, in a module the servers that use it require:

	local Announcements = Hydrogen.Messaging.topic("Announcements", gt.table({ text = gt.string() }))
	Announcements:publish({ text = "Double XP!" })
	Announcements:subscribe(function(value, info) print(value.text, info.fromThisServer) end)
]=]
function Messaging.topic<T>(name: string, schema: T, topicOptions: TopicOptions?): Types.Topic<T>
	if type(name) ~= "string" or name == "" or #name > MAX_NAME then
		error(`[HYDROGEN] Messaging.topic needs a name of 1 to {MAX_NAME} characters`, 2)
	end
	if topics[name] then
		error(`[HYDROGEN] Messaging topic {name} is already defined; define each topic once, in a module, and require that`, 2)
	end
	if type(schema) ~= "table" or type((schema :: any).matches) ~= "function" then
		error(`[HYDROGEN] Messaging topic {name} needs a GreenTea schema (Hydrogen.gt), got {typeof(schema)}`, 2)
	end
	if topicOptions ~= nil and type(topicOptions) ~= "table" then
		error(`[HYDROGEN] Messaging topic {name}: options must be a table`, 2)
	end

	local state: TopicState = {
		name = name,
		schema = schema,
		ignoreSelf = topicOptions ~= nil and topicOptions.ignoreSelf == true,
		listeners = {},
		connection = nil,
		live = nil,
		subscribing = false,
		warnedAt = nil,
		suppressed = 0,
	}
	topics[name] = state

	local topic = { name = name }

	function topic.publish(_self: any, value: T): (boolean, string?)
		serverOnly(`Messaging topic {name}:publish`)
		local ok, cause = state.schema:matches(value)
		if not ok then
			error(`[HYDROGEN] Messaging topic {name}: can't publish a value that doesn't match the schema: {cause}`, 2)
		end
		local problem = Json.check(value)
		if problem then
			error(`[HYDROGEN] Messaging topic {name}: can't publish it: {problem}`, 2)
		end
		local envelope = { s = serverId(), v = Tables.copy(value) }
		local size = Json.size(envelope) or 0
		if size > MAX_BYTES then
			error(
				`[HYDROGEN] Messaging topic {name}: the message is {size} bytes as JSON, over MessagingService's {MAX_BYTES}-byte limit; send ids and look the rest up (DataStore, MemoryStore)`,
				2
			)
		end

		local attempts = options.attempts
		local lastError: any = nil
		local started = generation
		for attempt = 1, attempts do
			waitForBudget(started)
			local service = currentService()
			local sentOk, err = pcall(service.PublishAsync, service, name, envelope)
			if sentOk then
				return true, nil
			end
			lastError = err
			if generation ~= started then
				break
			elseif attempt < attempts then
				Time.wait(math.min(2 ^ (attempt - 1), 8))
			end
		end
		local message = tostring(lastError)
		Log.warn(`[HYDROGEN] Messaging couldn't publish to topic {name}: {message}`)
		return false, message
	end

	function topic.subscribe(_self: any, callback: (value: T, info: MessageInfo) -> ()): () -> ()
		serverOnly(`Messaging topic {name}:subscribe`)
		if type(callback) ~= "function" then
			error(`[HYDROGEN] Messaging topic {name}:subscribe expects a function, got {typeof(callback)}`, 2)
		end
		local listener: Listener = { callback = callback :: any }
		table.insert(state.listeners, listener)
		ensureSubscribed(state)

		local subscribed = true
		return function()
			if not subscribed then
				return
			end
			subscribed = false
			local index = table.find(state.listeners, listener)
			if index then
				table.remove(state.listeners, index)
			end
			if #state.listeners == 0 then
				unsubscribe(state)
			end
		end
	end

	return table.freeze(topic) :: any
end

-- This server's id in messages: game.JobId, or a generated id in Studio and tests.
Messaging.serverId = serverId

-- Stands in for MessagingService in tests; see MemoryBus.
Messaging.memoryBus = MemoryBus.new

-- On app:stop() (shutdown, or the end of a test): every subscription is dropped and publishes
-- stop retrying.
function Messaging:stop()
	generation += 1
	for _, topic in topics do
		table.clear(topic.listeners)
		unsubscribe(topic)
	end
end

return Definition.define("Hydrogen.Messaging", function()
	return Messaging
end)
