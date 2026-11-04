--!strict

local Types = require("@self/Types")
local Stores = require("@self/Stores")
local FakeMarketplace = require("@self/FakeMarketplace")

export type Receipt = Types.Receipt
export type Decision = Types.Decision
export type ProductHandler = Types.ProductHandler
export type GamePassHandler = Types.GamePassHandler
export type ReceiptStore = Types.ReceiptStore
export type Marketplace = Types.Marketplace
export type ReceiptsOptions = Types.ReceiptsOptions
export type MemoryStore = Stores.MemoryStore
export type DataStoreLike = Stores.DataStoreLike
export type FakeMarketplace = FakeMarketplace.FakeMarketplace

return require("@self/Receipts")
