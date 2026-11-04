--!strict

-- A named collection of session-locked records. Data.player and Data.store wrap this in a system.

local Backend = require("./Backend")
local Clock = require("./Clock")
local Tables = require("./Tables")
local gt = require("../../roblox_packages/gt")
local Time = require("../Clock")
local Log = require("../Log")

type Backend = Backend.Backend
type RequestKind = Backend.RequestKind

export type Migration = ((data: any) -> any) | { migrate: (data: any) -> any, backwardsCompatible: boolean? }

export type UpdateOnceResult = "applied" | "duplicate" | "aborted" | "failed"

export type Config = {
	name: string,
	template: any,
	schema: any?,
	migrations: { Migration }?,
	backend: (() -> Backend),
	autosave: number?,
	lockTimeout: number?,
	loadTimeout: number?,
	retries: number?,
	-- Turns a caller's key (a Player for player stores) into the record key.
	keyOf: (key: any) -> string,
	-- UserIds to tag a new record with, for data-erasure requests.
	userIdsOf: ((key: any) -> { number }?)?,
	-- The session lock was taken by another server; this server must stop using the data.
	onLost: ((key: any) -> ())?,
}

-- What is stored under each key.
type Record = {
	data: any,
	-- Migrations applied to data.
	version: number,
	-- The fewest migrations a server can know and still read data.
	compatible: number,
	lock: { id: string, time: number }?,
	-- Set while (or after) a multi-key transaction wrote this record. See commitGroup.
	tx: { id: string, previous: any }?,
	-- Recent updateOnce ids, oldest first.
	once: { string }?,
}

type Status = "loading" | "loaded" | "failed" | "lost" | "closed"

type Session = {
	key: string,
	owner: any,
	status: Status,
	data: any,
	lockId: string,
	backend: Backend,
	-- Bumped on every commit; savedVersion is the newest version known to be stored.
	version: number,
	savedVersion: number,
	-- os.clock of the last save attempt and Clock.now of the last successful write.
	lastAttempt: number,
	lastWrite: number,
	once: { string },
	-- Version that recorded each id; 0 when it came from the store.
	onceVersion: { [string]: number },
	-- Unpersisted multi-key transaction this session is part of.
	group: Group?,
	-- Save mutex: whether a save runs, and the threads waiting for it.
	busy: boolean,
	waiting: { thread },
	-- Release the lock with the next write.
	releasing: boolean,
	-- The copy an update callback is changing, so updates nested inside it change it too.
	draft: any?,
	-- updateOnce calls still saving; unload waits for them.
	onceRunning: number,
}

type Group = {
	sessions: { Session },
	persisted: boolean,
	-- Markers of earlier attempts that failed, removed once one succeeds.
	stale: { string },
}

local AUTOSAVE = 120
local LOCK_TIMEOUT = 600
local LOAD_TIMEOUT = 30
local RETRIES = 5
local ONCE_KEEP = 100

local HttpService: HttpService? = nil
local idCounter = 0

local function newId(): string
	idCounter += 1
	local ok, guid = pcall(function()
		HttpService = HttpService or game:GetService("HttpService")
		return (HttpService :: HttpService):GenerateGUID(false)
	end)
	if ok and type(guid) == "string" then
		return guid
	end
	return string.format("%x-%x-%x-%x", os.time(), math.random(0, 0x7fffffff), math.floor(os.clock() * 1e6) % 0x7fffffff, idCounter)
end

local function report(fn: (...any) -> (), ...: any)
	local ok, err = xpcall(fn, debug.traceback, ...)
	if not ok then
		Log.warn(`[HYDROGEN] Data changed listener failed: {err}`)
	end
end

-- Runs a user callback that must not yield, so no other change can interleave with it.
local function runSync(what: string, fn: (...any) -> ...any, ...: any): ...any
	local thread = coroutine.create(fn)
	local results = table.pack(coroutine.resume(thread, ...))
	if coroutine.status(thread) ~= "dead" then
		coroutine.close(thread)
		error(`[HYDROGEN] {what} callbacks can't yield; do the yielding work first, then update`, 0)
	end
	if not results[1] then
		error(debug.traceback(thread, tostring(results[2])), 0)
	end
	return table.unpack(results, 2, results.n)
end

-- Runs fn on drafts while marking them as the sessions' pending copies. Returns fn's first result.
local function runOn(sessions: { Session }, drafts: { any }, what: string, fn: (...any) -> ...any, arg: any): any
	for index, session in sessions do
		if session.draft ~= nil then
			error(`[HYDROGEN] {what} can't run inside another update's callback for the same data; change the data argument instead`, 0)
		end
		session.draft = drafts[index]
	end
	local ok, result = pcall(runSync, what, fn, arg)
	for _, session in sessions do
		session.draft = nil
	end
	if not ok then
		error(result, 0)
	end
	return result
end

local Store = {}
Store.__index = Store
Store.runSync = runSync

export type Store = typeof(setmetatable(
	{} :: {
		name: string,
		_config: Config,
		_template: any,
		_schema: any,
		_fields: { [string]: any }?,
		_migrations: { { migrate: (any) -> any, backwardsCompatible: boolean? } },
		_compatible: number,
		_sessions: { [string]: Session },
		_listeners: { (key: any, data: any, old: any) -> () },
		_closing: boolean,
		_autosaving: boolean,
		_inFlight: { [RequestKind]: number },
		_txStore: string,
	},
	Store
))

function Store.new(config: Config): Store
	local template = config.template
	if type(template) ~= "table" then
		error(`[HYDROGEN] Data store {config.name} needs a template table`, 3)
	end

	local schema = gt.typecast(if config.schema ~= nil then config.schema else gt.typeof(template))
	local ok, cause = schema:matches(template)
	if not ok then
		error(`[HYDROGEN] Data store {config.name}'s template doesn't match its schema: {cause}`, 3)
	end

	-- Plain struct schemas let a change to one field be checked against that field alone.
	local fields = nil
	local info = (schema :: any).table
	if (schema :: any).kind == "table" and info and not info.indexer and not info.raw then
		fields = info.contents
	end

	local migrations = {}
	for index, migration in config.migrations or {} do
		if type(migration) == "function" then
			migrations[index] = { migrate = migration }
		elseif type(migration) == "table" and type(migration.migrate) == "function" then
			migrations[index] = migration
		else
			error(`[HYDROGEN] Data store {config.name}: migration {index} must be a function or \{ migrate = function \}`, 3)
		end
	end

	-- Data written now can be read by servers that lack the trailing backwards-compatible migrations.
	local compatible = #migrations
	while compatible > 0 and migrations[compatible].backwardsCompatible do
		compatible -= 1
	end

	local self = setmetatable({
		name = config.name,
		_config = config,
		_template = Tables.freeze(Tables.copy(template)),
		_schema = schema,
		_fields = fields,
		_migrations = migrations,
		_compatible = compatible,
		_sessions = {},
		_listeners = {},
		_closing = false,
		_autosaving = false,
		_inFlight = { update = 0, read = 0, write = 0 },
		_txStore = `{config.name}#tx`,
	}, Store)
	return self
end

-- Requests ------------------------------------------------------------------------------------

-- Waits for budget, then tries fn up to the configured attempts with exponential backoff.
function Store._request<T...>(self: Store, backend: Backend, kind: RequestKind, fn: () -> T...): (boolean, any)
	local attempts = self._config.retries or RETRIES
	local lastError: any = nil

	for attempt = 1, attempts do
		-- Requests already sent this frame haven't reached the budget yet.
		while backend:budget(kind) - self._inFlight[kind] <= 0 do
			Clock.wait(if self._closing then 0.1 else 1)
		end

		self._inFlight[kind] += 1
		local ok, result = pcall(fn)
		self._inFlight[kind] -= 1
		if ok then
			return true, result
		end

		lastError = result
		if attempt < attempts then
			Log.warn(`[HYDROGEN] Data store {self.name} {kind} request failed (attempt {attempt} of {attempts}), retrying: {result}`)
			Clock.wait(if self._closing then 0.5 else math.min(2 ^ (attempt - 1), 8))
		end
	end

	return false, lastError
end

-- Records -------------------------------------------------------------------------------------

-- Migrates, fills in template fields and validates. Errors with a readable message.
function Store._prepare(self: Store, record: Record): any
	local data = Tables.copy(record.data)
	local version = record.version or 0
	local known = #self._migrations

	if version > known then
		if known < (record.compatible or version) then
			error(`saved by a newer server ({version} migrations, this server knows {known}); this server can't read it`, 0)
		end
	else
		for index = version + 1, known do
			local ok, result = pcall(self._migrations[index].migrate, data)
			if not ok then
				error(`migration {index} failed: {result}`, 0)
			end
			data = result
		end
	end

	if type(data) ~= "table" then
		error(`data is a {typeof(data)}, not a table`, 0)
	end
	Tables.reconcile(data, self._template)

	local ok, cause = self._schema:matches(data)
	if not ok then
		error(`doesn't match the schema: {cause}`, 0)
	end
	return data
end

-- The record's data with any multi-key transaction resolved; txCommitted maps tx ids already read.
local function resolveTx(record: Record, txCommitted: { [string]: boolean }): any
	local tx = record.tx
	if not tx then
		return record.data
	end
	return if txCommitted[tx.id] then record.data else tx.previous
end

function Store._readTxStatus(self: Store, backend: Backend, txId: string, txCommitted: { [string]: boolean }): (boolean, any)
	local ok, marker = self:_request(backend, "read", function()
		return backend:read(self._txStore, txId)
	end)
	if ok then
		-- The marker is removed when the transaction commits.
		txCommitted[txId] = marker == nil
	end
	return ok, marker
end

-- Sessions ------------------------------------------------------------------------------------

function Store._session(self: Store, key: any): Session?
	return self._sessions[self._config.keyOf(key)]
end

function Store._loaded(self: Store, key: any, what: string): Session
	local session = self:_session(key)
	if not session or session.status == "loading" or session.status == "closed" then
		error(`[HYDROGEN] {what}: {self.name} has no data loaded for {self:_describe(key)}`, 3)
	end
	return session
end

function Store._describe(self: Store, key: any): string
	if type(key) == "string" then
		return `key "{key}"`
	end
	local ok, name = pcall(function()
		return key.Name
	end)
	return if ok and name then `{name} (key "{self._config.keyOf(key)}")` else tostring(key)
end

local function acquire(session: Session)
	if session.busy then
		table.insert(session.waiting, coroutine.running())
		coroutine.yield()
	end
	session.busy = true
end

local function releaseMutex(session: Session)
	local nextThread = table.remove(session.waiting, 1)
	if nextThread then
		-- Busy passes straight to the next waiter.
		task.spawn(nextThread)
	else
		session.busy = false
	end
end

-- Loads and session-locks the key. Waits for another server's lock up to loadTimeout, unless
-- cancelled() says to stop (the player left). On failure the session is removed.
function Store.load(self: Store, key: any, cancelled: (() -> boolean)?): (boolean, string?)
	local recordKey = self._config.keyOf(key)
	if self._closing then
		return false, "the server is shutting down"
	end

	-- A player who rejoined quickly waits for their previous session to finish saving.
	local existing = self._sessions[recordKey]
	local began = Time.now()
	while existing and (existing.status == "loading" or existing.releasing or existing.owner ~= key) do
		if Time.now() - began > (self._config.loadTimeout or LOAD_TIMEOUT) then
			return false, `an earlier session for {self:_describe(key)} is still closing`
		end
		Time.wait()
		existing = self._sessions[recordKey]
	end
	if existing then
		-- Loading the same key twice (two apps in one test VM) shares the first load.
		if existing.status == "loaded" then
			return true, nil
		end
		return false, `the existing session for {self:_describe(key)} is {existing.status}`
	end

	local backend = self._config.backend()
	local session: Session = {
		key = recordKey,
		owner = key,
		status = "loading",
		data = self._template,
		lockId = newId(),
		backend = backend,
		version = 0,
		savedVersion = 0,
		lastAttempt = Time.now(),
		lastWrite = Clock.now(),
		once = {},
		onceVersion = {},
		group = nil,
		busy = false,
		waiting = {},
		releasing = false,
		draft = nil,
		onceRunning = 0,
	}
	self._sessions[recordKey] = session

	local ok, err = self:_acquire(session, cancelled)
	if not ok then
		self._sessions[recordKey] = nil
		session.status = "closed"
		return false, err
	end

	session.status = "loaded"
	self:_startAutosave()
	return true, nil
end

function Store._acquire(self: Store, session: Session, cancelled: (() -> boolean)?): (boolean, string?)
	local backend = session.backend
	local lockTimeout = self._config.lockTimeout or LOCK_TIMEOUT
	local loadTimeout = self._config.loadTimeout or LOAD_TIMEOUT
	local userIds = if self._config.userIdsOf then self._config.userIdsOf(session.owner) else nil
	local txCommitted: { [string]: boolean } = {}
	local waited = 0
	local lockAttempt = 0

	while true do
		local outcome: "loaded" | "locked" | "tx" | "invalid" = "loaded"
		local detail: any = nil
		local data: any = nil
		local takenOver: number? = nil

		local ok, err = self:_request(backend, "update", function()
			return backend:update(self.name, session.key, function(current: Record?)
				local record: Record = current or { data = Tables.copy(self._template), version = #self._migrations, compatible = self._compatible }
				local lock = record.lock
				if lock and lock.id ~= session.lockId and Clock.now() - lock.time < lockTimeout then
					outcome, detail = "locked", nil
					return nil
				end
				takenOver = if lock and lock.id ~= session.lockId then Clock.now() - lock.time else nil

				-- Which way a transaction went is read outside the transform, which can't yield.
				local tx = record.tx
				if tx and txCommitted[tx.id] == nil then
					outcome, detail = "tx", tx.id
					return nil
				end

				local prepared, problem = pcall(self._prepare, self, {
					data = resolveTx(record, txCommitted),
					version = record.version,
					compatible = record.compatible,
				})
				if not prepared then
					outcome, detail = "invalid", problem
					return nil
				end

				outcome = "loaded"
				data = problem
				if (record.version or 0) <= #self._migrations then
					record.version = #self._migrations
					record.compatible = self._compatible
				end
				record.data = data
				record.tx = nil
				record.lock = { id = session.lockId, time = Clock.now() }
				session.once = table.clone(record.once or {})
				return record, if current == nil then userIds else nil
			end)
		end)

		if not ok then
			return false, `couldn't load {self:_describe(session.owner)}: {err}`
		elseif outcome == "loaded" then
			if takenOver then
				Log.warn(`[HYDROGEN] Data store {self.name}: took over {self:_describe(session.owner)}, whose lock was abandoned {takenOver}s ago`)
			end
			session.data = Tables.freeze(data)
			session.lastWrite = Clock.now()
			for _, id in session.once do
				session.onceVersion[id] = 0
			end
			return true, nil
		elseif outcome == "invalid" then
			return false, `{self.name} data for {self:_describe(session.owner)} {detail}`
		elseif outcome == "tx" then
			local read, readErr = self:_readTxStatus(backend, detail, txCommitted)
			if not read then
				return false, `couldn't check a transaction for {self:_describe(session.owner)}: {readErr}`
			end
		else
			if self._closing or (cancelled and cancelled()) then
				return false, "cancelled while another server held the lock"
			end
			if waited >= loadTimeout then
				return false, `{self:_describe(session.owner)} is still open on another server after {loadTimeout}s`
			end
			lockAttempt += 1
			local delay = math.min(2 ^ (lockAttempt - 1), 5, loadTimeout - waited)
			Clock.wait(delay)
			waited += delay
		end
	end
end

-- Reads the key without locking it; nil if it was never saved.
function Store.view(self: Store, key: any): any?
	local backend = self._config.backend()
	local recordKey = self._config.keyOf(key)
	local ok, record = self:_request(backend, "read", function()
		return backend:read(self.name, recordKey)
	end)
	if not ok then
		error(`[HYDROGEN] {self.name}: couldn't read {self:_describe(key)}: {record}`, 2)
	end
	if record == nil then
		return nil
	end

	local txCommitted = {}
	if record.tx then
		local read, err = self:_readTxStatus(backend, record.tx.id, txCommitted)
		if not read then
			error(`[HYDROGEN] {self.name}: couldn't check a transaction for {self:_describe(key)}: {err}`, 2)
		end
	end

	local prepared, data = pcall(self._prepare, self, {
		data = resolveTx(record, txCommitted),
		version = record.version,
		compatible = record.compatible,
	})
	if not prepared then
		error(`[HYDROGEN] {self.name} data for {self:_describe(key)} {data}`, 2)
	end
	return Tables.freeze(data)
end

-- Changes -------------------------------------------------------------------------------------

function Store._validate(self: Store, data: any, changed: { any }): (boolean, any)
	local fields = self._fields
	if fields then
		for _, field in changed do
			local schema = fields[field]
			if schema then
				local ok, cause = schema:matches(data[field])
				if not ok then
					return false, `field "{field}" {cause}`
				end
			end
		end
		return true, nil
	end
	return self._schema:matches(data)
end

function Store._commit(self: Store, session: Session, data: any)
	local old = session.data
	session.data = data
	session.version += 1
	for _, listener in table.clone(self._listeners) do
		task.spawn(report, listener, session.owner, data, old)
	end
end

-- Runs fn on a copy of the data, checks the result and commits it. Returns whether it committed.
function Store.update(self: Store, key: any, fn: (data: any) -> ...any): boolean
	local session = self:_loaded(key, "update")
	if session.draft ~= nil then
		-- Called from inside another update's callback (a helper like addCoins): it joins that
		-- change, which commits or aborts as a whole.
		if runSync("update", fn, session.draft) == false then
			error(`[HYDROGEN] {self.name}: an update nested inside another update can't abort on its own; return false from the outer callback`, 2)
		end
		return true
	end

	local draft = Tables.copy(session.data)
	if runOn({ session }, { draft }, "update", fn, draft) == false then
		return false
	end

	local changed = Tables.share(draft, session.data)
	if #changed == 0 then
		return true
	end

	local ok, cause = self:_validate(draft, changed)
	if not ok then
		error(`[HYDROGEN] {self.name} update for {self:_describe(key)} rejected, {cause}`, 2)
	end
	self:_commit(session, Tables.freeze(draft))
	return true
end

-- One top-level field, without copying the rest. Used by PlayerState.
function Store.setField(self: Store, key: any, field: string, value: any)
	local session = self:_loaded(key, "set")
	if session.draft ~= nil then
		-- Inside an update's callback: part of that change, checked when it commits.
		session.draft[field] = Tables.copy(value)
		return
	end
	local current = session.data
	if current[field] == value then
		return
	end

	value = Tables.freeze(Tables.copy(value))
	local data = table.clone(current)
	data[field] = value
	local ok, cause = self:_validate(data, { field })
	if not ok then
		error(`[HYDROGEN] {self.name} field "{field}" for {self:_describe(key)} rejected: {cause}`, 3)
	end
	self:_commit(session, table.freeze(data))
end

-- Applies fn once per id: the id is recorded in the same commit as fn's change, and the call
-- returns only after a save holding both succeeded. Meant for purchase receipts.
function Store.updateOnce(self: Store, key: any, id: string, fn: (data: any) -> ...any): UpdateOnceResult
	local session = self:_session(key)
	if not session or session.status ~= "loaded" or session.releasing then
		return "failed"
	end
	if session.draft ~= nil then
		error(`[HYDROGEN] {self.name}: updateOnce can't run inside another update's callback`, 2)
	end

	session.onceRunning += 1
	local ok, result = pcall(self._updateOnce, self, session, key, id, fn)
	session.onceRunning -= 1
	if not ok then
		error(result, 0)
	end
	return result
end

function Store._updateOnce(self: Store, session: Session, key: any, id: string, fn: (data: any) -> ...any): UpdateOnceResult
	local recordedAt = session.onceVersion[id]
	if recordedAt then
		if session.savedVersion >= recordedAt then
			return "duplicate"
		end
		-- Recorded here but not stored yet: only a successful save makes it a duplicate.
		return if self:save(key) then "duplicate" else "failed"
	end

	local draft = Tables.copy(session.data)
	if runOn({ session }, { draft }, "updateOnce", fn, draft) == false then
		return "aborted"
	end
	local changed = Tables.share(draft, session.data)
	local ok, cause = self:_validate(draft, changed)
	if not ok then
		error(`[HYDROGEN] {self.name} updateOnce for {self:_describe(key)} rejected, {cause}`, 0)
	end

	self:_commit(session, Tables.freeze(draft))
	table.insert(session.once, id)
	session.onceVersion[id] = session.version
	while #session.once > ONCE_KEEP do
		session.onceVersion[table.remove(session.once, 1) :: string] = nil
	end

	return if self:save(key) then "applied" else "failed"
end

-- Changes several keys at once. The change is all-or-nothing in memory right away, and saved
-- with a two-phase commit, so a crash can't store one side of a trade without the other.
function Store.transaction(self: Store, keys: { any }, fn: (data: { [any]: any }) -> ...any): boolean
	local sessions: { Session } = {}
	local drafts: { [any]: any } = {}
	for _, key in keys do
		local session = self:_loaded(key, "transaction")
		if session.status ~= "loaded" then
			error(`[HYDROGEN] transaction: {self.name} data for {self:_describe(key)} isn't usable ({session.status})`, 2)
		end
		if drafts[key] == nil then
			table.insert(sessions, session)
			drafts[key] = Tables.copy(session.data)
		end
	end

	local sessionDrafts = {}
	for index, session in sessions do
		sessionDrafts[index] = drafts[session.owner]
	end
	if runOn(sessions, sessionDrafts, "transaction", fn, drafts) == false then
		return false
	end

	local results: { { session: Session, data: any } } = {}
	for _, session in sessions do
		local draft = drafts[session.owner]
		local changed = Tables.share(draft, session.data)
		if #changed > 0 then
			local ok, cause = self:_validate(draft, changed)
			if not ok then
				error(`[HYDROGEN] {self.name} transaction rejected for {self:_describe(session.owner)}, {cause}`, 2)
			end
			table.insert(results, { session = session, data = draft })
		end
	end

	for _, result in results do
		self:_commit(result.session, Tables.freeze(result.data))
	end

	if #results >= 2 then
		local group: Group = { sessions = {}, persisted = false, stale = {} }
		for _, result in results do
			-- Joins any group a member is already in, so linked changes are stored together.
			local previous = result.session.group
			if previous and not previous.persisted then
				for _, member in previous.sessions do
					if not table.find(group.sessions, member) then
						table.insert(group.sessions, member)
					end
				end
				table.move(previous.stale, 1, #previous.stale, #group.stale + 1, group.stale)
			elseif not table.find(group.sessions, result.session) then
				table.insert(group.sessions, result.session)
			end
		end
		for _, member in group.sessions do
			member.group = group
		end
		task.spawn(function()
			self:save(results[1].session.owner)
		end)
	end
	return true
end

function Store.changed(self: Store, listener: (key: any, data: any, old: any) -> ()): () -> ()
	table.insert(self._listeners, listener)
	return function()
		local index = table.find(self._listeners, listener)
		if index then
			table.remove(self._listeners, index)
		end
	end
end

-- Saving --------------------------------------------------------------------------------------

function Store._lost(self: Store, session: Session)
	if session.status == "lost" then
		return
	end
	session.status = "lost"
	Log.warn(`[HYDROGEN] Data store {self.name}: another server took the lock on {self:_describe(session.owner)}; this server stops saving it`)
	if self._config.onLost then
		task.spawn(self._config.onLost, session.owner)
	end
end

-- Writes one record with the session's current data. Called with the session's mutex held.
function Store._writeOne(self: Store, session: Session): (boolean, string?)
	local backend = session.backend
	local data = session.data
	local version = session.version
	local release = session.releasing
	local once = table.clone(session.once)
	local lost = false

	session.lastAttempt = Time.now()
	local ok, err = self:_request(backend, "update", function()
		return backend:update(self.name, session.key, function(record: Record?)
			if not record or not record.lock or record.lock.id ~= session.lockId then
				lost = true
				return nil
			end
			lost = false
			if (record.version or 0) <= #self._migrations then
				record.version = #self._migrations
				record.compatible = self._compatible
			end
			record.data = data
			record.tx = nil
			record.once = once
			record.lock = if release then nil else { id = session.lockId, time = Clock.now() }
			return record
		end)
	end)

	if lost then
		self:_lost(session)
		return false, "the session lock was lost"
	elseif not ok then
		return false, tostring(err)
	end
	session.savedVersion = math.max(session.savedVersion, version)
	session.lastWrite = Clock.now()
	if release then
		-- The lock is gone, so nothing may write this record again.
		session.status = "closed"
	end
	return true, nil
end

-- Stores every member of a transaction group atomically: a pending marker, each record with
-- the marker's id and its previous data, then removing the marker, which is the commit point.
-- A server that loads a record whose marker still exists uses the previous data instead.
function Store._commitGroup(self: Store, group: Group): (boolean, string?)
	local first = group.sessions[1]
	local backend = first.backend
	local txId = newId()

	local prepared, prepareErr = self:_request(backend, "write", function()
		backend:write(self._txStore, txId, false)
	end)
	if not prepared then
		return false, `couldn't start a transaction: {prepareErr}`
	end

	local snapshots = {}
	for index, session in group.sessions do
		snapshots[index] = { data = session.data, version = session.version, release = session.releasing, once = table.clone(session.once) }
	end

	for index, session in group.sessions do
		local snapshot = snapshots[index]
		local lost = false
		session.lastAttempt = Time.now()
		local ok, err = self:_request(backend, "update", function()
			return backend:update(self.name, session.key, function(record: Record?)
				if not record or not record.lock or record.lock.id ~= session.lockId then
					lost = true
					return nil
				end
				lost = false
				-- A record still holding an unfinished transaction keeps that one's previous data.
				local previous = if record.tx then record.tx.previous else record.data
				record.tx = { id = txId, previous = previous }
				record.data = snapshot.data
				record.once = snapshot.once
				record.lock = { id = session.lockId, time = Clock.now() }
				return record
			end)
		end)
		if lost then
			self:_lost(session)
		end
		if lost or not ok then
			table.insert(group.stale, txId)
			return false, if lost then "the session lock was lost" else tostring(err)
		end
	end

	local committed, commitErr = self:_request(backend, "write", function()
		backend:write(self._txStore, txId, nil)
	end)
	if not committed then
		table.insert(group.stale, txId)
		return false, `couldn't commit a transaction: {commitErr}`
	end

	group.persisted = true
	for index, session in group.sessions do
		session.savedVersion = math.max(session.savedVersion, snapshots[index].version)
		session.lastWrite = Clock.now()
		if session.group == group then
			session.group = nil
		end
	end

	-- Records from failed attempts now point at this transaction, so their markers are garbage.
	for _, stale in group.stale do
		task.spawn(function()
			self:_request(backend, "write", function()
				backend:write(self._txStore, stale, nil)
			end)
		end)
	end
	return true, nil
end

-- Saves the key now and waits for it. Saves already running are joined rather than repeated.
-- Returns whether the data as it was when save was called is stored.
function Store.save(self: Store, key: any): (boolean, string?)
	local session = self:_session(key)
	if not session then
		return false, "not loaded"
	end
	return self:_save(session)
end

function Store._save(self: Store, session: Session): (boolean, string?)
	local target = session.version

	while true do
		if session.status ~= "loaded" then
			return false, `the session is {session.status}`
		end

		local group = session.group
		if group and not group.persisted then
			-- A member whose lock was taken can never be written, which would block the others
			-- forever. Saving them alone risks a duplicated trade; never saving them loses everything.
			local usable = {}
			for _, member in group.sessions do
				if member.status ~= "lost" then
					table.insert(usable, member)
				end
			end
			if #usable < #group.sessions then
				Log.warn(`[HYDROGEN] Data store {self.name}: a transaction member lost its lock; saving the rest without it`)
				group.sessions = usable
				if #usable < 2 then
					group.persisted = true
				end
			end
		end
		if group and group.persisted then
			session.group = nil
			group = nil
		end
		local members = if group then table.clone(group.sessions) else { session }
		-- One order for every caller, so two saves of one group can't deadlock.
		table.sort(members, function(a, b)
			return a.key < b.key
		end)
		for _, member in members do
			acquire(member)
		end

		-- The group may have grown or been stored while this waited.
		if session.group ~= group then
			for _, member in members do
				releaseMutex(member)
			end
			continue
		end

		local ok, err = true, nil
		if group and not group.persisted then
			ok, err = self:_commitGroup(group)
		elseif session.savedVersion < target or session.releasing or session.status ~= "loaded" then
			if session.status == "loaded" then
				ok, err = self:_writeOne(session)
			end
		end

		for _, member in members do
			releaseMutex(member)
		end
		return ok, err
	end
end

-- Saves, releases the lock and forgets the key. Waits for a load still in progress.
function Store.unload(self: Store, key: any)
	local recordKey = self._config.keyOf(key)
	local session = self._sessions[recordKey]
	if not session then
		return
	end
	while session.status == "loading" do
		Time.wait()
	end
	if session.status == "closed" or self._sessions[recordKey] ~= session then
		return
	end

	if session.status == "loaded" then
		-- A pending transaction is stored first; this key can't be released before it is.
		if session.group and not session.group.persisted then
			local ok, err = self:_save(session)
			if not ok then
				Log.warn(`[HYDROGEN] Data store {self.name}: a transaction including {self:_describe(key)} couldn't be saved: {err}`)
			end
		end

		-- A purchase being granted is stored before the lock goes.
		while session.onceRunning > 0 do
			Time.wait()
		end
		session.releasing = true
		local ok, err = self:_save(session)
		if not ok and session.status == "loaded" then
			Log.warn(`[HYDROGEN] Data store {self.name}: couldn't save {self:_describe(key)} on unload, changes since the last save are lost: {err}`)
		end
	end

	session.status = "closed"
	if self._sessions[recordKey] == session then
		self._sessions[recordKey] = nil
	end
end

-- Autosave and shutdown -----------------------------------------------------------------------

-- One thread per store, only while it has sessions. Saves what changed, and refreshes locks
-- before they could look stale to other servers.
function Store._startAutosave(self: Store)
	if self._autosaving then
		return
	end
	self._autosaving = true

	local interval = self._config.autosave or AUTOSAVE
	local lockTimeout = self._config.lockTimeout or LOCK_TIMEOUT
	local tick = math.clamp(interval / 6, 0.01, 15)

	task.spawn(function()
		while next(self._sessions) and not self._closing do
			Clock.wait(tick)
			local now = Time.now()
			for _, session in table.clone(self._sessions) do
				if session.status ~= "loaded" or session.busy or now - session.lastAttempt < interval then
					continue
				end
				local dirty = session.version > session.savedVersion or (session.group ~= nil and not session.group.persisted)
				if dirty or Clock.now() - session.lastWrite >= lockTimeout / 3 then
					session.lastAttempt = now
					task.spawn(function()
						local ok, err = self:_save(session)
						if not ok and session.status == "loaded" then
							Log.warn(`[HYDROGEN] Data store {self.name}: autosave of {self:_describe(session.owner)} failed: {err}`)
						end
					end)
				end
			end
		end
		self._autosaving = false
	end)
end

-- New loads fail fast and retries shorten, to fit in the shutdown window.
function Store.markClosing(self: Store)
	self._closing = true
end

-- Unloads every key and waits for all of them.
function Store.close(self: Store)
	self._closing = true
	local remaining = 0
	for _, session in table.clone(self._sessions) do
		remaining += 1
		task.spawn(function()
			self:unload(session.owner)
			remaining -= 1
		end)
	end
	while remaining > 0 do
		Time.wait()
	end
end

-- After close, so a test can boot the same store again.
function Store.reopen(self: Store)
	self._closing = false
end

-- Waits until the key's load finishes. Returns whether it loaded. For a player whose load
-- hasn't started yet, waits while they're in the game, up to timeout seconds.
function Store.waitForLoad(self: Store, key: any, timeout: number?): boolean
	local recordKey = self._config.keyOf(key)
	local limit = timeout or ((self._config.loadTimeout or LOAD_TIMEOUT) + 30)
	local began = Time.now()
	while Time.now() - began < limit do
		local session = self._sessions[recordKey]
		if session and session.status ~= "loading" then
			return session.status == "loaded" and not session.releasing
		end
		if not session and (type(key) ~= "table" or key.Parent == nil) then
			return false
		end
		Time.wait()
	end
	return false
end

function Store.isLoaded(self: Store, key: any): boolean
	local session = self:_session(key)
	return session ~= nil and session.status == "loaded"
end

function Store.status(self: Store, key: any): Status?
	local session = self:_session(key)
	return if session then session.status else nil
end

function Store.get(self: Store, key: any): any
	local session = self._sessions[self._config.keyOf(key)]
	if not session or session.status == "loading" or session.status == "closed" then
		error(`[HYDROGEN] {self.name}:get: no data loaded for {self:_describe(key)}`, 2)
	end
	return session.data
end

function Store.find(self: Store, key: any): any?
	local session = self._sessions[self._config.keyOf(key)]
	if not session or session.status == "loading" or session.status == "closed" then
		return nil
	end
	return session.data
end

-- A session that failed to load keeps template data so the rest of the join can run; it is
-- never saved.
function Store.placeholder(self: Store, key: any)
	local recordKey = self._config.keyOf(key)
	if self._sessions[recordKey] then
		return
	end
	self._sessions[recordKey] = {
		key = recordKey,
		owner = key,
		status = "failed",
		data = self._template,
		lockId = "",
		backend = self._config.backend(),
		version = 0,
		savedVersion = 0,
		lastAttempt = Time.now(),
		lastWrite = Clock.now(),
		once = {},
		onceVersion = {},
		group = nil,
		busy = false,
		waiting = {},
		releasing = false,
		draft = nil,
		onceRunning = 0,
	}
end

return Store
