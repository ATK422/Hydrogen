--!strict

-- A ring buffer sink: keeps the last capacity lines, overwriting the oldest. Writing a line
-- is two assignments, so it can sit behind every line a game emits.

local Types = require("./Types")

local Buffer = {}

function Buffer.new(capacity: number): Types.Buffer
	local slots: { Types.Line } = {}
	-- The slot written last, and how many slots hold a line.
	local head = 0
	local count = 0
	local total = 0

	local buffer = {} :: Types.Buffer
	buffer.capacity = capacity

	function buffer.sink(line: Types.Line)
		head = head % capacity + 1
		slots[head] = line
		if count < capacity then
			count += 1
		end
		total += 1
	end

	function buffer:lines(minLevel: Types.Level?): { Types.Line }
		local min = if minLevel then Types.RANK[minLevel] else 1
		if min == nil then
			error(`[HYDROGEN] buffer:lines expects a level ("debug", "info", "warn" or "error"), got {minLevel}`, 2)
		end
		local list: { Types.Line } = {}
		local first = if count < capacity then 1 else head % capacity + 1
		for offset = 0, count - 1 do
			local line = slots[(first + offset - 1) % capacity + 1]
			if Types.RANK[line.level] >= min then
				table.insert(list, line)
			end
		end
		return list
	end

	function buffer:total(): number
		return total
	end

	function buffer:clear()
		table.clear(slots)
		head = 0
		count = 0
	end

	-- Replaced by Log.buffer with the function that removes the sink.
	function buffer:stop() end

	return buffer
end

return Buffer
