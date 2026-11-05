--!strict

local Types = require("@self/Types")
local FakeService = require("@self/FakeService")

export type FailReason = Types.FailReason
export type Failure = Types.Failure
export type Result = Types.Result
export type SendOptions = Types.SendOptions
export type Request = Types.Request
export type Accepted = Types.Accepted
export type Backend = Types.Backend
export type Config = Types.Config
export type Ticket<T> = Types.Ticket<T>
export type FakeTeleportService = FakeService.FakeTeleportService

return require("@self/Teleport")
