--!strict

-- What Roblox passes to MarketplaceService.ProcessReceipt.
export type Receipt = {
	PurchaseId: string,
	PlayerId: number,
	ProductId: number,
	PlaceIdWherePurchased: number,
	CurrencySpent: number,
	-- Enum.CurrencyType and Enum.ProductPurchaseChannel in a real game.
	CurrencyType: any,
	ProductPurchaseChannel: any,
}

-- What ProcessReceipt answers. A real MarketplaceService gets the matching
-- Enum.ProductPurchaseDecision; an injected marketplace gets the string.
export type Decision = "PurchaseGranted" | "NotProcessedYet"

-- Grants a developer product. Return nothing to grant. Return false to decline for now:
-- nothing is recorded and Roblox offers the receipt again later. An error does the same,
-- with a warning. Anything the store passes to grant(...) comes after the receipt, e.g. the
-- player's data table from a data system's store.
export type ProductHandler = (player: Player, receipt: Receipt, ...any) -> ...boolean

-- Runs once per session for a player who owns the pass, when they join or buy it.
export type GamePassHandler = (player: Player, passId: number) -> ()

-- Where Receipts records which purchases were granted. The record has to live in the same
-- save as the grant itself for a purchase to be granted exactly once; see the README.
export type ReceiptStore = {
	-- Optional. Yields until the player's purchase record can be read. Return false when it
	-- can't (loading failed); their receipts then wait for another server.
	load: ((self: any, player: Player) -> boolean?)?,
	-- Whether this purchase was already granted, saved or not. May yield. Error when it can't tell.
	isGranted: (self: any, player: Player, receipt: Receipt) -> boolean,
	-- Calls grant, records the purchase in the same save as grant's changes, and returns once
	-- that save is durable. If grant errors, record nothing and let the error through.
	-- Error if the save fails. Arguments passed to grant(...) reach the handler after the receipt.
	-- If the purchase turns out to be recorded and durable already, return without calling
	-- grant: Receipts then answers PurchaseGranted without granting.
	record: (self: any, player: Player, receipt: Receipt, grant: (...any) -> ()) -> (),
	-- Makes a purchase that record or an earlier server already recorded durable.
	-- Returns at once when it already is. Error if the save fails.
	save: (self: any, player: Player, receipt: Receipt) -> (),
	-- Optional. The player left and their receipts are done; drop anything cached for them.
	release: ((self: any, player: Player) -> ())?,
}

export type Connection = {
	Disconnect: (self: any) -> (),
}

-- The parts of MarketplaceService Receipts uses, so a fake can stand in for it.
export type Marketplace = {
	ProcessReceipt: any,
	PromptGamePassPurchaseFinished: {
		Connect: (self: any, callback: (player: Player, passId: number, wasPurchased: boolean) -> ()) -> Connection,
	},
	UserOwnsGamePassAsync: (self: any, userId: number, passId: number) -> boolean,
	PromptProductPurchase: (self: any, player: Player, productId: number) -> (),
	PromptGamePassPurchase: (self: any, player: Player, passId: number) -> (),
}

export type ReceiptsOptions = {
	-- Where granted purchases are recorded. Defaults to Receipts.dataStore().
	store: ReceiptStore?,
	-- Stands in for MarketplaceService, e.g. Receipts.fakeMarketplace() in tests.
	marketplace: Marketplace?,
	-- Seconds a receipt waits for its player to join and load before it is left for later.
	-- Defaults to 30.
	loadTimeout: number?,
}

return {}
