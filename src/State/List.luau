--!strict

-- An array. Changes are sent as the operations that made them: (reset, ops, values), where ops is
-- flat (op, index) pairs and values holds the value of each set or insert in order. With reset,
-- values is the whole list. Once a frame has more operations than the list has items, the
-- whole list is smaller, so it is sent instead.

local Store = require("./Store")
local Log = require("../Log")

type Def = Store.Def
type Cell = Store.Cell

local SET = 1
local INSERT = 2
local REMOVE = 3

-- Operations beyond the item count before a frame's changes go as a snapshot instead.
local SNAPSHOT_SLACK = 8

local List = {}

local function emit(state: Def, ctx: any, cell: Cell)
	local observed = cell.observers ~= nil and #cell.observers > 0
	if observed or Store.hasAllObservers(state, ctx) then
		local items = table.clone(cell.data)
		if observed then
			Store.notify(state.name, cell.observers, items)
		end
		Store.notifyAll(state, ctx, cell, items)
	end
	Store.changed(state, ctx)
end

local function current(cell: Cell): ...any
	return table.clone(cell.data)
end

function List.observeAll(state: Def, observer: (...any) -> ()): () -> ()
	return Store.observeAll(state, observer, current)
end

local function wireAll(state: Def, items: { any }): { any }
	local wired = table.create(#items)
	for index, item in items do
		wired[index] = state.wire(item)
	end
	return wired
end

function List.initial(_state: Def): any
	return {}
end

function List.clearPending(cell: Cell)
	cell.ops = nil
	cell.opValues = nil
	cell.reset = false
end

function List.snapshot(state: Def, cell: Cell): ...any
	return true, {}, wireAll(state, cell.data)
end

function List.diff(state: Def, cell: Cell): ...any
	local ops, values = cell.ops, cell.opValues
	if cell.reset or not ops or not values then
		List.clearPending(cell)
		return List.snapshot(state, cell)
	end

	List.clearPending(cell)
	return false, ops, values
end

function List.apply(state: Def, ctx: any, cell: Cell, reset: boolean, ops: { number }, values: { any })
	if reset then
		local items = table.create(#values)
		for index, value in values do
			items[index] = state.unwire(value)
		end
		cell.data = items
		emit(state, ctx, cell)
		return
	end

	local data = cell.data
	local nextValue = 0
	for position = 1, #ops, 2 do
		local op, index = ops[position], ops[position + 1]
		local count = #data
		if op == SET and index >= 1 and index <= count then
			nextValue += 1
			data[index] = state.unwire(values[nextValue])
		elseif op == INSERT and index >= 1 and index <= count + 1 then
			nextValue += 1
			table.insert(data, index, state.unwire(values[nextValue]))
		elseif op == REMOVE and index >= 1 and index <= count then
			table.remove(data, index)
		else
			Log.warn(`[HYDROGEN] State {state.name} received a list change that doesn't fit the list (op {op} at {index} of {count}); the rest was ignored`)
			break
		end
	end
	emit(state, ctx, cell)
end

local function readCell(state: Def, player: Player?): Cell?
	Store.read(state)
	return Store.cell(state, Store.context(), player, false)
end

function List.get(state: Def, player: Player?, index: number): any
	local cell = readCell(state, player)
	return cell and cell.data[index]
end

function List.all(state: Def, player: Player?): { any }
	local cell = readCell(state, player)
	return if cell then table.clone(cell.data) else {}
end

function List.size(state: Def, player: Player?): number
	local cell = readCell(state, player)
	return if cell then #cell.data else 0
end

-- The server's item count, for checking an index before a write.
function List.count(state: Def, player: Player?): number
	return #Store.writable(state, player).data
end

local function record(state: Def, player: Player?, cell: Cell, op: number, index: number, value: any)
	if not Store.written(state, cell, player) or cell.reset then
		return
	end

	local ops = cell.ops or {}
	local values = cell.opValues or {}
	cell.ops = ops
	cell.opValues = values

	table.insert(ops, op)
	table.insert(ops, index)
	if op ~= REMOVE then
		table.insert(values, state.wire(value))
	end

	if #ops / 2 > #cell.data + SNAPSHOT_SLACK then
		cell.reset = true
		cell.ops = nil
		cell.opValues = nil
	end
end

local function changed(state: Def, cell: Cell)
	Store.within(Store.SERVER, emit, state, Store.SERVER, cell)
end

-- Indexes are checked by the caller, which knows the error level.
function List.insert(state: Def, player: Player?, index: number, value: any)
	local cell = Store.writable(state, player)
	table.insert(cell.data, index, value)
	record(state, player, cell, INSERT, index, value)
	changed(state, cell)
end

function List.set(state: Def, player: Player?, index: number, value: any)
	local cell = Store.writable(state, player)
	local previous = cell.data[index]
	if previous == value and type(value) ~= "table" then
		return
	end
	cell.data[index] = value
	record(state, player, cell, SET, index, value)
	changed(state, cell)
end

function List.remove(state: Def, player: Player?, index: number): any
	local cell = Store.writable(state, player)
	local removed = table.remove(cell.data, index)
	record(state, player, cell, REMOVE, index, nil)
	changed(state, cell)
	return removed
end

function List.replace(state: Def, player: Player?, items: { any })
	local cell = Store.writable(state, player)
	cell.data = table.clone(items)
	if Store.written(state, cell, player) then
		cell.reset = true
		cell.ops = nil
		cell.opValues = nil
	end
	changed(state, cell)
end

function List.clear(state: Def, player: Player?)
	local cell = Store.writable(state, player)
	if #cell.data == 0 then
		return
	end
	List.replace(state, player, {})
end

function List.observe(state: Def, player: Player?, observer: (...any) -> ()): () -> ()
	local ctx = Store.context()
	local cell = Store.cell(state, ctx, player, true) :: Cell
	local observers = cell.observers or {}
	cell.observers = observers

	local disconnect = Store.add(observers, observer)
	Store.within(ctx, Store.call, state.name, observer, table.clone(cell.data))
	return disconnect
end

return List
