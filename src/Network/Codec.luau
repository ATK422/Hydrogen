--!strict

-- Packs payloads into a buffer using the GreenTea schema. Types it can't pack are
-- sent as plain Luau values in a side table ("refs"), so every schema can be encoded.

type Writer = {
	buf: buffer,
	cursor: number,
	refs: { any },
}

type Reader = {
	buf: buffer,
	cursor: number,
	refs: { any },
	-- Index of the last ref read.
	ref: number,
}

type Field = {
	write: (writer: Writer, value: any) -> (),
	read: (reader: Reader) -> any,
	-- Fewest bytes a value takes, so a collection's claimed length can be checked against what's left.
	minSize: number,
}

export type Codec = {
	encode: (...any) -> (buffer, { any }?),
	decode: (buf: unknown, refs: unknown?) -> ...any,
}

local Codec = {}

-- Encoding never yields, so one scratch buffer is reused and only the result is copied out.
local scratch = buffer.create(256)

local function reserve(writer: Writer, bytes: number)
	local needed = writer.cursor + bytes
	local size = buffer.len(writer.buf)
	if needed <= size then
		return
	end

	while size < needed do
		size *= 2
	end
	local grown = buffer.create(size)
	buffer.copy(grown, 0, writer.buf, 0, writer.cursor)
	writer.buf = grown
	scratch = grown
end

local function expect(value: any, typeName: string)
	if typeof(value) ~= typeName then
		error(`expected {typeName}, got {typeof(value)}`, 0)
	end
end

-- Lengths and counts as unsigned LEB128: one byte below 128.
local function writeLength(writer: Writer, length: number)
	reserve(writer, 5)
	while length >= 128 do
		buffer.writeu8(writer.buf, writer.cursor, length % 128 + 128)
		writer.cursor += 1
		length = length // 128
	end
	buffer.writeu8(writer.buf, writer.cursor, length)
	writer.cursor += 1
end

local function readLength(reader: Reader): number
	local length = 0
	local scale = 1
	for _ = 1, 5 do
		local byte = buffer.readu8(reader.buf, reader.cursor)
		reader.cursor += 1
		length += (byte % 128) * scale
		if byte < 128 then
			return length
		end
		scale *= 128
	end
	error("length is too long", 0)
end

-- A collection claiming more items than the bytes left could hold is malformed.
local function readCount(reader: Reader, minSize: number): number
	local count = readLength(reader)
	if count * minSize > buffer.len(reader.buf) - reader.cursor then
		error(`claims {count} items but only {buffer.len(reader.buf) - reader.cursor} bytes remain`, 0)
	end
	return count
end

local function fixed(
	size: number,
	typeName: string,
	write: (buf: buffer, offset: number, value: any) -> (),
	read: (buf: buffer, offset: number) -> any
): Field
	return {
		minSize = size,
		write = function(writer, value)
			expect(value, typeName)
			reserve(writer, size)
			write(writer.buf, writer.cursor, value)
			writer.cursor += size
		end,
		read = function(reader)
			local value = read(reader.buf, reader.cursor)
			reader.cursor += size
			return value
		end,
	}
end

local f64 = fixed(8, "number", buffer.writef64, buffer.readf64)

-- Integers in a known range use the smallest width that holds the whole range.
local INTEGER_WIDTHS = {
	{ min = 0, max = 255, size = 1, write = buffer.writeu8, read = buffer.readu8 },
	{ min = -128, max = 127, size = 1, write = buffer.writei8, read = buffer.readi8 },
	{ min = 0, max = 65535, size = 2, write = buffer.writeu16, read = buffer.readu16 },
	{ min = -32768, max = 32767, size = 2, write = buffer.writei16, read = buffer.readi16 },
	{ min = 0, max = 4294967295, size = 4, write = buffer.writeu32, read = buffer.readu32 },
	{ min = -2147483648, max = 2147483647, size = 4, write = buffer.writei32, read = buffer.readi32 },
}

local function numberField(info: any): Field
	local range = info.range
	if not (info.integer and range and range.min and range.max) then
		return f64
	end

	local low, high = range.min, range.max
	for _, width in INTEGER_WIDTHS do
		if low >= width.min and high <= width.max then
			local write = width.write
			return fixed(width.size, "number", function(buf, offset, value)
				-- Out of range would wrap silently, so middleware that changed the value must not get through.
				if value < low or value > high or value % 1 ~= 0 then
					error(`{value} is outside the integer range [{low}, {high}]`, 0)
				end
				write(buf, offset, value)
			end, width.read)
		end
	end

	return f64
end

local stringField: Field = {
	minSize = 1,
	write = function(writer, value)
		expect(value, "string")
		local length = #value
		writeLength(writer, length)
		reserve(writer, length)
		buffer.writestring(writer.buf, writer.cursor, value)
		writer.cursor += length
	end,
	read = function(reader)
		local length = readLength(reader)
		local value = buffer.readstring(reader.buf, reader.cursor, length)
		reader.cursor += length
		return value
	end,
}

local bufferField: Field = {
	minSize = 1,
	write = function(writer, value)
		expect(value, "buffer")
		local length = buffer.len(value)
		writeLength(writer, length)
		reserve(writer, length)
		buffer.copy(writer.buf, writer.cursor, value, 0, length)
		writer.cursor += length
	end,
	read = function(reader)
		local length = readLength(reader)
		local value = buffer.create(length)
		buffer.copy(value, 0, reader.buf, reader.cursor, length)
		reader.cursor += length
		return value
	end,
}

local booleanField = fixed(1, "boolean", function(buf, offset, value)
	buffer.writeu8(buf, offset, if value then 1 else 0)
end, function(buf, offset)
	return buffer.readu8(buf, offset) ~= 0
end)

-- Vector3 and CFrame components are 32-bit floats in Roblox, so f32 loses nothing.
local vector3Field = fixed(12, "Vector3", function(buf, offset, value)
	buffer.writef32(buf, offset, value.X)
	buffer.writef32(buf, offset + 4, value.Y)
	buffer.writef32(buf, offset + 8, value.Z)
end, function(buf, offset)
	return Vector3.new(buffer.readf32(buf, offset), buffer.readf32(buf, offset + 4), buffer.readf32(buf, offset + 8))
end)

local cframeField = fixed(48, "CFrame", function(buf, offset, value)
	local components = { value:GetComponents() }
	for index = 1, 12 do
		buffer.writef32(buf, offset + (index - 1) * 4, components[index])
	end
end, function(buf, offset)
	local components = table.create(12)
	for index = 1, 12 do
		components[index] = buffer.readf32(buf, offset + (index - 1) * 4)
	end
	return (CFrame.new :: any)(table.unpack(components))
end)

local nilField: Field = {
	minSize = 0,
	write = function() end,
	read = function()
		return nil
	end,
}

-- Anything without a packed form goes over the wire as itself. A flag byte marks nil,
-- so refs stays a contiguous array (remotes cut arrays off at the first hole).
local fallbackField: Field = {
	minSize = 1,
	write = function(writer, value)
		reserve(writer, 1)
		if value == nil then
			buffer.writeu8(writer.buf, writer.cursor, 0)
		else
			buffer.writeu8(writer.buf, writer.cursor, 1)
			table.insert(writer.refs, value)
		end
		writer.cursor += 1
	end,
	read = function(reader)
		local flag = buffer.readu8(reader.buf, reader.cursor)
		reader.cursor += 1
		if flag == 0 then
			return nil
		end
		reader.ref += 1
		return reader.refs[reader.ref]
	end,
}

local BASIC_FIELDS: { [string]: Field } = {
	boolean = booleanField,
	buffer = bufferField,
	Vector3 = vector3Field,
	CFrame = cframeField,
	["nil"] = nilField,
}

local fieldFor: (schema: any) -> Field

local function literalField(value: any): Field
	return {
		minSize = 0,
		write = function(_, input)
			if input ~= value then
				error(`expected literally {tostring(value)}, got {tostring(input)}`, 0)
			end
		end,
		read = function()
			return value
		end,
	}
end

local function optionalField(inner: Field): Field
	return {
		minSize = 1,
		write = function(writer, value)
			reserve(writer, 1)
			buffer.writeu8(writer.buf, writer.cursor, if value == nil then 0 else 1)
			writer.cursor += 1
			if value ~= nil then
				inner.write(writer, value)
			end
		end,
		read = function(reader)
			local present = buffer.readu8(reader.buf, reader.cursor)
			reader.cursor += 1
			if present == 0 then
				return nil
			end
			return inner.read(reader)
		end,
	}
end

local function arrayField(item: Field): Field
	return {
		minSize = 1,
		write = function(writer, value)
			expect(value, "table")
			local count = #value
			writeLength(writer, count)
			for index = 1, count do
				item.write(writer, value[index])
			end
		end,
		read = function(reader)
			local count = readCount(reader, item.minSize)
			local value = table.create(count)
			for index = 1, count do
				value[index] = item.read(reader)
			end
			return value
		end,
	}
end

local function dictionaryField(key: Field, item: Field): Field
	return {
		minSize = 1,
		write = function(writer, value)
			expect(value, "table")
			local count = 0
			for _ in value do
				count += 1
			end
			writeLength(writer, count)
			for entryKey, entry in value do
				key.write(writer, entryKey)
				item.write(writer, entry)
			end
		end,
		read = function(reader)
			local count = readCount(reader, key.minSize + item.minSize)
			local value = {}
			for _ = 1, count do
				local entryKey = key.read(reader)
				if entryKey == nil then
					error("dictionary key is nil", 0)
				end
				value[entryKey] = item.read(reader)
			end
			return value
		end,
	}
end

-- Fields go in sorted key order so both sides agree without sending names.
local function structField(contents: { [string]: any }): Field
	local keys = {}
	for key in contents do
		table.insert(keys, key)
	end
	table.sort(keys)

	local fields = {}
	local minSize = 0
	for index, key in keys do
		fields[index] = fieldFor(contents[key])
		minSize += fields[index].minSize
	end

	return {
		minSize = minSize,
		write = function(writer, value)
			expect(value, "table")
			for index, key in keys do
				fields[index].write(writer, value[key])
			end
		end,
		read = function(reader)
			local value = {}
			for index, key in keys do
				value[key] = fields[index].read(reader)
			end
			return value
		end,
	}
end

local function tableField(info: any): Field
	local indexer = info.indexer
	local hasContents = next(info.contents) ~= nil

	if info.raw then
		return fallbackField
	elseif not indexer then
		return structField(info.contents)
	elseif hasContents then
		-- Mixed struct and indexer tables are rare; not worth a packed form.
		return fallbackField
	end

	local item = fieldFor(indexer.value)
	if info.array then
		-- Items that take no bytes would let a few bytes claim a huge array.
		return if item.minSize > 0 then arrayField(item) else fallbackField
	end

	local key = fieldFor(indexer.key)
	if key.minSize + item.minSize == 0 or key == fallbackField then
		return fallbackField
	end
	return dictionaryField(key, item)
end

function fieldFor(schema: any): Field
	local kind = schema.kind

	if kind == "number" then
		return numberField(schema.number)
	elseif kind == "string" then
		return stringField
	elseif kind == "basic" then
		return BASIC_FIELDS[schema.basic.typeof or ""] or fallbackField
	elseif kind == "literal" then
		return literalField(schema.literal.value)
	elseif kind == "table" then
		return tableField(schema.table)
	elseif kind == "union" and schema.union.optional then
		local inner = nil
		for _, member in schema.union.contents do
			local basic = member.basic
			if not (basic and (basic.typeof == "nil" or basic.type == "nil")) then
				if inner then
					-- More than one non-nil member needs a tag; fall back instead.
					return fallbackField
				end
				inner = member
			end
		end
		return if inner then optionalField(fieldFor(inner)) else nilField
	end

	return fallbackField
end

-- Builds a codec for a schema built with gt.build: a tuple, a vararg, nil (no values) or one type.
function Codec.new(schema: any, name: string): Codec
	local fields: { Field } = {}
	local vararg: Field? = nil

	if schema.kind == "tuple" then
		for index, member in schema.tuple.contents do
			fields[index] = fieldFor(member)
		end
		if schema.tuple.vararg then
			vararg = fieldFor(schema.tuple.vararg.vararg.type)
		end
	elseif schema.kind == "vararg" then
		vararg = fieldFor(schema.vararg.type)
	elseif not (schema.kind == "basic" and schema.basic.typeof == "nil") then
		fields[1] = fieldFor(schema)
	end

	-- Same reason as arrays: zero-byte items would let a few bytes claim a huge count.
	if vararg and vararg.minSize == 0 then
		vararg = fallbackField
	end

	local count = #fields
	local codec = {} :: Codec

	local function write(writer: Writer, ...: any)
		for index = 1, count do
			fields[index].write(writer, (select(index, ...)))
		end

		if vararg then
			-- Trailing nils aren't part of a vararg, matching how GreenTea checks it.
			local last = select("#", ...)
			while last > count and select(last, ...) == nil do
				last -= 1
			end

			writeLength(writer, math.max(last - count, 0))
			for index = count + 1, last do
				vararg.write(writer, (select(index, ...)))
			end
		end
	end

	-- Errors if a value doesn't fit the schema, e.g. middleware changed it after validation.
	function codec.encode(...: any): (buffer, { any }?)
		local writer: Writer = { buf = scratch, cursor = 0, refs = {} }
		local ok, err = pcall(write, writer, ...)
		if not ok then
			error(`[HYDROGEN] Can't encode {name}: {err}`, 0)
		end

		local result = buffer.create(writer.cursor)
		buffer.copy(result, 0, writer.buf, 0, writer.cursor)
		return result, if #writer.refs > 0 then writer.refs else nil
	end

	-- Errors on malformed input; the decoded values still need validating against the schema.
	function codec.decode(buf: unknown, refs: unknown?): ...any
		if typeof(buf) ~= "buffer" then
			error(`expected an encoded buffer, got {typeof(buf)}`, 0)
		end
		if refs ~= nil and type(refs) ~= "table" then
			error(`expected a table of values, got {typeof(refs)}`, 0)
		end

		local reader: Reader = { buf = buf :: buffer, cursor = 0, refs = (refs or {}) :: { any }, ref = 0 }
		local values = table.create(count)
		for index = 1, count do
			values[index] = fields[index].read(reader)
		end

		local total = count
		if vararg then
			local extra = readCount(reader, vararg.minSize)
			for index = count + 1, count + extra do
				values[index] = vararg.read(reader)
			end
			total += extra
		end

		if reader.cursor ~= buffer.len(reader.buf) then
			error(`{buffer.len(reader.buf) - reader.cursor} unread bytes`, 0)
		end

		return table.unpack(values, 1, total)
	end

	return codec
end

-- Values pass through unchanged when an object has no codec.
function Codec.encodeWith(codec: Codec?, ...: any): ...any
	if codec then
		return codec.encode(...)
	end
	return ...
end

local function decodedOrError(name: string, payload: string, ok: boolean, ...: any): ...any
	if not ok then
		error(`[HYDROGEN] Can't decode {name} {payload}: {(...)}`, 0)
	end
	return ...
end

-- For function payloads, which error back to the caller instead of being dropped.
function Codec.decodeWith(codec: Codec?, name: string, payload: string, ...: any): ...any
	if codec then
		return decodedOrError(name, payload, pcall(codec.decode, ...))
	end
	return ...
end

return Codec
