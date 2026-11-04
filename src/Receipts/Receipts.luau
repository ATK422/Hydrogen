--!strict

-- Routes MarketplaceService.ProcessReceipt to per-product handlers and grants each purchase
-- once: it answers PurchaseGranted only after the store says the grant is saved, and
-- NotProcessedYet whenever it can't be sure, so Roblox offers the receipt again later.

local RunService = game:GetService("RunService")

local Definition = require("../Definition")
local Clock = require("./Clock")
local Log = require("./Log")
local Types = require("./Types")
local Stores = require("./Stores")
local FakeMarketplace = require("./FakeMarketplace")

type Receipt = Types.Receipt
type Decision = Types.Decision
type ProductHandler = Types.ProductHandler
type GamePassHandler = Types.GamePassHandler
type ReceiptStore = Types.ReceiptStore
type Marketplace = Types.Marketplace
type Connection = Types.Connection
type ReceiptsOptions = Types.ReceiptsOptions

local GRANTED: Decision = "PurchaseGranted"
local NOT_PROCESSED: Decision = "NotProcessedYet"

-- Waits between attempts to save a grant whose save failed: three tries in all.
local SAVE_RETRY_DELAYS = { 1, 2 }
-- Waits between attempts to check game pass ownership.
local OWNERSHIP_RETRY_DELAYS = { 1, 2 }
-- Longest a leaving player, or shutdown, waits for a grant in progress.
local DRAIN_TIMEOUT = 15
local DEFAULT_LOAD_TIMEOUT = 30

type PassRegistration = {
	passId: number,
	handler: GamePassHandler,
}

type Entry = {
	player: Player,
	-- The store loaded the player's purchase record.
	ready: boolean,
	-- Loading failed; their receipts wait for another server.
	failed: boolean,
	left: boolean,
	-- One receipt at a time per player: the holder sets busy, the rest wait in queue.
	busy: boolean,
	queue: { thread },
	-- Waiting for busy to clear (the player leaving).
	idle: { thread },
	-- Purchases granted and saved in this session.
	granted: { [string]: true },
	-- Game pass ownership known this session, checks in progress, and handlers already run.
	passes: { [number]: boolean },
	checking: { [number]: { thread } },
	applied: { [PassRegistration]: true },
}

local products: { [number]: ProductHandler } = {}
local passRegistrations: { PassRegistration } = {}
local grantedListeners: { (Player, Receipt) -> () } = {}
local options = {
	store = nil :: ReceiptStore?,
	marketplace = nil :: Marketplace?,
	loadTimeout = DEFAULT_LOAD_TIMEOUT,
}

-- Runtime state, from start to stop.
local running = false
local stopping = false
local marketplace: Marketplace? = nil
local store: ReceiptStore = nil :: any
local connection: Connection? = nil
-- By UserId, since receipts name players by id.
local entries: { [number]: Entry } = {}
-- Receipts waiting for a player to join or finish loading.
local arrivals: { [number]: { thread } } = {}
-- Purchase id -> calls for the same purchase waiting on the first.
local inFlight: { [string]: { thread } } = {}
local processing = 0
local drained: { thread } = {}
local warned: { [string]: true } = {}

-- Parks the running thread in list until wake (returning its value) or the timeout (nil).
local function park(list: { thread }, timeout: number?): any
	local thread = coroutine.running()
	table.insert(list, thread)

	local timer: thread? = nil
	if timeout then
		timer = Clock.delay(timeout, function()
			timer = nil
			local index = table.find(list, thread)
			if index then
				table.remove(list, index)
				task.spawn(thread)
			end
		end)
	end

	local value = coroutine.yield()
	if timer then
		Clock.cancel(timer)
	end
	return value
end

local function wake(list: { thread }, value: any?)
	local threads = table.clone(list)
	table.clear(list)
	for _, thread in threads do
		task.spawn(thread, value)
	end
end

local function notify(userId: number)
	local list = arrivals[userId]
	if list then
		arrivals[userId] = nil
		wake(list)
	end
end

local function describe(entry: Entry): string
	return `{entry.player.Name} ({entry.player.UserId})`
end

local function currentMarketplace(): Marketplace
	return marketplace or options.marketplace or (game:GetService("MarketplaceService") :: any)
end

-- The player's entry once their purchase record is loaded; nil if they leave, loading fails,
-- the server shuts down, or loadTimeout passes first.
local function awaitPlayer(userId: number): Entry?
	local deadline = Clock.clock() + options.loadTimeout
	while running and not stopping do
		local entry = entries[userId]
		if entry then
			if entry.left or entry.failed then
				return nil
			elseif entry.ready then
				return entry
			end
		end

		local remaining = deadline - Clock.clock()
		if remaining <= 0 then
			return nil
		end
		local list = arrivals[userId]
		if not list then
			list = {}
			arrivals[userId] = list
		end
		park(list, remaining)
		if #list == 0 and arrivals[userId] == list then
			arrivals[userId] = nil
		end
	end
	return nil
end

local function acquire(entry: Entry): boolean
	while entry.busy and not entry.left do
		park(entry.queue)
	end
	if entry.left then
		return false
	end
	entry.busy = true
	return true
end

local function release(entry: Entry)
	entry.busy = false
	local nextThread = table.remove(entry.queue, 1)
	if nextThread then
		task.spawn(nextThread)
	end
	if not entry.busy then
		wake(entry.idle)
	end
end

local function finish(entry: Entry, receipt: Receipt, announce: boolean)
	entry.granted[receipt.PurchaseId] = true
	if not announce then
		return
	end
	for _, listener in table.clone(grantedListeners) do
		task.spawn(function()
			local ok, err = xpcall(listener, debug.traceback, entry.player, receipt)
			if not ok then
				Log.warn(`[HYDROGEN] Receipts onGranted callback failed: {err}`)
			end
		end)
	end
end

-- Saves an already recorded purchase, retrying a few times before leaving it for later.
local function confirm(entry: Entry, receipt: Receipt, announce: boolean): Decision
	local ok, err = pcall(store.save, store, entry.player, receipt)
	for _, delay in SAVE_RETRY_DELAYS do
		if ok then
			break
		end
		Clock.wait(delay)
		ok, err = pcall(store.save, store, entry.player, receipt)
	end

	if not ok then
		Log.warn(
			`[HYDROGEN] Receipts couldn't save purchase {receipt.PurchaseId} for {describe(entry)}; returning NotProcessedYet. It stays recorded, so a retry only saves it: {err}`
		)
		return NOT_PROCESSED
	end
	finish(entry, receipt, announce)
	return GRANTED
end

local function grantOnce(entry: Entry, receipt: Receipt): Decision
	local player = entry.player
	local purchaseId = receipt.PurchaseId

	local checked, alreadyGranted = pcall(store.isGranted, store, player, receipt)
	if not checked then
		Log.warn(`[HYDROGEN] Receipts couldn't check whether purchase {purchaseId} was granted; returning NotProcessedYet: {alreadyGranted}`)
		return NOT_PROCESSED
	end
	if alreadyGranted then
		-- Granted before, here or in another server; make sure that grant is saved.
		return confirm(entry, receipt, false)
	end

	local handler = products[receipt.ProductId]
	if not handler then
		if not warned[purchaseId] then
			warned[purchaseId] = true
			Log.warn(
				`[HYDROGEN] Receipts has no handler for developer product {receipt.ProductId} (purchase {purchaseId} by {describe(entry)}); returning NotProcessedYet so it can be granted once one exists`
			)
		end
		return NOT_PROCESSED
	end

	if entry.left then
		return NOT_PROCESSED
	end

	local ran = false
	local declined = false
	local handlerError: string? = nil
	local function grant(...: any)
		local ok, result = xpcall(handler, debug.traceback, player, receipt, ...)
		if not ok then
			handlerError = tostring(result)
			error(result, 0)
		elseif result == false then
			declined = true
			error("[HYDROGEN] Receipt handler declined the purchase", 0)
		end
		ran = true
	end

	local recorded, err = pcall(store.record, store, player, receipt, grant)
	if recorded then
		-- A store that dedupes inside record (instead of in isGranted) skips grant for a
		-- purchase it already holds durably.
		finish(entry, receipt, ran)
		return GRANTED
	elseif declined then
		return NOT_PROCESSED
	elseif handlerError then
		Log.warn(`[HYDROGEN] Receipt handler for developer product {receipt.ProductId} failed (purchase {purchaseId} by {describe(entry)}); returning NotProcessedYet: {handlerError}`)
		return NOT_PROCESSED
	elseif not ran then
		Log.warn(`[HYDROGEN] Receipts store failed before granting purchase {purchaseId}; returning NotProcessedYet: {err}`)
		return NOT_PROCESSED
	end

	-- The grant happened but its save failed. The store still has it recorded, so retrying
	-- the save (here, or when Roblox offers the receipt again) can't grant twice.
	Log.warn(`[HYDROGEN] Receipts granted purchase {purchaseId} but its save failed; retrying: {err}`)
	return confirm(entry, receipt, true)
end

local function decide(receipt: Receipt): Decision
	local entry = awaitPlayer(receipt.PlayerId)
	if not entry then
		return NOT_PROCESSED
	end
	if entry.granted[receipt.PurchaseId] then
		return GRANTED
	end
	if not acquire(entry) then
		return NOT_PROCESSED
	end

	local ok, decision = xpcall(grantOnce, debug.traceback, entry, receipt)
	release(entry)
	if not ok then
		Log.warn(`[HYDROGEN] Receipts failed processing purchase {receipt.PurchaseId}; returning NotProcessedYet: {decision}`)
		return NOT_PROCESSED
	end
	return decision
end

local function process(receipt: Receipt): Decision
	if not running or stopping then
		return NOT_PROCESSED
	end

	-- Roblox can offer the same receipt again while the first call still yields.
	local purchaseId = receipt.PurchaseId
	local waiting = inFlight[purchaseId]
	if waiting then
		return park(waiting) or NOT_PROCESSED
	end

	waiting = {}
	inFlight[purchaseId] = waiting
	processing += 1

	local ok, decision = xpcall(decide, debug.traceback, receipt)
	if not ok then
		Log.warn(`[HYDROGEN] Receipts failed processing purchase {purchaseId}; returning NotProcessedYet: {decision}`)
		decision = NOT_PROCESSED
	end

	processing -= 1
	inFlight[purchaseId] = nil
	wake(waiting, decision)
	if processing == 0 then
		wake(drained)
	end
	return decision
end

-- nil when every attempt errors.
local function queryOwnership(userId: number, passId: number): boolean?
	local market = currentMarketplace()
	local ok, result = pcall(market.UserOwnsGamePassAsync, market, userId, passId)
	for _, delay in OWNERSHIP_RETRY_DELAYS do
		if ok then
			break
		end
		Clock.wait(delay)
		ok, result = pcall(market.UserOwnsGamePassAsync, market, userId, passId)
	end
	if not ok then
		Log.warn(`[HYDROGEN] Receipts couldn't check game pass {passId} for user {userId}: {result}`)
		return nil
	end
	return result == true
end

local function entryFor(player: Player): Entry?
	local entry = entries[player.UserId]
	if entry and entry.player == player and not entry.left then
		return entry
	end
	return nil
end

local function owns(player: Player, passId: number): boolean
	local entry = entryFor(player)
	if not entry then
		return queryOwnership(player.UserId, passId) == true
	end

	local known = entry.passes[passId]
	if known ~= nil then
		return known
	end

	local waiting = entry.checking[passId]
	if waiting then
		return park(waiting) == true
	end

	waiting = {}
	entry.checking[passId] = waiting
	local result = queryOwnership(player.UserId, passId)
	entry.checking[passId] = nil

	-- A purchase may have landed while the check yielded.
	if entry.passes[passId] == nil and result ~= nil and not entry.left then
		entry.passes[passId] = result
	end
	local owned = entry.passes[passId] == true or result == true
	wake(waiting, owned)
	return owned
end

local function apply(entry: Entry, registration: PassRegistration)
	if entry.left or entry.applied[registration] then
		return
	end
	entry.applied[registration] = true
	local ok, err = xpcall(registration.handler, debug.traceback, entry.player, registration.passId)
	if not ok then
		Log.warn(`[HYDROGEN] Game pass handler for pass {registration.passId} failed for {describe(entry)}: {err}`)
	end
end

local function checkPasses(entry: Entry, registrations: { PassRegistration })
	for _, registration in registrations do
		if entry.left then
			return
		end
		if owns(entry.player, registration.passId) then
			apply(entry, registration)
		end
	end
end

local function onGamePassPurchased(player: Player, passId: number, wasPurchased: boolean)
	if not wasPurchased then
		return
	end
	local entry = entryFor(player)
	if not entry then
		return
	end
	entry.passes[passId] = true
	for _, registration in table.clone(passRegistrations) do
		if registration.passId == passId then
			apply(entry, registration)
		end
	end
end

local function checkProductId(productId: any, level: number)
	if type(productId) ~= "number" then
		error(`[HYDROGEN] Expected a developer product id (number), got {typeof(productId)}`, level + 1)
	end
end

local function checkHandler(handler: any, level: number)
	if type(handler) ~= "function" then
		error(`[HYDROGEN] Expected a handler function, got {typeof(handler)}`, level + 1)
	end
end

local Receipts = {}

-- Sets where purchases are recorded, the marketplace (a fake in tests) and loadTimeout.
-- Call it before Receipts starts: from your main script or a system's init.
function Receipts.configure(newOptions: ReceiptsOptions)
	if running then
		error(`[HYDROGEN] Receipts.configure must be called before Hydrogen.Receipts starts`, 2)
	end
	local newStore = newOptions.store
	if newStore ~= nil then
		for _, method in { "isGranted", "record", "save" } do
			if type((newStore :: any)[method]) ~= "function" then
				error(`[HYDROGEN] Receipts.configure: store is missing {method}`, 2)
			end
		end
	end
	if newOptions.loadTimeout ~= nil and (type(newOptions.loadTimeout) ~= "number" or newOptions.loadTimeout < 0) then
		error(`[HYDROGEN] Receipts.configure: loadTimeout must be a number of seconds`, 2)
	end

	options.store = newStore
	options.marketplace = newOptions.marketplace
	options.loadTimeout = newOptions.loadTimeout or DEFAULT_LOAD_TIMEOUT
end

-- Grants a developer product. Each product has one handler; returns a function that removes it.
function Receipts.product(productId: number, handler: ProductHandler): () -> ()
	checkProductId(productId, 2)
	checkHandler(handler, 2)
	if products[productId] then
		error(`[HYDROGEN] Developer product {productId} already has a handler`, 2)
	end

	products[productId] = handler
	return function()
		if products[productId] == handler then
			products[productId] = nil
		end
	end
end

-- Several products at once: { [productId] = handler }. Returns a function that removes them all.
function Receipts.products(handlers: { [number]: ProductHandler }): () -> ()
	for productId, handler in handlers do
		checkProductId(productId, 2)
		checkHandler(handler, 2)
		if products[productId] then
			error(`[HYDROGEN] Developer product {productId} already has a handler`, 2)
		end
	end

	local removers = {}
	for productId, handler in handlers do
		table.insert(removers, Receipts.product(productId, handler))
	end
	return function()
		for _, remove in removers do
			remove()
		end
	end
end

-- Runs handler once per session for each player who owns the pass: when they join, or when
-- they buy it in game. A pass can have several handlers. Returns a function that removes it.
function Receipts.gamePass(passId: number, handler: GamePassHandler): () -> ()
	if type(passId) ~= "number" then
		error(`[HYDROGEN] Expected a game pass id (number), got {typeof(passId)}`, 2)
	end
	checkHandler(handler, 2)

	local registration: PassRegistration = { passId = passId, handler = handler }
	table.insert(passRegistrations, registration)

	-- Registered after players joined: check the players already here.
	for _, entry in entries do
		if not entry.left then
			task.spawn(checkPasses, entry, { registration })
		end
	end

	return function()
		local index = table.find(passRegistrations, registration)
		if index then
			table.remove(passRegistrations, index)
		end
	end
end

-- Several passes at once: { [passId] = handler }. Returns a function that removes them all.
function Receipts.gamePasses(handlers: { [number]: GamePassHandler }): () -> ()
	local removers = {}
	for passId, handler in handlers do
		table.insert(removers, Receipts.gamePass(passId, handler))
	end
	return function()
		for _, remove in removers do
			remove()
		end
	end
end

-- Whether the player owns the game pass. The first check per player and pass yields; after
-- that it's cached for the session, and an in-game purchase updates it. Returns false when
-- Roblox can't be reached (not cached, so the next call asks again).
function Receipts.owns(player: Player, passId: number): boolean
	return owns(player, passId)
end

function Receipts.promptProduct(player: Player, productId: number)
	local market = currentMarketplace()
	market:PromptProductPurchase(player, productId)
end

function Receipts.promptGamePass(player: Player, passId: number)
	local market = currentMarketplace()
	market:PromptGamePassPurchase(player, passId)
end

-- Called after each purchase this server grants and saves, for purchase history or analytics.
-- Runs in its own thread; errors are warned. Returns a function that disconnects it.
function Receipts.onGranted(callback: (player: Player, receipt: Receipt) -> ()): () -> ()
	checkHandler(callback, 2)
	table.insert(grantedListeners, callback)
	return function()
		local index = table.find(grantedListeners, callback)
		if index then
			table.remove(grantedListeners, index)
		end
	end
end

-- The default store: one DataStore key per purchase. Pass a name, or a DataStore-like object in tests.
Receipts.dataStore = Stores.dataStore
-- Records in memory, with failSaves to simulate outages. For tests.
Receipts.memoryStore = Stores.memoryStore
-- A stand-in MarketplaceService for tests; see FakeMarketplace.
Receipts.fakeMarketplace = FakeMarketplace.new

function Receipts:start()
	local market = options.marketplace
	if not market then
		-- ProcessReceipt only exists on the server; elsewhere (the client, headless tests
		-- without a fake) there is nothing to bind.
		if not RunService:IsServer() then
			return
		end
		market = game:GetService("MarketplaceService") :: any
	end

	marketplace = market
	store = options.store or Stores.dataStore()
	running = true
	stopping = false

	local real = typeof(market) == "Instance"
	local bound = market :: Marketplace
	bound.ProcessReceipt = function(receipt: Receipt): any
		local decision = process(receipt)
		if real then
			return (Enum.ProductPurchaseDecision :: any)[decision]
		end
		return decision
	end
	connection = bound.PromptGamePassPurchaseFinished:Connect(onGamePassPurchased)
end

function Receipts:playerAdded(player: Player)
	if not running then
		return
	end

	local entry: Entry = {
		player = player,
		ready = false,
		failed = false,
		left = false,
		busy = false,
		queue = {},
		idle = {},
		granted = {},
		passes = {},
		checking = {},
		applied = {},
	}
	entries[player.UserId] = entry

	-- Loading may wait on other systems' playerAdded hooks (a Data profile), so it can't
	-- block this one.
	local loading = store
	task.spawn(function()
		local loaded = true
		if loading.load then
			local ok, result = pcall(loading.load, loading, player)
			if not ok then
				Log.warn(`[HYDROGEN] Receipts store failed to load {describe(entry)}; their purchases wait for another server: {result}`)
				loaded = false
			else
				loaded = result ~= false
			end
		end
		if entry.left then
			return
		end
		entry.ready = loaded
		entry.failed = not loaded
		notify(player.UserId)
	end)

	if #passRegistrations > 0 then
		task.spawn(checkPasses, entry, table.clone(passRegistrations))
	end
end

-- Lets a grant in progress finish first, so systems that save after this one see it.
function Receipts:playerRemoving(player: Player)
	local entry = entries[player.UserId]
	if not entry or entry.player ~= player then
		return
	end

	entry.left = true
	notify(player.UserId)
	wake(entry.queue)
	for _, waiting in entry.checking do
		wake(waiting, false)
	end

	local deadline = Clock.clock() + DRAIN_TIMEOUT
	while entry.busy do
		local remaining = deadline - Clock.clock()
		if remaining <= 0 then
			Log.warn(`[HYDROGEN] Receipts gave up waiting for a grant in progress for {describe(entry)}`)
			break
		end
		park(entry.idle, remaining)
	end

	if store.release then
		local ok, err = pcall(store.release, store, player)
		if not ok then
			Log.warn(`[HYDROGEN] Receipts store failed to release {describe(entry)}: {err}`)
		end
	end
	if entries[player.UserId] == entry then
		entries[player.UserId] = nil
	end
end

-- New receipts answer NotProcessedYet from here on, so another server grants them.
function Receipts:stop()
	if not running then
		return
	end
	stopping = true
	for userId in arrivals do
		notify(userId)
	end

	local deadline = Clock.clock() + DRAIN_TIMEOUT
	while processing > 0 do
		local remaining = deadline - Clock.clock()
		if remaining <= 0 then
			Log.warn(`[HYDROGEN] Receipts stopped with {processing} receipts still processing`)
			break
		end
		park(drained, remaining)
	end

	if connection then
		connection:Disconnect()
		connection = nil
	end
	-- ProcessReceipt stays bound and answers NotProcessedYet while not running.
	running = false
	stopping = false
	marketplace = nil
	entries = {}
	arrivals = {}
	inFlight = {}
	warned = {}
end

return Definition.define("Hydrogen.Receipts", function()
	return Receipts
end)
