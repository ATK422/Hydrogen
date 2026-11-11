--!strict

export type Connection = {
	Disconnect: (self: any) -> (),
}

-- What MessagingService passes to a subscription callback.
export type Message = {
	Data: any,
	Sent: number,
}

-- The parts of MessagingService Messaging uses, so a memory bus can stand in for it.
export type Backend = {
	PublishAsync: (self: any, topic: string, message: any) -> (),
	SubscribeAsync: (self: any, topic: string, callback: (message: Message) -> ()) -> Connection,
}

-- Passed to subscribers with each value.
export type MessageInfo = {
	-- When the message was sent (MessagingService's Sent).
	sent: number,
	-- The sending server's id (its game.JobId, or Messaging.serverId()).
	serverId: string,
	-- This server sent it.
	fromThisServer: boolean,
}

export type TopicOptions = {
	-- Don't deliver messages this server published to this server's subscribers. Default false:
	-- MessagingService delivers a server's own messages to it too.
	ignoreSelf: boolean?,
}

-- A named, typed MessagingService topic.
export type Topic<T> = {
	name: string,
	-- Checks value against the schema and the size limit (errors at once if it fails), then
	-- sends it, retrying failures. Yields. Returns whether MessagingService accepted it.
	publish: (self: Topic<T>, value: T) -> (boolean, string?),
	-- Calls callback with every valid message from now on. The first subscriber on a topic
	-- subscribes with MessagingService (in the background). Returns a function that unsubscribes.
	subscribe: (self: Topic<T>, callback: (value: T, info: MessageInfo) -> ()) -> () -> (),
}

export type Config = {
	-- Stands in for MessagingService, e.g. Messaging.memoryBus() in tests.
	service: Backend?,
	-- PublishAsync attempts per publish. Default 3.
	attempts: number?,
}

return {}
