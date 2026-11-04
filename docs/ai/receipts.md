# Hydrogen.Receipts

> A server system that owns `MarketplaceService.ProcessReceipt`, routes each developer product purchase to the handler registered for its product id, and grants it exactly once (it answers `PurchaseGranted` only after the grant is saved); it also caches game pass ownership and runs per-pass handlers.

## Use it when / Don't use it when

Use it when:
- the game sells developer products (consumables: currency, boosts, revives) and must never lose or double-grant one;
- several systems sell things but `ProcessReceipt` can only be set once per server;
- you need game pass ownership checks (`owns`) or perks applied to pass owners on join and on in-game purchase.

Don't use it when:
- you only need to show a prompt from the client: call `MarketplaceService:PromptProductPurchase` there directly (granting still goes through Receipts on the server);
- something else in the game already sets `MarketplaceService.ProcessReceipt` (remove it; two setters overwrite each other);
- you need subscriptions or Avatar Shop items: Receipts handles developer products and game passes only.

## Quick start

Server boot. Receipts is a Hydrogen system: add it to the app, after the system that saves player data.

```luau
-- ServerScriptService/Main.server.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local app = Hydrogen.App.new()
app:addSystemsFolders(ServerScriptService.Systems)
app:addSystem(Hydrogen.Receipts) -- after the data system, so its playerRemoving runs first
app:start()
```

A system that sells things. Handlers are registered in the constructor.

```luau
-- ServerScriptService/Systems/Shop.luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

local COINS_100 = 1234567
local VIP_PASS = 7654321

return Hydrogen.define(function(use)
	local Receipts = use(Hydrogen.Receipts)

	local coins: { [Player]: number } = {}
	local vip: { [Player]: boolean } = {}

	Receipts.product(COINS_100, function(player: Player, _receipt: Hydrogen.Receipt)
		coins[player] = (coins[player] or 0) + 100
	end)

	Receipts.gamePass(VIP_PASS, function(player: Player, _passId: number)
		vip[player] = true
	end)

	local Shop = {}

	function Shop.buyCoins(player: Player)
		Receipts.promptProduct(player, COINS_100)
	end

	function Shop.isVip(player: Player): boolean
		return Receipts.owns(player, VIP_PASS) -- yields the first time per player and pass
	end

	return Shop
end)
```

With no `configure` call, purchases are recorded in the default DataStore store (`HydrogenReceipts`). To grant exactly once, record purchases in your player data instead (see "Stores" in Recipes).

Client: nothing to add. Prompt with `MarketplaceService:PromptProductPurchase(Players.LocalPlayer, id)`, or ask the server to call `Receipts.promptProduct`.

## API

All of this is server-only unless noted. `Receipts` below is `Hydrogen.Receipts` (or what `use(Hydrogen.Receipts)` returns).

Handlers and callbacks:
- `Receipts.product(productId: number, handler: ProductHandler): () -> ()`: registers the handler for a developer product; returns a function that removes it. Errors if the product already has one.
- `Receipts.products(handlers: { [number]: ProductHandler }): () -> ()`: registers several; if any id is taken, registers none and errors. Returns a remover for all.
- `Receipts.gamePass(passId: number, handler: GamePassHandler): () -> ()`: runs `handler` once per session for each owner (on join, or when bought in game). A pass can have several handlers. Registered after players joined: checks them too.
- `Receipts.gamePasses(handlers: { [number]: GamePassHandler }): () -> ()`: several at once.
- `Receipts.onGranted(callback: (player: Player, receipt: Receipt) -> ()): () -> ()`: called after each purchase this server grants and saves (history, analytics). Runs in its own thread; errors are warned. Not called for duplicates. Returns a disconnect function.

Queries and prompts:
- `Receipts.owns(player: Player, passId: number): boolean`: **yields** the first time per player and pass (`UserOwnsGamePassAsync`, three tries), then cached for the session; an in-game purchase sets it to `true`. Returns `false` without caching if Roblox can't be reached. Works on the client too, uncached.
- `Receipts.promptProduct(player: Player, productId: number)`: `MarketplaceService:PromptProductPurchase`.
- `Receipts.promptGamePass(player: Player, passId: number)`: `MarketplaceService:PromptGamePassPurchase`.

Configuration and stores:
- `Receipts.configure(options: ReceiptsOptions)`: replaces all options. Call before Receipts starts (main script, or any system's `init`); errors afterwards.
- `Receipts.dataStore(source: (string | DataStoreLike)?): ReceiptStore`: the default store. A name (default `"HydrogenReceipts"`) or a DataStore-like object (`GetAsync`, `SetAsync`) for tests. Creating it makes no requests.
- `Receipts.memoryStore(): MemoryStore`: in-memory store for tests.
- `Receipts.fromData(playerData: PlayerStore<any>): ReceiptStore`: records each purchase in a `Hydrogen.Data.player` store, in the same save as the grant (via `updateOnce`). Handlers receive the draft data as their third argument. The recommended store when the game uses `Hydrogen.Data`.
- `Receipts.fakeMarketplace(): FakeMarketplace`: stand-in `MarketplaceService` for tests.

Types (import from `Hydrogen`):
```luau
type Receipt = { -- what Roblox passes to ProcessReceipt
	PurchaseId: string, PlayerId: number, ProductId: number,
	PlaceIdWherePurchased: number, CurrencySpent: number,
	CurrencyType: any, ProductPurchaseChannel: any,
}
type PurchaseDecision = "PurchaseGranted" | "NotProcessedYet"
-- Return nothing to grant; return false to decline for now. Extra args come from the store's grant(...).
type ProductHandler = (player: Player, receipt: Receipt, ...any) -> ...boolean
type GamePassHandler = (player: Player, passId: number) -> ()
type ReceiptsOptions = {
	store: ReceiptStore?,        -- default Receipts.dataStore()
	marketplace: Marketplace?,   -- default MarketplaceService; a fake in tests
	loadTimeout: number?,        -- seconds a receipt waits for its player; default 30
}
type ReceiptStore = {
	load: ((self: any, player: Player) -> boolean?)?,  -- optional; yield until readable; false = load failed
	isGranted: (self: any, player: Player, receipt: Receipt) -> boolean, -- saved or not; error = can't tell
	-- Call grant(...), record receipt.PurchaseId in the SAME save, return once durable.
	-- grant errors -> record nothing, rethrow. Save fails -> error.
	-- Already recorded and durable -> return without calling grant (answered PurchaseGranted).
	record: (self: any, player: Player, receipt: Receipt, grant: (...any) -> ()) -> (),
	save: (self: any, player: Player, receipt: Receipt) -> (), -- make a recorded purchase durable; error on failure
	release: ((self: any, player: Player) -> ())?,      -- optional; player left
}
```
Also exported: `Hydrogen.Marketplace` (the parts of MarketplaceService used), `Hydrogen.MemoryReceiptStore` (`ReceiptStore` plus `failSaves(count)`, `isSaved(purchaseId): boolean`, `savedCount(): number`) and `Hydrogen.FakeMarketplace` (see Testing).

## Rules

- **Add `Hydrogen.Receipts` to the app.** `use` alone doesn't bind anything; without `app:addSystem(Hydrogen.Receipts)` Hydrogen warns that a dependency wasn't added and `ProcessReceipt` is never set.
- **Receipts sets `ProcessReceipt` in its `start`.** On the client (or under Lune without a fake marketplace) it binds nothing.
- **One handler per developer product.** A second `product` for the same id errors. Unregister with the returned function.
- **A receipt waits for its player** to be in the server and for `store:load` to finish, up to `loadTimeout` (30 s). Pending receipts are re-sent as the player joins, while their data is still loading; waiting avoids pushing them to the next visit.
- **Answer rules.** `PurchaseGranted` only after `store:record` (or `store:save` for an already recorded purchase) returned. Everything else is `NotProcessedYet`, which makes Roblox offer the receipt again later (usually on the player's next join):
  player left / not loaded in time / load failed; handler errored (warned) or returned `false` (silent); no handler for the product (warned once per purchase); `store:isGranted` errored; the save failed after two retries; the server is shutting down.
- **A failed save after the grant can't cause a second grant.** The purchase stays recorded, so later tries call `store:save` only.
- **One receipt at a time per player.** A second receipt waits. The same `PurchaseId` arriving while the first call runs waits for and returns the first call's answer.
- **Handlers may yield** with the default or memory store, but keep them short: the player's other receipts wait, and a yield gives the player time to leave. With a data-backed store (`updateOnce`), don't yield: the change and the purchase id must commit together.
- **Leaving:** Receipts' `playerRemoving` waits up to 15 s for a grant already in progress. `playerRemoving` runs in reverse order, and unrelated systems run in add order, so add Receipts *after* the data system for that data system to save including the grant.
- **Shutdown (`app:stop()`, bound to `BindToClose`):** receipts not yet granting answer `NotProcessedYet`; grants in progress finish (up to 15 s). Afterwards `ProcessReceipt` stays bound and answers `NotProcessedYet`.
- **Game passes:** ownership is cached per player per session, including `false`. A purchase on the website mid-session isn't seen until the next session; an in-game purchase (`PromptGamePassPurchaseFinished`) is. Each pass handler runs at most once per player per session.
- **A real `MarketplaceService` gets `Enum.ProductPurchaseDecision` items; an injected marketplace gets the strings.**

## Recipes

Snippets run inside a system constructor where `local Receipts = use(Hydrogen.Receipts)`; `Wallet` and `Inventory` stand for your own systems.

### Several products in one table, with a decline
```luau
Receipts.products({
	[COINS_100] = function(player: Player, _receipt: Hydrogen.Receipt)
		Wallet.add(player, 100)
	end,
	[SWORD] = function(player: Player, _receipt: Hydrogen.Receipt): boolean
		if Inventory.isFull(player) then
			return false -- not now; Roblox re-offers the receipt later
		end
		Inventory.give(player, "Sword")
		return true
	end,
})
```

### Exactly-once with Hydrogen.Data
`Hydrogen.Receipts.fromData(PlayerData)` records the purchase id in the player's data in the same commit as the change, via `PlayerData:updateOnce`, so a purchase is never granted twice or lost. Prefer it over the standalone store whenever the game uses `Hydrogen.Data`.

```luau
-- Main.server.luau, before app:start():
Hydrogen.Receipts.configure({ store = Hydrogen.Receipts.fromData(PlayerData) })

-- Handlers then change the data argument, not the store:
Hydrogen.Receipts.product(COINS_100, function(_player: Player, _receipt: Hydrogen.Receipt, data: any)
	data.coins += 100
end)
```

For another data library, write the same adapter yourself. This is what `fromData` does:

```luau
-- In your data system's module, after creating PlayerData with Hydrogen.Data.player(...)
local function receiptStore(PlayerData: any): Hydrogen.ReceiptStore
	return {
		load = function(_self: any, player: Player): boolean
			return PlayerData:waitForLoad(player) -- false if loading failed or they left
		end,
		isGranted = function(_self: any, _player: Player, _receipt: Hydrogen.Receipt): boolean
			return false -- updateOnce dedupes
		end,
		record = function(_self: any, player: Player, receipt: Hydrogen.Receipt, grant: (...any) -> ())
			local result = PlayerData:updateOnce(player, receipt.PurchaseId, function(data)
				grant(data) -- the handler gets `data` as its third argument
			end)
			if result == "failed" or result == "aborted" then
				error(`[HYDROGEN] updateOnce {result}`)
			end -- "applied" and "duplicate": return normally
		end,
		save = function(_self: any, player: Player, _receipt: Hydrogen.Receipt)
			local ok, err = PlayerData:save(player) -- must really save: Receipts retries through it
			if not ok then
				error(err)
			end
		end,
	}
end
```

### Standalone store (no data integration)
```luau
Hydrogen.Receipts.configure({ store = Hydrogen.Receipts.dataStore("ShopPurchases") })
```
One DataStore key per purchase id, written after the handler returns, tagged with the UserId (for erasure requests). Players who never buy cost no requests. It can't share a save with your data: a crash between your save and this one can grant twice or lose a grant. Prefer a data-backed store.

### Purchase history / analytics
```luau
Receipts.onGranted(function(player: Player, receipt: Hydrogen.Receipt)
	print(`{player.Name} bought {receipt.ProductId} for {receipt.CurrencySpent} Robux`)
end)
```

### VIP perks from a game pass
```luau
Receipts.gamePass(VIP_PASS, function(player: Player, _passId: number)
	player:SetAttribute("VIP", true) -- runs on join if owned, or right after an in-game purchase
end)
```

## Mistakes

- Don't set `MarketplaceService.ProcessReceipt = ...` yourself, anywhere. Do register `Receipts.product(id, handler)`; Receipts owns the callback and a second setter silently replaces it.
- Don't grant in a handler and also record the purchase id yourself in a separate DataStore. Do let the store record it: with a data-backed store the id and the grant land in one save.
- Don't save in the handler or return `PurchaseGranted` yourself. Do just change the data and return; Receipts answers `PurchaseGranted` only after the store reports the save durable.
- Don't return `false` from a handler to mean "error". `false` silently declines; `error(...)` declines with a warning. Return nothing to grant.
- Don't grant with `PlayerData:update` inside a handler when the store passes `data`. Do change the `data` argument (nested updates join it, but the argument is the clear path).
- Don't call `Receipts.configure` in a system's `start` or later. Do call it in the main script or an `init`; it errors once Receipts has started.
- Don't forget `app:addSystem(Hydrogen.Receipts)`. `use` alone binds nothing.
- Don't add Receipts before the data system in the app. Do add it after, so its `playerRemoving` (which waits for grants in progress) runs before the data is saved.
- Don't register the same product in two systems. Do keep one owner per product id; use `products` for a table.
- Don't treat `Receipts.owns` as free on first call. It yields; call it from a thread that can wait, or prefetch with a `gamePass` handler.
- Don't make a store's `save` a no-op when `record` wraps a call that can commit and then fail to save. Do save for real and error on failure.

## Testing

Use `Receipts.fakeMarketplace()` and `Receipts.memoryStore()`. They work under Lune and in Studio, with `Hydrogen.loopback()` players or fake players.

```luau
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)
local Shop = require(ServerScriptService.Systems.Shop)

local COINS_100 = 1234567
local VIP_PASS = 7654321

local market = Hydrogen.Receipts.fakeMarketplace()
local store = Hydrogen.Receipts.memoryStore()
Hydrogen.Receipts.configure({ marketplace = market, store = store, loadTimeout = 1 })

local net = Hydrogen.loopback()
local alice = net:join("Alice")
local app = Hydrogen.App.new()
app:addSystems({ Shop, Hydrogen.Receipts })
app:start()

local decision, receipt = market:purchase(alice, COINS_100)
assert(decision == "PurchaseGranted" and store:isSaved(receipt.PurchaseId))
assert(market:deliver(receipt) == "PurchaseGranted") -- duplicate: answered, not granted again

store:failSaves(10)                                    -- outage: every save fails
market:purchase(alice, COINS_100)                      -- "NotProcessedYet", stays pending
store:failSaves(0)
market:retryPending(alice)                             -- what Roblox does on rejoin: now granted

market:setOwnsGamePass(alice, VIP_PASS, true)          -- owned before joining
market:buyGamePass(alice, VIP_PASS)                    -- in-game purchase: fires the finished event

app:stop()
net:close()
```

`FakeMarketplace` (all methods `:`):
- `purchase(player: Player, productId: number, fields: { [string]: any }?): (PurchaseDecision, Receipt)`: builds a receipt (`PurchaseId` `"fake-purchase-N"`), calls `ProcessReceipt`. `fields` overrides receipt fields, e.g. `{ PurchaseId = "same" }`. Yields while Receipts yields.
- `deliver(receipt: Receipt): PurchaseDecision`: calls `ProcessReceipt` with that receipt again.
- `pending(player: Player?): { Receipt }`, `retryPending(player: Player?): { PurchaseDecision }`: receipts not yet granted, and re-delivering them.
- `setOwnsGamePass(player: Player, passId: number, owns: boolean)`, `buyGamePass(player: Player, passId: number)`.
- `failOwnershipChecks(count: number)`; fields `ownershipChecks: number` and `prompts: { { player: Player, kind: "product" | "gamePass", id: number } }`.

`MemoryReceiptStore`: `failSaves(count)`, `isSaved(purchaseId): boolean`, `savedCount(): number`. Records survive as long as the store table, so a new app with the same store acts like the next server.

Other tips:
- Purchases yield while a receipt waits; use `task.spawn` around `market:purchase` to test concurrency or a player leaving mid-grant.
- Under Lune the default `loadTimeout` is 30 s: set it low in tests where a player never loads.
- To fake Receipts entirely in another system's test: `app:replace(Hydrogen.Receipts, fake)`.
- Retries wait 1 s and 2 s through `src/Receipts/Clock.luau` (`Clock.wait`); the harness's fake clock replaces it.

## Errors and warnings

Thrown at registration or configuration:
- `[HYDROGEN] Developer product <id> already has a handler`: two registrations for one id. Remove one, or unregister first.
- `[HYDROGEN] Expected a developer product id (number), got <type>` / `Expected a game pass id (number), got <type>` / `Expected a handler function, got <type>`: wrong argument types.
- `[HYDROGEN] Receipts.configure must be called before Hydrogen.Receipts starts`: move `configure` to the main script or an `init`.
- `[HYDROGEN] Receipts.configure: store is missing <method>`: a store must have `isGranted`, `record` and `save`.
- `[HYDROGEN] Receipts.configure: loadTimeout must be a number of seconds`.
- `[HYDROGEN] fakeMarketplace: ProcessReceipt isn't set; add Hydrogen.Receipts to an app and start it`: the fake was used before an app with Receipts started.

Warnings while running (the answer is `NotProcessedYet` unless stated):
- `Receipts has no handler for developer product <id> (purchase ... by ...)`: register a handler for that id; the pending purchase is granted on the next try.
- `Receipt handler for developer product <id> failed (...): <error and traceback>`: fix the handler; nothing was recorded.
- `Receipts couldn't check whether purchase <id> was granted`: `store:isGranted` errored (e.g. DataStore outage).
- `Receipts store failed before granting purchase <id>`: `store:record` errored before calling `grant` (data not loaded, released).
- `Receipts granted purchase <id> but its save failed; retrying`: followed by success (answer `PurchaseGranted`) or by the next warning.
- `Receipts couldn't save purchase <id> for <player>; returning NotProcessedYet. It stays recorded, so a retry only saves it`: saves keep failing; the next delivery only saves.
- `Receipts couldn't save purchase <id> for <player> before they left`: the default DataStore store's last write failed; the purchase may be granted again in the next server.
- `Receipts failed processing purchase <id>`: an internal or store error escaped; report it.
- `Receipts store failed to load <player>; their purchases wait for another server`: `store:load` errored.
- `Receipts store failed to release <player>`: `store:release` errored (answers already given).
- `Receipts gave up waiting for a grant in progress for <player>`: a handler or save took over 15 s while the player left.
- `Receipts stopped with <n> receipts still processing`: shutdown waited 15 s; those receipts finish or Roblox re-offers them.
- `Receipts onGranted callback failed`: your analytics callback errored; the purchase was still granted.
- `Receipts couldn't check game pass <id> for user <id>`: three `UserOwnsGamePassAsync` attempts failed; `owns` returned `false` (not cached).
- `Game pass handler for pass <id> failed for <player>`: fix the handler; it won't run again for that player this session.

## Works with

- **Hydrogen.Data**: `Hydrogen.Receipts.fromData(PlayerData)` gives exactly-once grants, built on `PlayerData:waitForLoad`, `PlayerData:updateOnce` and `PlayerData:save`. Add the Data store to the app too.
- **Hydrogen.PlayerState**: change replicated player state inside the handler; field assignments inside an `updateOnce` fn join the same commit.
- **Test harness**: Receipts' retries and load timeouts run on `Hydrogen.Clock`, so `t:advance` drives them; use `fakeMarketplace` and `memoryStore` with `Hydrogen.test`.
- **Core:** a normal Hydrogen system; `app:replace(Hydrogen.Receipts, fake)` works like any other.
