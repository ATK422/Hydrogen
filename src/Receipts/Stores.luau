--!strict

local Clock = require("./Clock")
local Log = require("./Log")
local Types = require("./Types")

type Receipt = Types.Receipt
type ReceiptStore = Types.ReceiptStore

export type MemoryStore = ReceiptStore & {
	-- Makes the next `count` saves fail, as a DataStore outage would.
	failSaves: (self: MemoryStore, count: number) -> (),
	-- Whether the purchase is recorded and saved.
	isSaved: (self: MemoryStore, purchaseId: string) -> boolean,
	-- How many purchases are recorded and saved.
	savedCount: (self: MemoryStore) -> number,
}

-- The parts of a DataStore the default store uses, so a fake can stand in for one.
export type DataStoreLike = {
	GetAsync: (self: any, key: string) -> any,
	SetAsync: (self: any, key: string, value: any, userIds: { number }?) -> any,
}

local DEFAULT_NAME = "HydrogenReceipts"
-- Waits between DataStore attempts: three tries in all.
local RETRY_DELAYS = { 1, 2 }

local Stores = {}

-- Keeps everything in this VM. For tests: it survives as long as the store table does.
function Stores.memoryStore(): MemoryStore
	local saved: { [string]: Receipt } = {}
	local unsaved: { [string]: Receipt } = {}
	local failures = 0

	local store = {}

	local function persist(purchaseId: string)
		if failures > 0 then
			failures -= 1
			error("[HYDROGEN] memoryStore: simulated save failure", 0)
		end
		saved[purchaseId] = unsaved[purchaseId]
		unsaved[purchaseId] = nil
	end

	function store.isGranted(_self: any, _player: Player, receipt: Receipt): boolean
		return saved[receipt.PurchaseId] ~= nil or unsaved[receipt.PurchaseId] ~= nil
	end

	function store.record(_self: any, _player: Player, receipt: Receipt, grant: () -> ())
		grant()
		unsaved[receipt.PurchaseId] = receipt
		persist(receipt.PurchaseId)
	end

	function store.save(_self: any, _player: Player, receipt: Receipt)
		if unsaved[receipt.PurchaseId] then
			persist(receipt.PurchaseId)
		end
	end

	function store.failSaves(_self: any, count: number)
		failures = count
	end

	function store.isSaved(_self: any, purchaseId: string): boolean
		return saved[purchaseId] ~= nil
	end

	function store.savedCount(_self: any): number
		local count = 0
		for _ in saved do
			count += 1
		end
		return count
	end

	return store :: any
end

local function withRetries<T...>(callback: (T...) -> any, ...: T...): any
	local ok, result = pcall(callback, ...)
	for _, delay in RETRY_DELAYS do
		if ok then
			break
		end
		Clock.wait(delay)
		ok, result = pcall(callback, ...)
	end
	if not ok then
		error(result, 0)
	end
	return result
end

-- One DataStore key per purchase, written after the grant. Nothing is read or written for
-- players who never buy anything. It can't share a save with your game's data, so a crash
-- between the two can grant twice or lose a grant; see the README.
function Stores.dataStore(source: (string | DataStoreLike)?): ReceiptStore
	local name = if type(source) == "string" then source else DEFAULT_NAME
	local dataStore: DataStoreLike? = if type(source) == "table" then source else nil

	-- Purchases known to be saved (purchase id -> UserId), and ones granted here whose save
	-- hasn't succeeded yet.
	local saved: { [string]: number } = {}
	local unsaved: { [string]: Receipt } = {}

	-- Resolved on first use, so creating the store touches nothing.
	local function resolve(): DataStoreLike
		if not dataStore then
			dataStore = (game:GetService("DataStoreService") :: any):GetDataStore(name)
		end
		return dataStore :: DataStoreLike
	end

	local function write(receipt: Receipt)
		local target = resolve()
		withRetries(function()
			return target:SetAsync(receipt.PurchaseId, {
				userId = receipt.PlayerId,
				productId = receipt.ProductId,
				placeId = receipt.PlaceIdWherePurchased,
				spent = receipt.CurrencySpent,
				time = os.time(),
			}, { receipt.PlayerId })
		end)
		saved[receipt.PurchaseId] = receipt.PlayerId
		unsaved[receipt.PurchaseId] = nil
	end

	local store = {}

	function store.isGranted(_self: any, _player: Player, receipt: Receipt): boolean
		local purchaseId = receipt.PurchaseId
		if saved[purchaseId] or unsaved[purchaseId] then
			return true
		end
		local target = resolve()
		local value = withRetries(function()
			return target:GetAsync(purchaseId)
		end)
		if value ~= nil then
			saved[purchaseId] = receipt.PlayerId
			return true
		end
		return false
	end

	function store.record(_self: any, _player: Player, receipt: Receipt, grant: () -> ())
		grant()
		unsaved[receipt.PurchaseId] = receipt
		write(receipt)
	end

	function store.save(_self: any, _player: Player, receipt: Receipt)
		if unsaved[receipt.PurchaseId] then
			write(receipt)
		end
	end

	-- One last try for grants still unsaved, then forget the player's purchases.
	function store.release(_self: any, player: Player)
		for purchaseId, receipt in table.clone(unsaved) do
			if receipt.PlayerId == player.UserId then
				local ok, err = pcall(write, receipt)
				if not ok then
					Log.warn(`[HYDROGEN] Receipts couldn't save purchase {purchaseId} for {player.Name} before they left: {err}`)
					unsaved[purchaseId] = nil
				end
			end
		end
		for purchaseId, userId in table.clone(saved) do
			if userId == player.UserId then
				saved[purchaseId] = nil
			end
		end
	end

	return store :: any
end

-- The parts of a Hydrogen.Data player store fromData uses.
export type PlayerDataLike = {
	waitForLoad: (self: any, player: Player, timeout: number?) -> boolean,
	updateOnce: (self: any, player: Player, id: string, fn: (data: any) -> ...any) -> string,
	save: (self: any, player: Player) -> (boolean, string?),
}

-- Records purchases in a Hydrogen.Data player store: the purchase id goes into the same save as
-- the grant (updateOnce), so a purchase is granted exactly once. Handlers get the store's draft
-- data after the receipt; change it, not the store, to keep the grant in that save.
function Stores.fromData(playerData: PlayerDataLike): ReceiptStore
	local store = {}

	function store.load(_self: any, player: Player): boolean
		return playerData:waitForLoad(player)
	end

	-- updateOnce does the dedupe, against the ids kept with the player's data.
	function store.isGranted(_self: any, _player: Player, _receipt: Receipt): boolean
		return false
	end

	function store.record(_self: any, player: Player, receipt: Receipt, grant: (...any) -> ())
		local result = playerData:updateOnce(player, receipt.PurchaseId, function(data)
			grant(data)
		end)
		if result ~= "applied" and result ~= "duplicate" then
			error(`[HYDROGEN] Receipts: couldn't record purchase {receipt.PurchaseId} in player data ({result})`, 0)
		end
	end

	-- Receipts retries through this when updateOnce committed but its save failed.
	function store.save(_self: any, player: Player, _receipt: Receipt)
		local ok, err = playerData:save(player)
		if not ok then
			error(`[HYDROGEN] Receipts: couldn't save player data: {err}`, 0)
		end
	end

	return store :: any
end

return Stores
