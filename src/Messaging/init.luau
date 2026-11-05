--!strict

local Types = require("@self/Types")
local MemoryBus = require("@self/MemoryBus")

export type Backend = Types.Backend
export type Connection = Types.Connection
export type Message = Types.Message
export type MessageInfo = Types.MessageInfo
export type TopicOptions = Types.TopicOptions
export type Topic<T> = Types.Topic<T>
export type Config = Types.Config
export type MemoryBus = MemoryBus.MemoryBus
export type Published = MemoryBus.Published

return require("@self/Messaging")
