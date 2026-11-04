--!strict

-- Where state lives and how it replicates. Each state keeps a cell per context: the server's
-- cell, and on clients a replica. Under Hydrogen.loopback one VM is the server and every fake
-- client, so each fake client gets its own replica, keyed by its player.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Runtime = require("../Network/Runtime")
local Schedule = require("./Schedule")

export type Cell = {
	-- The value, map table or list table.
	data: any,
	-- Written on the server since it was created, so a joining player needs a snapshot of it.
	touched: boolean,
	-- Waiting for the next flush.
	dirty: boolean,
	-- Per-player cells: whose cell it is, as sent on the wire.
	userId: number?,
	-- Maps: keys changed since the last flush.
	keys: { [any]: boolean }?,
	-- Lists: (op, index) pairs since the last flush, and the values of the ops that carry one.
	ops: { number }?,
	opValues: { any }?,
	-- The pending changes are sent as a full snapshot instead (cleared, replaced, or many list ops).
	reset: boolean,
	observers: { (...any) -> () }?,
	keyObservers: { [any]: { (...any) -> () } }?,
	listeners: { (...any) -> () }?,
}

-- Something computed state can depend on: a state, or another computed state.
export type Source = {
	watchers: { [(ctx: any) -> ()]: boolean },
}

-- How a kind of state (value, map, list) goes over the wire.
export type Kind = {
	initial: (state: Def) -> any,
	-- The payload for a player who has nothing yet.
	snapshot: (state: Def, cell: Cell) -> ...any,
	-- The payload for the changes since the last flush. Clears them.
	diff: (state: Def, cell: Cell) -> ...any,
	clearPending: (cell: Cell) -> (),
	-- Client: applies a payload to a replica and tells observers.
	apply: (state: Def, ctx: any, cell: Cell, ...any) -> (),
}

export type Def = Source & {
	name: string,
	kind: Kind,
	perPlayer: boolean,
	-- Every player sees it. Always true for global state.
	public: boolean,
	initial: any,
	event: any,
	-- The handler registered on the event, so it can be put back after a loopback removes it.
	receive: (...any) -> (),
	wire: (value: any) -> any,
	unwire: (value: any) -> any,
	-- Context -> cell, for global state.
	global: { [any]: Cell },
	-- Context -> owner -> cell, for per-player state. The server keys by Player, weakly, so a
	-- player's state stays readable in later playerRemoving hooks and is freed with the player.
	-- Replicas key by UserId, which is what the wire carries.
	players: { [any]: { [any]: Cell } },
}

type Pending = {
	state: Def,
	cell: Cell,
	player: Player?,
}

local Store = {}

-- The server's context.
Store.SERVER = table.freeze({ context = "server" })
-- A real client's only replica.
Store.LOCAL = table.freeze({ context = "client" })

Store.states = {} :: { Def }
Store.byName = {} :: { [string]: Def }
-- Computed states, so reset can drop their observers.
Store.computeds = {} :: { { reset: (self: any) -> () } }
-- Tells clients a player left, so they drop that player's replicated state.
Store.leftEvent = nil :: any

local SERVER = Store.SERVER
local LOCAL = Store.LOCAL

-- Read once: the side a VM is on never changes.
local side: "server" | "client" | "none" | nil = nil

local function realSide(): "server" | "client" | "none"
	if not side then
		side = if RunService:IsServer() then "server" elseif RunService:IsClient() then "client" else "none"
	end
	return side :: any
end

--------------------------------------------------------------------------------
-- Context: whose copy of the state the running code reads.
--------------------------------------------------------------------------------

local override: any = nil

-- The server, a real client's replica, or under loopback the replica of the client the running
-- code acts as (inside net:as, or while a server message is delivered to it).
function Store.context(): any
	if override ~= nil then
		return override
	end

	local loopback = Runtime.Loopback
	if loopback then
		Store.ensure()
		return loopback:client() or SERVER
	end

	return if realSide() == "client" then LOCAL else SERVER
end

-- Runs fn with reads pointed at ctx, so observers see the copy that changed.
function Store.within(ctx: any, fn: (...any) -> (), ...: any)
	local previous = override
	override = ctx
	local ok, err = pcall(fn, ...)
	override = previous
	if not ok then
		error(err, 0)
	end
end

function Store.assertWritable(state: Def, level: number)
	if Runtime.Loopback == nil and realSide() == "client" then
		error(`[HYDROGEN] State {state.name} can only be changed on the server`, level + 1)
	end
end

--------------------------------------------------------------------------------
-- Cells
--------------------------------------------------------------------------------

local function newCell(state: Def, userId: number?): Cell
	return {
		data = state.kind.initial(state),
		touched = false,
		dirty = false,
		userId = userId,
		reset = false,
	}
end

-- The cell for a context and an owner key (Player on the server, UserId on clients).
function Store.cellAt(state: Def, ctx: any, key: any, create: boolean): Cell?
	if not state.perPlayer then
		local cell = state.global[ctx]
		if not cell and create then
			cell = newCell(state, nil)
			state.global[ctx] = cell
		end
		return cell
	end

	local cells = state.players[ctx]
	if not cells then
		if not create then
			return nil
		end
		cells = if ctx == SERVER then setmetatable({}, { __mode = "k" }) :: any else {}
		state.players[ctx] = cells
	end

	local cell = (cells :: any)[key]
	if not cell and create then
		cell = newCell(state, if ctx == SERVER then key.UserId else key)
		;(cells :: any)[key] = cell
	end
	return cell
end

function Store.cell(state: Def, ctx: any, player: Player?, create: boolean): Cell?
	if not state.perPlayer then
		return Store.cellAt(state, ctx, nil, create)
	end
	local key = if ctx == SERVER then player else (player :: Player).UserId
	return Store.cellAt(state, ctx, key, create)
end

--------------------------------------------------------------------------------
-- Dependency tracking for computed state
--------------------------------------------------------------------------------

local collecting: { [Source]: boolean }? = nil

-- Called by every read, so computed state learns what it depends on.
function Store.read(source: Source)
	if collecting then
		collecting[source] = true
	end
end

-- Runs fn and returns the sources it read.
function Store.collect<T>(fn: () -> T): ({ [Source]: boolean }, T)
	local previous = collecting
	local deps = {}
	collecting = deps
	local ok, result = pcall(fn)
	collecting = previous
	if not ok then
		error(result, 0)
	end
	return deps, result
end

-- Tells computed state that depends on source that it changed in ctx.
function Store.changed(source: Source, ctx: any)
	if next(source.watchers) == nil then
		return
	end

	local watchers = {}
	for watcher in source.watchers do
		table.insert(watchers, watcher)
	end
	for _, watcher in watchers do
		watcher(ctx)
	end
end

--------------------------------------------------------------------------------
-- Calling observers
--------------------------------------------------------------------------------

-- Observers run on a reused thread, like a signal library: no new thread per call unless one
-- yields, and an error is reported without stopping the others or the write that caused it.
local freeThread: thread? = nil

local function runObserver(name: string, observer: (...any) -> (), ...: any)
	local acquired = freeThread
	freeThread = nil
	local ok, err = xpcall(observer, debug.traceback, ...)
	if not ok then
		warn(`[HYDROGEN] Observer of State {name} failed: {err}`)
	end
	freeThread = acquired
end

local function observerLoop()
	while true do
		runObserver(coroutine.yield())
	end
end

function Store.call(name: string, observer: (...any) -> (), ...: any)
	if not freeThread then
		local thread = coroutine.create(observerLoop)
		coroutine.resume(thread)
		freeThread = thread
	end
	task.spawn(freeThread :: thread, name, observer, ...)
end

-- Calls each observer in a list. Cloned so one that disconnects itself doesn't skip the next.
function Store.notify(name: string, observers: { (...any) -> () }?, ...: any)
	if not observers or #observers == 0 then
		return
	end
	for _, observer in table.clone(observers) do
		Store.call(name, observer, ...)
	end
end

-- Adds to a list and returns a function that removes it again.
function Store.add<T>(list: { T }, item: T): () -> ()
	table.insert(list, item)
	return function()
		local index = table.find(list, item)
		if index then
			table.remove(list, index)
		end
	end
end

--------------------------------------------------------------------------------
-- Replication (server)
--------------------------------------------------------------------------------

-- What player joins come from: the Players service, the open loopback, or nothing yet.
local attached: any = nil
local subscribed: { [Player]: boolean } = {}
local subscribers: { Player } = {}
-- Weak so players who left can be garbage collected.
local departed: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local pending: { Pending } = {}
local scheduled = false

local function send(state: Def, cell: Cell, targets: { Player }, ...: any)
	local ok, err = if state.perPlayer and state.public
		then pcall(state.event.Fire, state.event, targets, cell.userId, ...)
		else pcall(state.event.Fire, state.event, targets, ...)
	if not ok then
		warn(`[HYDROGEN] State {state.name} could not be sent: {err}`)
	end
end

local function gone(player: Player): boolean
	return departed[player] == true or Runtime:isDeparted(player)
end

-- A player starts receiving state: first everything already written that they may see, then changes.
local function subscribe(player: Player)
	if subscribed[player] or gone(player) then
		return
	end

	-- Pending changes are already in the snapshot, so they must not reach this player again.
	Store.flush()
	subscribed[player] = true
	table.insert(subscribers, player)

	local targets = { player }
	for _, state in Store.states do
		local kind = state.kind
		if not state.perPlayer then
			local cell = state.global[SERVER]
			if cell and cell.touched then
				send(state, cell, targets, kind.snapshot(state, cell))
			end
			continue
		end

		local cells = state.players[SERVER]
		if not cells then
			continue
		end

		if state.public then
			for owner, cell in cells do
				if cell.touched and not gone(owner) then
					send(state, cell, targets, kind.snapshot(state, cell))
				end
			end
		else
			local cell = cells[player]
			if cell and cell.touched then
				send(state, cell, targets, kind.snapshot(state, cell))
			end
		end
	end
end

local function unsubscribe(player: Player)
	departed[player] = true
	if subscribed[player] then
		subscribed[player] = nil
		local index = table.find(subscribers, player)
		if index then
			table.remove(subscribers, index)
		end
	end

	local leftEvent = Store.leftEvent
	if leftEvent and #subscribers > 0 then
		local ok, err = pcall(leftEvent.Fire, leftEvent, table.clone(subscribers), player.UserId)
		if not ok then
			warn(`[HYDROGEN] State could not tell clients that {player.Name} left: {err}`)
		end
	end
end

-- Forgets players and replicas, for a fresh network (a new loopback). Server values stay.
local function dropReplication()
	table.clear(subscribed)
	table.clear(subscribers)
	table.clear(departed)
	for _, entry in pending do
		entry.cell.dirty = false
		entry.state.kind.clearPending(entry.cell)
	end
	pending = {}

	for _, state in Store.states do
		for ctx in state.global do
			if ctx ~= SERVER then
				state.global[ctx] = nil
			end
		end
		for ctx in state.players do
			if ctx ~= SERVER then
				state.players[ctx] = nil
			end
		end
	end
end

-- A loopback removes listeners added after it opened when it closes; put State's back.
local function restoreListeners()
	for _, state in Store.states do
		local listeners = state.event._listeners
		if not table.find(listeners, state.receive) then
			table.insert(listeners, state.receive)
		end
	end
end

-- Starts following player joins and leaves the first time state is used on the server, so a game
-- that never uses State pays nothing. Returns whether this VM replicates state at all.
function Store.ensure(): boolean
	local loopback = Runtime.Loopback
	if loopback then
		if attached ~= loopback then
			dropReplication()
			attached = loopback
			restoreListeners()
			loopback:watch(subscribe, unsubscribe)
		end
		return true
	end

	if attached ~= nil and attached ~= Players then
		-- The loopback closed.
		dropReplication()
		attached = nil
	end

	if attached == nil and realSide() == "server" then
		attached = Players
		Players.PlayerAdded:Connect(subscribe)
		Players.PlayerRemoving:Connect(unsubscribe)
		for _, player in Players:GetPlayers() do
			task.spawn(subscribe, player)
		end
	end

	return attached ~= nil
end

-- The server cell a write goes to. Call before changing anything, so a player who subscribes
-- because of this call gets a snapshot without the change, and then the change.
function Store.writable(state: Def, player: Player?): Cell
	Store.ensure()
	return Store.cellAt(state, SERVER, player, true) :: Cell
end

local function scheduledFlush()
	scheduled = false
	Store.flush()
end

-- Records that a server cell changed. Returns whether the change will be sent, so the kind
-- knows to remember what changed.
function Store.written(state: Def, cell: Cell, player: Player?): boolean
	cell.touched = true
	if attached == nil or (player and departed[player]) then
		return false
	end

	if not cell.dirty then
		cell.dirty = true
		table.insert(pending, { state = state, cell = cell, player = player })
		if not scheduled then
			scheduled = true
			Schedule.nextFrame(scheduledFlush)
		end
	end
	return true
end

-- Sends every pending change now: one message per changed cell.
function Store.flush()
	if #pending == 0 then
		return
	end

	local list = pending
	pending = {}
	local everyone = table.clone(subscribers)

	for _, entry in list do
		local state, cell, player = entry.state, entry.cell, entry.player
		if not cell.dirty then
			continue
		end
		cell.dirty = false

		local targets: { Player }? = nil
		if player and departed[player] then
			targets = nil
		elseif state.perPlayer and not state.public then
			if subscribed[player :: Player] then
				targets = { player :: Player }
			end
		elseif #everyone > 0 then
			targets = everyone
		end

		if targets then
			send(state, cell, targets, state.kind.diff(state, cell))
		else
			state.kind.clearPending(cell)
		end
	end
end

--------------------------------------------------------------------------------
-- Replication (client)
--------------------------------------------------------------------------------

local function replicaKey(): any
	local loopback = Runtime.Loopback
	if loopback then
		return loopback:client()
	end
	return LOCAL
end

local function localUserId(ctx: any): number?
	if ctx == LOCAL then
		local player = Players.LocalPlayer
		return player and player.UserId
	end
	return ctx.UserId
end

function Store.receive(state: Def, ...: any)
	Store.ensure()
	local ctx = replicaKey()
	if ctx == nil then
		return
	end

	if not state.perPlayer then
		Store.within(ctx, state.kind.apply, state, ctx, Store.cellAt(state, ctx, nil, true), ...)
	elseif state.public then
		local userId = ...
		Store.within(ctx, state.kind.apply, state, ctx, Store.cellAt(state, ctx, userId, true), select(2, ...))
	else
		local userId = localUserId(ctx)
		if userId then
			Store.within(ctx, state.kind.apply, state, ctx, Store.cellAt(state, ctx, userId, true), ...)
		end
	end
end

-- A player left: drop what this client holds for them.
function Store.receiveLeft(userId: number)
	local ctx = replicaKey()
	if ctx == nil then
		return
	end
	for _, state in Store.states do
		local cells = state.players[ctx]
		if cells then
			cells[userId] = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Tests
--------------------------------------------------------------------------------

-- Every state back to its initial value, on the server and in every replica, with observers
-- and pending changes dropped. Players stay subscribed.
function Store.reset()
	for _, entry in pending do
		entry.cell.dirty = false
	end
	pending = {}
	for _, state in Store.states do
		table.clear(state.global)
		table.clear(state.players)
	end
	for _, computed in Store.computeds do
		computed:reset()
	end
end

return Store
