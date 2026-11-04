--!strict

-- Session-locked DataStore persistence. See Stores for the API.
local Stores = require("@self/Stores")

export type Backend = Stores.Backend
export type MemoryBackend = Stores.MemoryBackend
export type RequestKind = Stores.RequestKind
export type Migration = Stores.Migration
export type UpdateOnceResult = Stores.UpdateOnceResult
export type PlayerOptions<T> = Stores.PlayerOptions<T>
export type StoreOptions<T> = Stores.StoreOptions<T>
export type PlayerStore<T> = Stores.PlayerStore<T>
export type KeyStore<T> = Stores.KeyStore<T>

return Stores
