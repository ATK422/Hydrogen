--!strict

local Types = require("./Types")

type Receipt = Types.Receipt
type Decision = Types.Decision
type Connection = Types.Connection

export type Prompt = {
	player: Player,
	kind: "product" | "gamePass",
	id: number,
}

-- Stands in for MarketplaceService in tests. It also plays Roblox's part: purchases build a
-- receipt and call ProcessReceipt, and receipts not granted stay pending until retried.
export type FakeMarketplace = Types.Marketplace & {
	-- Buys a developer product: builds a receipt, calls ProcessReceipt and returns its answer.
	-- `fields` overrides receipt fields, e.g. { PurchaseId = "same" } to send a duplicate.
	purchase: (self: FakeMarketplace, player: Player, productId: number, fields: { [string]: any }?) -> (Decision, Receipt),
	-- Calls ProcessReceipt with a receipt again, as Roblox does when a purchase wasn't granted.
	deliver: (self: FakeMarketplace, receipt: Receipt) -> Decision,
	-- Receipts not granted yet, oldest first, optionally only one player's.
	pending: (self: FakeMarketplace, player: Player?) -> { Receipt },
	-- Delivers every pending receipt again (for one player: what Roblox does when they rejoin).
	-- Returns the answers in order.
	retryPending: (self: FakeMarketplace, player: Player?) -> { Decision },
	-- Sets whether UserOwnsGamePassAsync reports the pass as owned.
	setOwnsGamePass: (self: FakeMarketplace, player: Player, passId: number, owns: boolean) -> (),
	-- Buys a game pass in game: marks it owned and fires PromptGamePassPurchaseFinished.
	buyGamePass: (self: FakeMarketplace, player: Player, passId: number) -> (),
	-- Makes the next `count` UserOwnsGamePassAsync calls error, as a web outage would.
	failOwnershipChecks: (self: FakeMarketplace, count: number) -> (),
	-- How many times UserOwnsGamePassAsync was called.
	ownershipChecks: number,
	-- Every PromptProductPurchase and PromptGamePassPurchase, in order.
	prompts: { Prompt },
}

local function new(): FakeMarketplace
	local listeners: { (Player, number, boolean) -> () } = {}
	local owned: { [number]: { [number]: boolean } } = {}
	local pending: { Receipt } = {}
	local purchases = 0
	local ownershipFailures = 0

	local market = {
		ProcessReceipt = nil :: any,
		ownershipChecks = 0,
		prompts = {} :: { Prompt },
	}

	market.PromptGamePassPurchaseFinished = {
		Connect = function(_self: any, callback: (Player, number, boolean) -> ()): Connection
			table.insert(listeners, callback)
			return {
				Disconnect = function(_: any)
					local index = table.find(listeners, callback)
					if index then
						table.remove(listeners, index)
					end
				end,
			}
		end,
	}

	function market.UserOwnsGamePassAsync(self: any, userId: number, passId: number): boolean
		self.ownershipChecks += 1
		if ownershipFailures > 0 then
			ownershipFailures -= 1
			error("[HYDROGEN] fakeMarketplace: simulated UserOwnsGamePassAsync failure", 0)
		end
		local passes = owned[userId]
		return passes ~= nil and passes[passId] == true
	end

	function market.PromptProductPurchase(self: any, player: Player, productId: number)
		table.insert(self.prompts, { player = player, kind = "product", id = productId })
	end

	function market.PromptGamePassPurchase(self: any, player: Player, passId: number)
		table.insert(self.prompts, { player = player, kind = "gamePass", id = passId })
	end

	function market.deliver(self: any, receipt: Receipt): Decision
		local callback = self.ProcessReceipt
		if type(callback) ~= "function" then
			error("[HYDROGEN] fakeMarketplace: ProcessReceipt isn't set; add Hydrogen.Receipts to an app and start it", 2)
		end

		if not table.find(pending, receipt) then
			table.insert(pending, receipt)
		end
		local decision = callback(receipt)
		if decision == "PurchaseGranted" then
			local index = table.find(pending, receipt)
			if index then
				table.remove(pending, index)
			end
		end
		return decision
	end

	function market.purchase(self: any, player: Player, productId: number, fields: { [string]: any }?): (Decision, Receipt)
		purchases += 1
		local receipt: Receipt = {
			PurchaseId = `fake-purchase-{purchases}`,
			PlayerId = player.UserId,
			ProductId = productId,
			PlaceIdWherePurchased = 0,
			CurrencySpent = 0,
			CurrencyType = "Robux",
			ProductPurchaseChannel = "InExperience",
		}
		if fields then
			for key, value in fields do
				(receipt :: any)[key] = value
			end
		end
		return self:deliver(receipt), receipt
	end

	function market.pending(_self: any, player: Player?): { Receipt }
		local result = {}
		for _, receipt in pending do
			if player == nil or receipt.PlayerId == player.UserId then
				table.insert(result, receipt)
			end
		end
		return result
	end

	function market.retryPending(self: any, player: Player?): { Decision }
		local decisions = {}
		for _, receipt in self:pending(player) do
			table.insert(decisions, self:deliver(receipt))
		end
		return decisions
	end

	function market.setOwnsGamePass(_self: any, player: Player, passId: number, owns: boolean)
		local passes = owned[player.UserId]
		if not passes then
			passes = {}
			owned[player.UserId] = passes
		end
		passes[passId] = owns
	end

	function market.buyGamePass(self: any, player: Player, passId: number)
		self:setOwnsGamePass(player, passId, true)
		for _, listener in table.clone(listeners) do
			listener(player, passId, true)
		end
	end

	function market.failOwnershipChecks(_self: any, count: number)
		ownershipFailures = count
	end

	return market :: any
end

return {
	new = new,
}
