--!strict

-- A key -> value table. Changes are sent as key diffs: (reset, keys, values, removed).
-- Keys and values travel as parallel arrays, because remotes mangle tables with non-string keys.
-- With reset, keys/values are the whole map and replace what the client had.

local Store = require("./Store")

type Def = Store.Def
type Cell = Store.Cell

type Change = {
	key: any,
	value: any,
	previous: any,
}

local Map = {}

local function differs(new: any, old: any): boolean
	return new ~= old or type(new) == "table"
end

-- Key observers and change listeners per key, then whole-map observers once.
local function emit(state: Def, ctx: any, cell: Cell, changes: { Change })
	local keyObservers = cell.keyObservers
	for _, change in changes do
		if keyObservers then
			Store.notify(state.name, keyObservers[change.key], change.value)
		end
		Store.notify(state.name, cell.listeners, change.key, change.value, change.previous)
	end
	if cell.observers and #cell.observers > 0 then
		Store.notify(state.name, cell.observers, table.clone(cell.data))
	end
	Store.changed(state, ctx)
end

function Map.initial(_state: Def): any
	return {}
end

function Map.clearPending(cell: Cell)
	cell.keys = nil
	cell.reset = false
end

function Map.snapshot(state: Def, cell: Cell): ...any
	local keys, values = {}, {}
	for key, value in cell.data do
		table.insert(keys, key)
		table.insert(values, state.wire(value))
	end
	return true, keys, values, {}
end

function Map.diff(state: Def, cell: Cell): ...any
	if cell.reset or not cell.keys then
		Map.clearPending(cell)
		return Map.snapshot(state, cell)
	end

	local data = cell.data
	local keys, values, removed = {}, {}, {}
	for key in cell.keys :: { [any]: boolean } do
		local value = data[key]
		if value == nil then
			table.insert(removed, key)
		else
			table.insert(keys, key)
			table.insert(values, state.wire(value))
		end
	end
	Map.clearPending(cell)
	return false, keys, values, removed
end

function Map.apply(state: Def, ctx: any, cell: Cell, reset: boolean, keys: { any }, values: { any }, removed: { any })
	if #keys ~= #values then
		warn(`[HYDROGEN] State {state.name} received a map change with {#keys} keys and {#values} values; ignored`)
		return
	end

	local data = cell.data
	local changes: { Change } = {}

	if reset then
		local replacement = {}
		for index, key in keys do
			replacement[key] = state.unwire(values[index])
		end
		for key, previous in data do
			if replacement[key] == nil then
				table.insert(changes, { key = key, value = nil, previous = previous })
			end
		end
		for key, value in replacement do
			local previous = data[key]
			if differs(value, previous) then
				table.insert(changes, { key = key, value = value, previous = previous })
			end
		end
		cell.data = replacement
	else
		for index, key in keys do
			local value = state.unwire(values[index])
			local previous = data[key]
			data[key] = value
			if differs(value, previous) then
				table.insert(changes, { key = key, value = value, previous = previous })
			end
		end
		for _, key in removed do
			local previous = data[key]
			if previous ~= nil then
				data[key] = nil
				table.insert(changes, { key = key, value = nil, previous = previous })
			end
		end
	end

	if #changes > 0 then
		emit(state, ctx, cell, changes)
	end
end

local function readCell(state: Def, player: Player?): Cell?
	Store.read(state)
	return Store.cell(state, Store.context(), player, false)
end

function Map.get(state: Def, player: Player?, key: any): any
	local cell = readCell(state, player)
	return cell and cell.data[key]
end

function Map.all(state: Def, player: Player?): { [any]: any }
	local cell = readCell(state, player)
	return if cell then table.clone(cell.data) else {}
end

function Map.size(state: Def, player: Player?): number
	local cell = readCell(state, player)
	local count = 0
	if cell then
		for _ in cell.data do
			count += 1
		end
	end
	return count
end

-- The server's current entry, for update.
function Map.current(state: Def, player: Player?, key: any): any
	return Store.writable(state, player).data[key]
end

-- Records changes already made to the server cell for the next flush, then tells observers.
local function commit(state: Def, player: Player?, cell: Cell, changes: { Change })
	if #changes == 0 then
		return
	end

	local tracked = Store.written(state, cell, player)
	if tracked and not cell.reset then
		local keys = cell.keys or {}
		cell.keys = keys
		for _, change in changes do
			keys[change.key] = true
		end
	end
	Store.within(Store.SERVER, emit, state, Store.SERVER, cell, changes)
end

-- A nil value removes the key.
function Map.set(state: Def, player: Player?, key: any, value: any)
	local cell = Store.writable(state, player)
	local previous = cell.data[key]
	if not differs(value, previous) then
		return
	end

	cell.data[key] = value
	commit(state, player, cell, { { key = key, value = value, previous = previous } })
end

-- Makes the map equal to entries, sending only the keys that differ.
function Map.replace(state: Def, player: Player?, entries: { [any]: any })
	local cell = Store.writable(state, player)
	local data = cell.data
	local changes: { Change } = {}

	for key, previous in data do
		if entries[key] == nil then
			table.insert(changes, { key = key, value = nil, previous = previous })
		end
	end
	for key, value in entries do
		local previous = data[key]
		if differs(value, previous) then
			table.insert(changes, { key = key, value = value, previous = previous })
		end
	end

	for _, change in changes do
		data[change.key] = change.value
	end
	commit(state, player, cell, changes)
end

function Map.clear(state: Def, player: Player?)
	local cell = Store.writable(state, player)
	if next(cell.data) == nil then
		return
	end

	local changes: { Change } = {}
	for key, previous in cell.data do
		table.insert(changes, { key = key, value = nil, previous = previous })
	end
	cell.data = {}

	-- Cheaper to send the (empty) map than every removed key.
	if Store.written(state, cell, player) then
		cell.reset = true
		cell.keys = nil
	end
	Store.within(Store.SERVER, emit, state, Store.SERVER, cell, changes)
end

local function observerCell(state: Def, player: Player?): (any, Cell)
	local ctx = Store.context()
	return ctx, Store.cell(state, ctx, player, true) :: Cell
end

function Map.observe(state: Def, player: Player?, observer: (...any) -> ()): () -> ()
	local ctx, cell = observerCell(state, player)
	local observers = cell.observers or {}
	cell.observers = observers

	local disconnect = Store.add(observers, observer)
	Store.within(ctx, Store.call, state.name, observer, table.clone(cell.data))
	return disconnect
end

function Map.observeKey(state: Def, player: Player?, key: any, observer: (...any) -> ()): () -> ()
	local ctx, cell = observerCell(state, player)
	local byKey = cell.keyObservers or {}
	cell.keyObservers = byKey
	local observers = byKey[key] or {}
	byKey[key] = observers

	local remove = Store.add(observers, observer)
	Store.within(ctx, Store.call, state.name, observer, cell.data[key])
	return function()
		remove()
		if #observers == 0 and byKey[key] == observers then
			byKey[key] = nil
		end
	end
end

function Map.onChange(state: Def, player: Player?, listener: (...any) -> ()): () -> ()
	local _, cell = observerCell(state, player)
	local listeners = cell.listeners or {}
	cell.listeners = listeners
	return Store.add(listeners, listener)
end

return Map
