--!strict

local Types = require("./Types")
local Tables = require("../Data/Tables")
local Time = require("../Clock")

type Connection = Types.Connection
type Message = Types.Message

export type Published = {
	topic: string,
	-- What was handed to PublishAsync: Hydrogen's envelope { s = serverId, v = value }.
	data: any,
}

-- Stands in for MessagingService in tests. Publishing delivers to every subscriber of the topic
-- at once, including the publisher's own server, as MessagingService does.
export type MemoryBus = Types.Backend & {
	-- Every accepted PublishAsync, oldest first.
	published: { Published },
	-- Delivers value on topic as if another server published it (wrapped like Hydrogen does).
	send: (self: MemoryBus, topic: string, value: any, serverId: string?) -> (),
	-- Delivers data on topic exactly as given, without Hydrogen's envelope (malformed messages).
	sendRaw: (self: MemoryBus, topic: string, data: any) -> (),
	-- The next `count` PublishAsync calls error.
	failPublishes: (self: MemoryBus, count: number, message: string?) -> (),
	-- The next `count` SubscribeAsync calls error.
	failSubscribes: (self: MemoryBus, count: number, message: string?) -> (),
	-- Open subscriptions, on one topic or all.
	subscriptions: (self: MemoryBus, topic: string?) -> number,
	-- SubscribeAsync calls made, on one topic or all.
	subscribeCalls: (self: MemoryBus, topic: string?) -> number,
}

local function new(): MemoryBus
	local subscribers: { [string]: { (Message) -> () } } = {}
	local calls: { [string]: number } = {}
	local publishFailures: { string } = {}
	local subscribeFailures: { string } = {}

	local bus = {
		published = {} :: { Published },
	}

	local function deliver(topic: string, data: any)
		local list = subscribers[topic]
		if not list then
			return
		end
		for _, callback in table.clone(list) do
			-- Each server gets its own decoded copy.
			task.spawn(callback, { Data = Tables.copy(data), Sent = Time.time() })
		end
	end

	function bus.PublishAsync(self: any, topic: string, data: any)
		local message = table.remove(publishFailures, 1)
		if message then
			error(message, 0)
		end
		local copy = Tables.copy(data)
		table.insert(self.published, { topic = topic, data = copy })
		deliver(topic, copy)
	end

	function bus.SubscribeAsync(_self: any, topic: string, callback: (Message) -> ()): Connection
		calls[topic] = (calls[topic] or 0) + 1
		local message = table.remove(subscribeFailures, 1)
		if message then
			error(message, 0)
		end
		local list = subscribers[topic]
		if not list then
			list = {}
			subscribers[topic] = list
		end
		table.insert(list, callback)
		return {
			Connected = true,
			Disconnect = function(connection: any)
				connection.Connected = false
				local current = subscribers[topic]
				local index = current and table.find(current, callback)
				if current and index then
					table.remove(current, index)
				end
			end,
		} :: any
	end

	function bus.send(_self: any, topic: string, value: any, serverId: string?)
		deliver(topic, { s = serverId or "memory-bus-server", v = Tables.copy(value) })
	end

	function bus.sendRaw(_self: any, topic: string, data: any)
		deliver(topic, Tables.copy(data))
	end

	function bus.failPublishes(_self: any, count: number, message: string?)
		for _ = 1, count do
			table.insert(publishFailures, message or "memory bus: simulated PublishAsync failure")
		end
	end

	function bus.failSubscribes(_self: any, count: number, message: string?)
		for _ = 1, count do
			table.insert(subscribeFailures, message or "memory bus: simulated SubscribeAsync failure")
		end
	end

	function bus.subscriptions(_self: any, topic: string?): number
		if topic then
			local list = subscribers[topic]
			return if list then #list else 0
		end
		local total = 0
		for _, list in subscribers do
			total += #list
		end
		return total
	end

	function bus.subscribeCalls(_self: any, topic: string?): number
		if topic then
			return calls[topic] or 0
		end
		local total = 0
		for _, count in calls do
			total += count
		end
		return total
	end

	return bus :: any
end

return {
	new = new,
}
