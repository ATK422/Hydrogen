--!strict

-- Hydrogen.Log's types and level ranks, shared by its modules.

-- How important a line is, least to most.
export type Level = "debug" | "info" | "warn" | "error"
-- A level a logger lets through from, or "off" for nothing.
export type Threshold = Level | "off"

-- Structured values carried by a line, e.g. { item = "sword", price = 50 }.
export type Fields = { [any]: any }

-- A message, or a function that builds it (and optionally fields) only if the line is emitted.
export type Message = string | () -> (string, Fields?)

-- One emitted line, as sinks receive it. Frozen: sinks share it.
export type Line = {
	level: Level,
	-- The logger's name, e.g. "Shop"; "HYDROGEN" for Hydrogen's own lines; nil for a bare warn().
	tag: string?,
	message: string,
	-- The line's fields, merged with the logger's bound ones. Not copied: don't mutate them.
	fields: Fields?,
	-- The line as the console prints it, e.g. [Shop] bought item=sword price=50.
	text: string,
	-- Clock.now() when it was emitted.
	at: number,
	-- On the summary of a rate-limited burst: how many identical lines were dropped.
	repeated: number?,
}

-- Receives every emitted line. Errors are contained; a sink that yields runs on in its own thread.
export type Sink = (line: Line) -> ()

export type Logger = {
	debug: (self: Logger, message: Message, fields: Fields?) -> (),
	info: (self: Logger, message: Message, fields: Fields?) -> (),
	warn: (self: Logger, message: Message, fields: Fields?) -> (),
	-- Logs at error level. It doesn't throw.
	error: (self: Logger, message: Message, fields: Fields?) -> (),
	-- Whether a line at level would be emitted, to guard expensive work.
	enabled: (self: Logger, level: Level) -> boolean,
	-- A logger with the same name and level that adds fields to every line.
	with: (self: Logger, fields: Fields) -> Logger,
	-- Overrides the level for this logger's name; nil goes back to the global level.
	setLevel: (self: Logger, level: Threshold?) -> (),
	-- The name lines carry, e.g. "Shop".
	name: (self: Logger) -> string,
}

-- A ring buffer of recent lines, e.g. for a debug overlay.
export type Buffer = {
	capacity: number,
	-- The lines it holds, oldest first; only those at minLevel or above if given.
	lines: (self: Buffer, minLevel: Level?) -> { Line },
	-- Lines written since it was created, so a reader can tell cheaply whether anything changed.
	total: (self: Buffer) -> number,
	clear: (self: Buffer) -> (),
	-- Stops receiving lines. The lines it holds stay readable.
	stop: (self: Buffer) -> (),
	-- The sink it receives lines through.
	sink: Sink,
}

export type RateLimitOptions = {
	-- Identical lines let through per window before the rest are dropped. Defaults to 5.
	burst: number?,
	-- Seconds. When a window that dropped lines ends, one summary line says how many. Defaults to 10.
	window: number?,
}

local Types = {}

Types.RANK = table.freeze({
	debug = 1,
	info = 2,
	warn = 3,
	error = 4,
	off = 5,
}) :: { [string]: number }

local NAMES: { Threshold } = { "debug", "info", "warn", "error", "off" }
Types.NAMES = table.freeze(NAMES)

return Types
