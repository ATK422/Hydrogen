--!strict

-- Per-player state with saved and runtime fields and per-field replication. See Define for the API.
local Define = require("@self/Define")

export type Audience = Define.Audience
export type Options<D, R> = Define.Options<D, R>
export type PlayerState<S> = Define.PlayerState<S>

return Define
