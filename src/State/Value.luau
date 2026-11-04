--!strict

-- A single value. Every change sends the whole value: (value).

local Store = require("./Store")

type Def = Store.Def
type Cell = Store.Cell

local Value = {}

-- Tables are compared by contents nowhere, so setting a table always counts as a change:
-- writing back a table that was changed in place still replicates.
local function differs(new: any, old: any): boolean
	return new ~= old or type(new) == "table"
end

local function emit(state: Def, ctx: any, cell: Cell, new: any, old: any)
	Store.notify(state.name, cell.observers, new, old)
	Store.changed(state, ctx)
end

function Value.initial(state: Def): any
	return state.initial
end

function Value.snapshot(state: Def, cell: Cell): ...any
	return state.wire(cell.data)
end

Value.diff = Value.snapshot

function Value.clearPending(_cell: Cell) end

function Value.apply(state: Def, ctx: any, cell: Cell, wired: any)
	local new = state.unwire(wired)
	local old = cell.data
	cell.data = new
	if differs(new, old) then
		emit(state, ctx, cell, new, old)
	end
end

function Value.get(state: Def, player: Player?): any
	Store.read(state)
	local cell = Store.cell(state, Store.context(), player, false)
	if cell then
		return cell.data
	end
	return state.initial
end

-- The value a write starts from: always the server's, even inside net:as under loopback.
function Value.current(state: Def, player: Player?): any
	return Store.writable(state, player).data
end

function Value.set(state: Def, player: Player?, value: any)
	local cell = Store.writable(state, player)
	local old = cell.data
	if not differs(value, old) then
		return
	end

	cell.data = value
	Store.written(state, cell, player)
	Store.within(Store.SERVER, emit, state, Store.SERVER, cell, value, old)
end

function Value.observe(state: Def, player: Player?, observer: (...any) -> ()): () -> ()
	local ctx = Store.context()
	local cell = Store.cell(state, ctx, player, true) :: Cell
	local observers = cell.observers or {}
	cell.observers = observers

	local disconnect = Store.add(observers, observer)
	Store.within(ctx, Store.call, state.name, observer, cell.data, nil)
	return disconnect
end

return Value
