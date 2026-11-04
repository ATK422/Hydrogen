--!strict

-- What every guard is made of. A guard is an ordinary middleware function, so it goes straight
-- into :Use, :UseRequest or Hydrogen.useMiddleware; its spec (kept in a weak table) is what
-- Guards.all and Guards.any combine. Guards only act on what the server receives from a player:
-- incoming events and function requests. Everything else passes through untouched.

local Clock = require("../Clock")
local Log = require("../Log")
local Middleware = require("../Network/Middleware")

export type Context = Middleware.Context
export type Guard = Middleware.AnyMiddleware
export type RejectHook = (context: Context, reason: string) -> ()

export type GuardOptions = {
	-- Sent to the client instead of the guard's own reason when this guard rejects.
	reason: string?,
	-- Runs for every message this guard rejects, e.g. to log or kick. It may yield; errors are warned.
	onReject: RejectHook?,
}

-- A cooldown as the guard core sees it: how long until this player may use it, and using it.
-- Both are plain arithmetic and never yield, which is what makes a group of them atomic.
export type Usable = {
	_wait: (self: any, player: Player, now: number) -> number,
	_consume: (self: any, player: Player, now: number) -> (),
	_label: (self: any) -> string,
}

-- Returns nil when the message passes, or why it doesn't. A guard made of others (all, any) also
-- returns which of them said so, for its reason option and onReject.
export type Check = (player: Player, context: Context, ...any) -> (string?, Spec?)

export type Spec = {
	check: Check,
	-- Cooldowns used when the guard passes, each once. Every one is checked before any is used.
	uses: { Usable }?,
	options: GuardOptions?,
}

local Guard = {}

-- Middleware function -> its spec. Weak, so guards that were thrown away can be collected.
local specs: { [any]: Spec } = setmetatable({}, { __mode = "k" }) :: any

local hooks: { RejectHook } = {}

local function callHook(hook: RejectHook, context: Context, reason: string)
	local ok, err = xpcall(hook, debug.traceback, context, reason)
	if not ok then
		Log.warn(`[HYDROGEN] Guards onReject failed for {context.name}: {err}`)
	end
end

-- Runs the rejecting guard's onReject and every global hook, each in its own thread so a kick
-- or a yield in one can't hold up the drop.
local function rejected(spec: Spec, context: Context, reason: string)
	local options = spec.options
	local hook = options and options.onReject
	if hook then
		task.spawn(callHook, hook, context, reason)
	end
	if #hooks > 0 then
		for _, global in table.clone(hooks) do
			task.spawn(callHook, global, context, reason)
		end
	end
end

-- The reason a guard gives: its options.reason when set, else what it worked out.
function Guard.reason(spec: Spec, reason: string): string
	local options = spec.options
	return (options and options.reason) or reason
end

-- Checks every cooldown in uses, then uses them all. Nothing in here yields, so two messages
-- can't both take the last charge.
function Guard.take(spec: Spec, uses: { Usable }, player: Player): (string?, Spec?)
	local now = Clock.now()
	for _, usable in uses do
		local wait = usable:_wait(player, now)
		if wait > 0 then
			return Guard.reason(spec, `{usable:_label()} ({string.format("%.1f", wait)}s left)`), spec
		end
	end
	for _, usable in uses do
		usable:_consume(player, now)
	end
	return nil, nil
end

-- Runs a spec's checks only, and says which guard rejected: the one that gave the reason.
function Guard.check(spec: Spec, player: Player, context: Context, ...: any): (string?, Spec?)
	local reason, failed = spec.check(player, context, ...)
	if reason == nil then
		return nil, nil
	elseif failed == nil then
		return Guard.reason(spec, reason), spec
	end
	return reason, failed
end

-- Runs a spec as a whole guard would: its checks, then its cooldowns.
function Guard.evaluate(spec: Spec, player: Player, context: Context, ...: any): (string?, Spec?)
	local reason, failed = Guard.check(spec, player, context, ...)
	if reason == nil then
		local uses = spec.uses
		if uses then
			return Guard.take(spec, uses, player)
		end
	end
	return reason, failed
end

function Guard.build(spec: Spec): Guard
	local function guard(context: Context, ...: any): ...any
		local player = context.player
		if player == nil or context.direction ~= "incoming" or context.payload == "response" then
			return ...
		end

		local reason, failed = Guard.evaluate(spec, player, context, ...)
		if reason == nil then
			return ...
		end

		rejected(failed or spec, context, reason)
		if context.payload == "request" then
			-- The caller is waiting for an answer, so it gets the reason instead.
			error(`[HYDROGEN] {context.name} request rejected: {reason}`, 0)
		end
		return Middleware.DROP
	end

	specs[guard] = spec
	return guard
end

-- The spec behind a guard, or an error that says what was passed instead.
function Guard.spec(value: any, caller: string, index: number): Spec
	local spec = if type(value) == "function" then specs[value] else nil
	if not spec then
		error(
			`[HYDROGEN] {caller} expects guards made by Hydrogen.Guards (Guards.role, Guards.check, cooldown:guard(), ...); argument {index} is a {typeof(value)}. Wrap your own logic in Guards.check(fn)`,
			3
		)
	end
	return spec
end

function Guard.isGuard(value: any): boolean
	return type(value) == "function" and specs[value] ~= nil
end

function Guard.onReject(hook: RejectHook): () -> ()
	if type(hook) ~= "function" then
		error(`[HYDROGEN] Guards.onReject expects a function, got {typeof(hook)}`, 2)
	end
	return Middleware.add(hooks, hook)
end

return Guard
