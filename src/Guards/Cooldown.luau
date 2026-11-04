--!strict

-- Per-player cooldowns with charges. Each player costs one number per cooldown (two with a gap):
-- the time their charges are all back. Charges come back one at a time, every `seconds`.

local Clock = require("../Clock")
local Guard = require("./Guard")
local Leave = require("./Leave")

export type CooldownOptions = {
	-- Shown in reasons and warnings, e.g. "Fireball".
	name: string?,
	-- Uses that can be stored up; each comes back `seconds` after it's used. Defaults to 1.
	charges: number?,
	-- Smallest time between two uses, even with charges left. Defaults to 0.
	gap: number?,
	-- Other cooldowns this one also needs ready and also uses: a shared group or a global cooldown.
	group: { Cooldown }?,
}

export type Cooldown = {
	read name: string?,
	read seconds: number,
	read maxCharges: number,
	read gap: number,

	-- Whether the player can use it now (this cooldown and its group).
	ready: (self: Cooldown, player: Player) -> boolean,
	-- Uses it if ready and returns true; otherwise changes nothing and returns false.
	use: (self: Cooldown, player: Player) -> boolean,
	-- Seconds until the player can use it, or 0 when ready.
	remaining: (self: Cooldown, player: Player) -> number,
	-- Charges the player has now (this cooldown only, not its group).
	charges: (self: Cooldown, player: Player) -> number,
	-- Gives the player (or everyone, without one) every charge back.
	reset: (self: Cooldown, player: Player?) -> (),
	-- A middleware that drops a player's message unless the cooldown is ready, and uses it when the message passes.
	guard: (self: Cooldown, options: Guard.GuardOptions?) -> Guard.Guard,
}

type Internal = Cooldown & {
	_full: { [Player]: number },
	_last: { [Player]: number }?,
	-- Seconds of recharge a player can owe at most: seconds * charges.
	_total: number,
	-- This cooldown and its whole group, each once.
	_closure: { Internal },
	_wait: (self: Internal, player: Player, now: number) -> number,
	_consume: (self: Internal, player: Player, now: number) -> (),
	_label: (self: Internal) -> string,
}

-- Float error from adding seconds up must not leave a charge a hair short.
local EPSILON = 1e-6

local Methods = {}
local metatable = { __index = Methods }

-- Every cooldown, so a player's state can be cleared when they leave. Weak for cooldowns made in tests.
local live: { [Internal]: true } = setmetatable({}, { __mode = "k" }) :: any

Leave.on(function(player: Player)
	for cooldown in live do
		cooldown._full[player] = nil
		local last = cooldown._last
		if last then
			last[player] = nil
		end
	end
end)

-- Charges still recharging. Clears state that ran out, or that was written under another clock
-- (a test's fake clock came or went), which would otherwise never run out.
local function owed(self: Internal, player: Player, now: number): number
	local full = self._full[player]
	if full == nil then
		return 0
	end
	local pending = full - now
	if pending <= EPSILON or pending > self._total + EPSILON then
		self._full[player] = nil
		return 0
	end
	return math.ceil(pending / self.seconds - EPSILON)
end

-- Seconds until this cooldown alone is ready: the next charge, and the gap.
function Methods._wait(self: Internal, player: Player, now: number): number
	local wait = 0
	if owed(self, player, now) >= self.maxCharges then
		wait = (self._full[player] - now) - (self.maxCharges - 1) * self.seconds
	end

	local lastUses = self._last
	local last = lastUses and lastUses[player]
	if lastUses and last then
		local since = now - last
		if since < 0 or since >= self.gap - EPSILON then
			lastUses[player] = nil
		elseif self.gap - since > wait then
			wait = self.gap - since
		end
	end

	return wait
end

function Methods._consume(self: Internal, player: Player, now: number)
	if Leave.gone(player) then
		return
	end
	Leave.track()

	local full = self._full[player]
	self._full[player] = (if full and full > now then full else now) + self.seconds
	local lastUses = self._last
	if lastUses then
		lastUses[player] = now
	end
end

function Methods._label(self: Internal): string
	return if self.name then `{self.name} is on cooldown` else "on cooldown"
end

function Methods.remaining(self: Internal, player: Player): number
	local now = Clock.now()
	local wait = 0
	for _, cooldown in self._closure do
		local each = cooldown:_wait(player, now)
		if each > wait then
			wait = each
		end
	end
	return wait
end

function Methods.ready(self: Internal, player: Player): boolean
	return self:remaining(player) <= 0
end

function Methods.use(self: Internal, player: Player): boolean
	local now = Clock.now()
	for _, cooldown in self._closure do
		if cooldown:_wait(player, now) > 0 then
			return false
		end
	end
	for _, cooldown in self._closure do
		cooldown:_consume(player, now)
	end
	return true
end

function Methods.charges(self: Internal, player: Player): number
	return self.maxCharges - math.min(owed(self, player, Clock.now()), self.maxCharges)
end

function Methods.reset(self: Internal, player: Player?)
	local lastUses = self._last
	if player == nil then
		table.clear(self._full)
		if lastUses then
			table.clear(lastUses)
		end
		return
	end
	self._full[player] = nil
	if lastUses then
		lastUses[player] = nil
	end
end

function Methods.guard(self: Internal, options: Guard.GuardOptions?): Guard.Guard
	return Guard.build({
		-- Only looks; the guard core uses the cooldown once every other check passed.
		check = function(player: Player): (string?, Guard.Spec?)
			local wait = self:remaining(player)
			if wait > 0 then
				return `{self:_label()} ({string.format("%.1f", wait)}s left)`, nil
			end
			return nil, nil
		end,
		uses = self._closure :: { any },
		options = options,
	})
end

local Cooldown = {}

function Cooldown.is(value: any): boolean
	return type(value) == "table" and live[value] == true
end

function Cooldown.new(seconds: number, options: CooldownOptions?): Cooldown
	if type(seconds) ~= "number" or not (seconds > 0) or seconds == math.huge then
		error(`[HYDROGEN] Guards.cooldown expects a positive number of seconds, got {tostring(seconds)}`, 3)
	end

	local name = options and options.name
	local charges = (options and options.charges) or 1
	local gap = (options and options.gap) or 0
	local group = (options and options.group) or {}

	if type(charges) ~= "number" or charges < 1 or charges % 1 ~= 0 then
		error(`[HYDROGEN] Guards.cooldown charges must be a whole number of at least 1, got {tostring(charges)}`, 3)
	end
	if type(gap) ~= "number" or not (gap >= 0) or gap == math.huge then
		error(`[HYDROGEN] Guards.cooldown gap must be a non-negative number of seconds, got {tostring(gap)}`, 3)
	end
	if name ~= nil and type(name) ~= "string" then
		error(`[HYDROGEN] Guards.cooldown name must be a string, got {typeof(name)}`, 3)
	end

	local self = setmetatable({
		name = name,
		seconds = seconds,
		maxCharges = charges,
		gap = gap,
		_full = setmetatable({}, { __mode = "k" }),
		_last = if gap > 0 then setmetatable({}, { __mode = "k" }) else nil,
		_total = seconds * charges,
		_closure = {},
	}, metatable) :: any

	-- The group is fixed here, so a cycle can't form and the closure is worked out once.
	local closure: { Internal } = { self }
	local seen: { [any]: boolean } = { [self] = true }
	for index, member in group do
		if not Cooldown.is(member) then
			error(`[HYDROGEN] Guards.cooldown group must hold cooldowns made by Guards.cooldown; entry {index} is a {typeof(member)}`, 3)
		end
		for _, each in (member :: Internal)._closure do
			if not seen[each] then
				seen[each] = true
				table.insert(closure, each)
			end
		end
	end
	self._closure = closure

	live[self] = true
	return self :: Cooldown
end

return Cooldown
