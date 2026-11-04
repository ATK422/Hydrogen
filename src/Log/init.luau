--!strict

-- Hydrogen.Log: tagged, levelled, structured logging, and the channel Hydrogen's own warnings
-- go through so a test can capture them (Hydrogen.test does).
--
-- A filtered-out line costs one comparison: every logger caches the lowest level it emits
-- (_min), and changing a level only resets those caches to 0, so each logger works it out
-- again on its next line. Formatting, field merging, rate limiting and sinks only run for
-- lines that are emitted.

local Clock = require("./Clock")
local Types = require("@self/Types")
local Format = require("@self/Format")
local Buffer = require("@self/Buffer")

export type Level = Types.Level
export type Threshold = Types.Threshold
export type Fields = Types.Fields
export type Message = Types.Message
export type Line = Types.Line
export type Sink = Types.Sink
export type Logger = Types.Logger
export type Buffer = Types.Buffer
export type RateLimitOptions = Types.RateLimitOptions

-- Returns true to keep the message from reaching the output (the console). The line is
-- passed too; captures see warn and error lines.
export type Capture = (message: string, line: Line) -> boolean?

-- What game code sees as Hydrogen.Log.
export type Public = {
	of: (target: any, player: any?) -> Logger,
	setLevel: (level: Threshold?, target: any?) -> (),
	level: (target: any?) -> Threshold,
	addSink: (sink: Sink) -> () -> (),
	removeSink: (sink: Sink) -> (),
	console: Sink,
	buffer: (capacity: number?) -> Buffer,
	rateLimit: (options: (RateLimitOptions | false)?) -> (),
	format: (fields: Fields?) -> string,
}

type State = Logger & {
	-- The lowest rank this logger emits; 0 until it is worked out.
	_min: number,
	-- What Log.of was given: a name or a system. nil for bare lines.
	_target: any,
	-- The name, once known. A system's id is only set when define returns, so it is
	-- looked up on the first line rather than in Log.of.
	_tag: string?,
	_resolved: boolean,
	-- Fields added to every line, from with() or a player.
	_fields: Fields?,
	_root: State,
}

-- Snapshot of the configuration, so the test harness can put it back after a test.
export type Snapshot = {
	level: number?,
	overrides: { [string]: number },
	rateLimit: { burst: number, window: number }?,
	sinks: { Sink },
}

local RANK = Types.RANK
local NAMES = Types.NAMES
local DEBUG, INFO, WARN, ERROR = 1, 2, 3, 4

-- Rate-limit entries kept before expired ones are swept.
local MAX_RATE_ENTRIES = 256

local Log = {
	-- Where the console writes warn and error lines.
	output = warn :: (message: string) -> (),
	-- Where the console writes debug and info lines.
	infoOutput = print :: (message: string) -> (),
}

local captures: { Capture } = {}
-- Replaced, never changed in place, so a line being delivered can't skip a sink.
local sinks: { Sink } = {}
-- Sinks Hydrogen wrote, called directly; others run in a thread of their own.
local direct: { [Sink]: boolean } = setmetatable({}, { __mode = "k" }) :: any
-- Sinks whose last call failed, so a broken sink warns once rather than per line.
local failing: { [Sink]: boolean } = setmetatable({}, { __mode = "k" }) :: any

local config = {
	-- nil: debug in Studio, info elsewhere.
	level = nil :: number?,
	overrides = {} :: { [string]: number },
	rateLimit = nil :: { burst: number, window: number }?,
}
local defaultRank: number? = nil

-- Every logger, so a level change can reset their caches.
local loggers: { [State]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local byName: { [string]: State } = {}
local bySystem: { [any]: State } = setmetatable({}, { __mode = "k" }) :: any
local byPlayer: { [State]: { [any]: State } } = setmetatable({}, { __mode = "k" }) :: any

-- Above 0 while sinks run: lines logged from inside a sink go to the console only.
local depth = 0

local function checkThreshold(level: any, what: string): number
	local rank = if type(level) == "string" then RANK[level] else nil
	if rank == nil then
		error(`[HYDROGEN] {what} expects a level: "debug", "info", "warn", "error" or "off", got {level}`, 3)
	end
	return rank
end

local function globalRank(): number
	local level = config.level
	if level then
		return level
	end
	if defaultRank == nil then
		local ok, studio = pcall(function()
			return game:GetService("RunService"):IsStudio()
		end)
		defaultRank = if ok and studio then DEBUG else INFO
	end
	return defaultRank :: number
end

-- A system's id, or its described name while it is replaced. nil inside its constructor.
local function systemName(system: any): string?
	local id = rawget(system, "id")
	if type(id) == "string" then
		return id
	end
	local ok, name = pcall(function()
		local forwarded = system.id
		if type(forwarded) == "string" then
			return forwarded
		end
		-- Required here: Definition may warn through Log one day, and a require at the top
		-- would then be a cycle.
		return require("./Definition").describe(system)
	end)
	return if ok and type(name) == "string" then name else nil
end

local function resolveTag(logger: State): string?
	if logger._resolved then
		return logger._tag
	end
	local root = logger._root
	if not root._resolved then
		local target = root._target
		local tag = if type(target) == "string" then target else systemName(target)
		if tag == nil then
			return nil
		end
		root._tag = tag
		root._resolved = true
	end
	logger._tag = root._tag
	logger._resolved = true
	return logger._tag
end

-- Works out and caches a logger's lowest emitted rank. While a system's name isn't known yet
-- the cache stays 0, so it is worked out again on the next line.
local function refresh(logger: State): number
	local tag = resolveTag(logger)
	local rank = (tag and config.overrides[tag]) or globalRank()
	if logger._resolved then
		logger._min = rank
	end
	return rank
end

local function invalidate()
	for logger in loggers do
		logger._min = 0
	end
end

local function deliver(sink: Sink, line: Line)
	local ok, err
	if direct[sink] then
		ok, err = pcall(sink, line)
	else
		-- Its own thread, so a sink that yields (an HTTP request) doesn't hold up the caller.
		ok, err = coroutine.resume(coroutine.create(sink), line)
	end
	if ok then
		if failing[sink] then
			failing[sink] = nil
		end
		return
	end
	if failing[sink] then
		return
	end
	failing[sink] = true
	local text = `[HYDROGEN] A log sink failed; it keeps receiving lines, but its errors aren't reported again until it succeeds: {err}`
	local warning: Line = {
		level = "warn",
		tag = "HYDROGEN",
		message = string.sub(text, 12),
		fields = nil,
		text = text,
		at = Clock.now(),
		repeated = nil,
	}
	table.freeze(warning)
	-- Straight to the console, never back through the sinks.
	for index = #captures, 1, -1 do
		if captures[index](text, warning) then
			return
		end
	end
	Log.output(text)
end

local function dispatch(line: Line)
	local captured = false
	if line.level == "warn" or line.level == "error" then
		-- The newest capture sees a line first.
		for index = #captures, 1, -1 do
			if captures[index](line.text, line) then
				captured = true
				break
			end
		end
	end

	if depth > 0 then
		if not captured then
			Log.console(line)
		end
		return
	end

	depth += 1
	for _, sink in sinks do
		if sink == Log.console then
			if not captured then
				deliver(sink, line)
			end
		else
			deliver(sink, line)
		end
	end
	depth -= 1
end

local function makeLine(rank: number, tag: string?, message: string, fields: Fields?, text: string, repeated: number?): Line
	local line: Line = {
		level = NAMES[rank] :: Level,
		tag = tag,
		message = message,
		fields = fields,
		text = text,
		at = Clock.now(),
		repeated = repeated,
	}
	table.freeze(line)
	return line
end

-- Rate limiting: identical lines (same level and text) beyond burst in one window are
-- dropped, and one summary line follows when the window ends.
type RateEntry = {
	start: number,
	count: number,
	dropped: number,
	rank: number,
	tag: string?,
	message: string,
	fields: Fields?,
	text: string,
	timer: thread?,
}

local rateEntries: { [string]: RateEntry } = {}
local rateEntryCount = 0

local function forget(key: string, entry: RateEntry)
	if rateEntries[key] == entry then
		rateEntries[key] = nil
		rateEntryCount -= 1
	end
end

local function summarize(key: string, entry: RateEntry, window: number)
	forget(key, entry)
	if entry.dropped == 0 then
		return
	end
	local dropped = entry.dropped
	entry.dropped = 0
	local suffix = ` (repeated {dropped} more {if dropped == 1 then "time" else "times"} in {window}s)`
	dispatch(makeLine(entry.rank, entry.tag, entry.message, entry.fields, entry.text .. suffix, dropped))
end

-- Called by the window's timer. A timer from an earlier configuration finds its entry gone.
local function windowEnded(key: string, entry: RateEntry, window: number)
	if rateEntries[key] ~= entry then
		return
	end
	entry.timer = nil
	summarize(key, entry, window)
end

local function closeEntry(key: string, entry: RateEntry, window: number)
	local timer = entry.timer
	if timer then
		entry.timer = nil
		pcall(Clock.cancel, timer)
	end
	summarize(key, entry, window)
end

local function sweep(now: number, window: number)
	for key, entry in rateEntries do
		local elapsed = now - entry.start
		if entry.dropped == 0 and (elapsed < 0 or elapsed >= window) then
			forget(key, entry)
		end
	end
end

-- Whether a line should be dropped.
local function limited(rank: number, tag: string?, message: string, fields: Fields?, text: string): boolean
	local limit = config.rateLimit
	if limit == nil then
		return false
	end
	local window = limit.window
	local key = NAMES[rank] .. "\0" .. text
	local now = Clock.now()

	local entry = rateEntries[key]
	if entry then
		local elapsed = now - entry.start
		-- Negative when the clock was swapped (a test's fake clock came or went).
		if elapsed < 0 or elapsed >= window then
			closeEntry(key, entry, window)
			entry = nil
		end
	end
	if entry == nil then
		if rateEntryCount >= MAX_RATE_ENTRIES then
			sweep(now, window)
		end
		local created: RateEntry = {
			start = now,
			count = 0,
			dropped = 0,
			rank = rank,
			tag = tag,
			message = message,
			fields = fields,
			text = text,
			timer = nil,
		}
		rateEntries[key] = created
		rateEntryCount += 1
		entry = created
	end

	local current = entry :: RateEntry
	current.count += 1
	if current.count <= limit.burst then
		return false
	end
	current.dropped += 1
	if current.dropped == 1 then
		current.timer = Clock.delay(math.max(current.start + window - now, 0), windowEnded, key, current, window)
	end
	return true
end

local function flushRateLimits()
	local window = if config.rateLimit then config.rateLimit.window else 0
	for key, entry in rateEntries do
		closeEntry(key, entry, window)
	end
	table.clear(rateEntries)
	rateEntryCount = 0
end

local function write(rank: number, tag: string?, message: string, fields: Fields?, text: string?)
	local finalText = text or Format.text(NAMES[rank] :: Level, tag, message, fields)
	if config.rateLimit and limited(rank, tag, message, fields, finalText) then
		return
	end
	dispatch(makeLine(rank, tag, message, fields, finalText, nil))
end

local function merge(base: Fields?, extra: Fields?): Fields?
	if base == nil then
		return extra
	elseif extra == nil then
		return base
	end
	local merged = table.clone(base)
	for key, value in extra do
		merged[key] = value
	end
	return merged
end

local function emit(logger: State, rank: number, message: Message, fields: Fields?)
	local min = logger._min
	if min == 0 then
		min = refresh(logger)
	end
	if rank < min then
		return
	end

	local tag = resolveTag(logger) or "system"
	local text: string
	if type(message) == "function" then
		local ok, built, builtFields = pcall(message)
		if not ok then
			write(WARN, "HYDROGEN", `A log message function failed in {tag}: {built}`, nil, nil)
			return
		end
		text = if type(built) == "string" then built else tostring(built)
		if builtFields ~= nil then
			fields = merge(fields, builtFields)
		end
	elseif type(message) == "string" then
		text = message
	else
		text = tostring(message)
	end

	write(rank, tag, text, merge(logger._fields, fields), nil)
end

local Methods = {}

function Methods.debug(self: State, message: Message, fields: Fields?)
	if self._min > DEBUG then
		return
	end
	emit(self, DEBUG, message, fields)
end

function Methods.info(self: State, message: Message, fields: Fields?)
	if self._min > INFO then
		return
	end
	emit(self, INFO, message, fields)
end

function Methods.warn(self: State, message: Message, fields: Fields?)
	if self._min > WARN then
		return
	end
	emit(self, WARN, message, fields)
end

function Methods.error(self: State, message: Message, fields: Fields?)
	if self._min > ERROR then
		return
	end
	emit(self, ERROR, message, fields)
end

function Methods.enabled(self: State, level: Level): boolean
	local rank = RANK[level]
	if rank == nil or rank > ERROR then
		error(`[HYDROGEN] log:enabled expects "debug", "info", "warn" or "error", got {level}`, 2)
	end
	local min = self._min
	if min == 0 then
		min = refresh(self)
	end
	return rank >= min
end

local newLogger: (root: State?, target: any, fields: Fields?) -> State

function Methods.with(self: State, fields: Fields): Logger
	if type(fields) ~= "table" then
		error(`[HYDROGEN] log:with expects a table of fields, e.g. log:with(\{ round = 3 })`, 2)
	end
	return newLogger(self._root, nil, merge(self._fields, fields))
end

function Methods.setLevel(self: State, level: Threshold?)
	local tag = resolveTag(self)
	if tag == nil then
		error(`[HYDROGEN] log:setLevel was called before this system's define returned, so it has no name yet; call it from init or later`, 2)
	end
	if level == nil then
		config.overrides[tag] = nil
	else
		config.overrides[tag] = checkThreshold(level, "log:setLevel")
	end
	invalidate()
end

function Methods.name(self: State): string
	return resolveTag(self) or "system"
end

function newLogger(root: State?, target: any, fields: Fields?): State
	local logger = {
		debug = Methods.debug,
		info = Methods.info,
		warn = Methods.warn,
		error = Methods.error,
		enabled = Methods.enabled,
		with = Methods.with,
		setLevel = Methods.setLevel,
		name = Methods.name,
		_min = 0,
		_target = target,
		_tag = nil,
		_resolved = false,
		_fields = fields,
	} :: any
	logger._root = root or logger
	loggers[logger] = true
	return logger :: State
end

-- Hydrogen's own lines ([HYDROGEN] ...) and bare warn() calls under Lune.
local hydrogenLogger: State? = nil
local bareLogger = newLogger(nil, nil, nil)
bareLogger._resolved = true

-- The logger for a system or a name. The same target always gives the same logger. With a
-- player, every line also carries player=<Name>.
function Log.of(target: any, player: any?): Logger
	local root: State
	if type(target) == "string" then
		if target == "" then
			error(`[HYDROGEN] Log.of expects a system or a non-empty name`, 2)
		end
		root = byName[target]
		if not root then
			root = newLogger(nil, target, nil)
			byName[target] = root
		end
	elseif type(target) == "table" then
		root = bySystem[target]
		if not root then
			root = newLogger(nil, target, nil)
			bySystem[target] = root
		end
	else
		error(`[HYDROGEN] Log.of expects a system (from Hydrogen.define) or a name, got {typeof(target)}`, 2)
	end

	if player == nil then
		return root
	end
	local name = if type(player) == "table" or typeof(player) == "Instance" then player.Name else nil
	if type(name) ~= "string" then
		error(`[HYDROGEN] Log.of(target, player) expects a Player, got {typeof(player)}`, 2)
	end
	local perPlayer = byPlayer[root]
	if not perPlayer then
		perPlayer = setmetatable({}, { __mode = "k" }) :: any
		byPlayer[root] = perPlayer
	end
	local logger = perPlayer[player]
	if not logger then
		logger = newLogger(root, nil, { player = name })
		perPlayer[player] = logger
	end
	return logger
end

local function tagOf(target: any, what: string): string
	if type(target) == "string" and target ~= "" then
		return target
	elseif type(target) == "table" then
		local name = systemName(target)
		if name then
			return name
		end
		error(`[HYDROGEN] {what} was given a system whose define hasn't returned yet; pass its name, or call it from init or later`, 3)
	end
	error(`[HYDROGEN] {what} expects a system or a name, got {typeof(target)}`, 3)
end

-- Sets the global level, or with a target, that name's level (nil clears it). A global nil
-- goes back to the default: debug in Studio, info elsewhere.
function Log.setLevel(level: Threshold?, target: any?)
	if target == nil then
		config.level = if level == nil then nil else checkThreshold(level, "Log.setLevel")
	else
		local tag = tagOf(target, "Log.setLevel")
		config.overrides[tag] = if level == nil then nil else checkThreshold(level, "Log.setLevel")
	end
	invalidate()
end

-- The level lines must reach to be emitted: globally, or for a target.
function Log.level(target: any?): Threshold
	local rank = globalRank()
	if target ~= nil then
		rank = config.overrides[tagOf(target, "Log.level")] or rank
	end
	return NAMES[rank]
end

local function addSink(sink: Sink, isDirect: boolean): () -> ()
	if type(sink) ~= "function" then
		error(`[HYDROGEN] Log.addSink expects a function that receives each line`, 3)
	end
	if isDirect then
		direct[sink] = true
	end
	if not table.find(sinks, sink) then
		local updated = table.clone(sinks)
		table.insert(updated, sink)
		sinks = updated
	end
	return function()
		Log.removeSink(sink)
	end
end

-- Sends every emitted line to sink as well. Returns a function that removes it.
function Log.addSink(sink: Sink): () -> ()
	return addSink(sink, false)
end

-- For Hydrogen's own sinks (buffers, the test harness): called directly, without a thread.
function Log._addDirectSink(sink: Sink): () -> ()
	return addSink(sink, true)
end

function Log.removeSink(sink: Sink)
	local index = table.find(sinks, sink)
	if index then
		local updated = table.clone(sinks)
		table.remove(updated, index)
		sinks = updated
	end
end

-- The default sink: print for debug and info, warn for warn and error. Remove it with
-- Log.removeSink(Log.console) to send lines only to your own sinks.
function Log.console(line: Line)
	if line.level == "warn" or line.level == "error" then
		Log.output(line.text)
	else
		Log.infoOutput(line.text)
	end
end

direct[Log.console] = true
sinks = { Log.console }

-- A ring buffer of the last capacity lines (default 200), receiving lines until buffer:stop().
function Log.buffer(capacity: number?): Buffer
	local size = capacity or 200
	if type(size) ~= "number" or size < 1 or size % 1 ~= 0 then
		error(`[HYDROGEN] Log.buffer expects a whole number of lines, at least 1`, 2)
	end
	local buffer = Buffer.new(size)
	local remove = addSink(buffer.sink, true)
	function buffer:stop()
		remove()
	end
	return buffer
end

-- Drops identical lines beyond options.burst per options.window seconds, then reports how
-- many were dropped. false or nil turns it off. Off by default.
function Log.rateLimit(options: (RateLimitOptions | false)?)
	if options == nil or options == false then
		flushRateLimits()
		config.rateLimit = nil
		return
	end
	if type(options) ~= "table" then
		error(`[HYDROGEN] Log.rateLimit expects \{ burst = 5, window = 10 } or false`, 2)
	end
	local burst = options.burst or 5
	local window = options.window or 10
	if type(burst) ~= "number" or burst < 1 then
		error(`[HYDROGEN] Log.rateLimit burst must be at least 1`, 2)
	end
	if type(window) ~= "number" or window <= 0 then
		error(`[HYDROGEN] Log.rateLimit window must be a positive number of seconds`, 2)
	end
	flushRateLimits()
	config.rateLimit = { burst = burst, window = window }
end

-- Fields as a line prints them: " item=sword price=50".
Log.format = Format.fields

-- Writes a line that is already formatted, e.g. "[HYDROGEN] ..." from Hydrogen itself. The
-- text is kept exactly; a "[HYDROGEN] " prefix gives it the HYDROGEN tag and its level.
function Log.line(level: Level, text: string)
	local rank = RANK[level]
	local logger = bareLogger
	local tag: string? = nil
	local message = text
	if string.sub(text, 1, 11) == "[HYDROGEN] " then
		local hydrogen = hydrogenLogger
		if hydrogen == nil then
			hydrogen = Log.of("HYDROGEN") :: State
			hydrogenLogger = hydrogen
		end
		logger = hydrogen :: State
		tag = "HYDROGEN"
		message = string.sub(text, 12)
	end

	local min = logger._min
	if min == 0 then
		min = refresh(logger)
	end
	if rank < min then
		return
	end
	write(rank, tag, message, nil, text)
end

-- Hydrogen's warnings: Log.warn(`[HYDROGEN] ...`). Captures see them before the console.
function Log.warn(message: string)
	Log.line("warn", message)
end

-- Sees every warn and error line until the returned function is called.
function Log.capture(capture: Capture): () -> ()
	table.insert(captures, capture)
	return function()
		local index = table.find(captures, capture)
		if index then
			table.remove(captures, index)
		end
	end
end

-- The configuration, for Log._restore. The test harness takes one when it opens.
function Log._snapshot(): Snapshot
	return {
		level = config.level,
		overrides = table.clone(config.overrides),
		rateLimit = config.rateLimit,
		sinks = sinks,
	}
end

-- Puts a snapshot's levels, rate limit and sinks back. Lines a rate limit was holding are
-- forgotten without a summary.
function Log._restore(snapshot: Snapshot)
	config.level = snapshot.level
	config.overrides = table.clone(snapshot.overrides)
	config.rateLimit = snapshot.rateLimit
	sinks = snapshot.sinks
	for _, entry in rateEntries do
		local timer = entry.timer
		if timer then
			entry.timer = nil
			pcall(Clock.cancel, timer)
		end
	end
	table.clear(rateEntries)
	rateEntryCount = 0
	invalidate()
end

-- Hydrogen.Log: the parts meant for game code.
Log.api = table.freeze({
	of = Log.of,
	setLevel = Log.setLevel,
	level = Log.level,
	addSink = Log.addSink,
	removeSink = Log.removeSink,
	console = Log.console,
	buffer = Log.buffer,
	rateLimit = Log.rateLimit,
	format = Log.format,
}) :: Public

return Log
