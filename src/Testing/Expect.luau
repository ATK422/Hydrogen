--!strict

-- Expectations on what a network object delivered during a test. A failed expectation
-- errors, so it works in any test framework (frktest, TestEZ, Jest-Lua) or none.

local Middleware = require("../Network/Middleware")

type Packed = { [number]: any, n: number }

-- One message the test saw arrive: what the receiving listeners or handler got.
export type Delivery = {
	name: string,
	kind: Middleware.Kind,
	-- The client that received a server event or answered a server function, or the
	-- client that sent a client event or called a client function.
	player: Player?,
	args: Packed,
	-- For functions: what the handler returned, nil if it errored or is still running.
	returns: Packed?,
}

export type Expectation = {
	-- Events. Pass arguments to also check them; t.any matches any one value.
	-- Delivered at least once, to or from anyone.
	fired: (self: Expectation, ...any) -> Expectation,
	-- A server event delivered to player.
	firedTo: (self: Expectation, player: Player, ...any) -> Expectation,
	-- A client event the server received from player.
	firedBy: (self: Expectation, player: Player, ...any) -> Expectation,
	-- Never delivered (to or from player, if given).
	notFired: (self: Expectation, player: Player?) -> Expectation,
	-- Delivered exactly count times. FireAll to three clients counts three.
	firedTimes: (self: Expectation, count: number) -> Expectation,

	-- Functions.
	-- The handler ran with these arguments (or with any, if none are given).
	called: (self: Expectation, ...any) -> Expectation,
	-- A client function called by player, or a server function answered by player.
	calledBy: (self: Expectation, player: Player, ...any) -> Expectation,
	-- Some call returned exactly these values.
	returned: (self: Expectation, ...any) -> Expectation,
	notCalled: (self: Expectation) -> Expectation,
	calledTimes: (self: Expectation, count: number) -> Expectation,

	-- Every delivery so far, oldest first, for checks of your own.
	deliveries: (self: Expectation) -> { Delivery },
}

type Source = {
	name: string,
	kind: Middleware.Kind,
	deliveries: () -> { Delivery },
	isPlayer: (value: any) -> boolean,
}

-- Matches any one value in an expected argument list.
local ANY = table.freeze({})

local Expect = {
	ANY = ANY,
}

local LABELS: { [Middleware.Kind]: string } = {
	ClientEvent = "clientEvent",
	ServerEvent = "serverEvent",
	ClientFunction = "clientFunction",
	ServerFunction = "serverFunction",
}

-- Copies tables so later changes by listeners don't change what was recorded. Players and
-- other references a remote passes as-is are kept.
function Expect.copy(value: any, isPlayer: (any) -> boolean, seen: { [any]: any }?): any
	if type(value) ~= "table" or isPlayer(value) or value == ANY then
		return value
	end
	local visited = seen or {}
	if visited[value] then
		return visited[value]
	end
	local result = {}
	visited[value] = result
	for key, inner in next, value do
		result[Expect.copy(key, isPlayer, visited)] = Expect.copy(inner, isPlayer, visited)
	end
	return result
end

function Expect.copyArgs(args: Packed, isPlayer: (any) -> boolean): Packed
	local seen = {}
	local result = { n = args.n } :: Packed
	for index = 1, args.n do
		result[index] = Expect.copy(args[index], isPlayer, seen)
	end
	return result
end

local function equal(expected: any, actual: any, isPlayer: (any) -> boolean, seen: { [any]: any }): boolean
	if expected == ANY or rawequal(expected, actual) then
		return true
	end
	-- Values such as Vector3 and CFrame are userdata compared by value (__eq), not by reference.
	if type(expected) == "userdata" and typeof(expected) == typeof(actual) and expected == actual then
		return true
	end
	if type(expected) ~= "table" or type(actual) ~= "table" or isPlayer(expected) or isPlayer(actual) then
		-- NaN never equals itself, but an expected NaN should match a NaN.
		return expected ~= expected and actual ~= actual
	end
	if seen[expected] == actual then
		return true
	end
	seen[expected] = actual

	for key, inner in next, expected do
		if not equal(inner, rawget(actual, key), isPlayer, seen) then
			return false
		end
	end
	for key in next, actual do
		if rawget(expected, key) == nil then
			return false
		end
	end
	return true
end

local function matches(expected: Packed, actual: Packed, isPlayer: (any) -> boolean): boolean
	if expected.n ~= actual.n then
		return false
	end
	local seen = {}
	for index = 1, expected.n do
		if not equal(expected[index], actual[index], isPlayer, seen) then
			return false
		end
	end
	return true
end

local function describeValue(value: any, isPlayer: (any) -> boolean): string
	if value == ANY then
		return "any"
	elseif type(value) == "table" and isPlayer(value) then
		return (value :: any).Name
	end
	return Middleware.format(value)
end

function Expect.describeArgs(args: Packed, isPlayer: (any) -> boolean): string
	local parts = {}
	for index = 1, args.n do
		table.insert(parts, describeValue(args[index], isPlayer))
	end
	return `({table.concat(parts, ", ")})`
end

local function describeDelivery(delivery: Delivery, isPlayer: (any) -> boolean): string
	local args = Expect.describeArgs(delivery.args, isPlayer)
	local who = if delivery.player then (delivery.player :: any).Name else "?"
	local kind = delivery.kind

	if kind == "ServerEvent" then
		return `to {who}: {args}`
	elseif kind == "ClientEvent" then
		return `from {who}: {args}`
	end

	local returns = delivery.returns
	local result = if returns then Expect.describeArgs(returns, isPlayer) else "(errored)"
	local preposition = if kind == "ClientFunction" then "by" else "answered by"
	return `{preposition} {who}: {args} -> {result}`
end

local function times(count: number): string
	return if count == 1 then "1 time" else `{count} times`
end

-- "never fired" or "fired 2 times:" followed by each delivery.
local function describeHistory(source: Source, verb: string, list: { Delivery }): string
	if #list == 0 then
		return `it was never {verb}`
	end
	local lines = { `it was {verb} {times(#list)}:` }
	for _, delivery in list do
		table.insert(lines, `  {describeDelivery(delivery, source.isPlayer)}`)
	end
	return table.concat(lines, "\n")
end

local function withArgs(source: Source, expected: Packed): string
	if expected.n == 0 then
		return ""
	end
	return ` with {Expect.describeArgs(expected, source.isPlayer)}`
end

function Expect.new(source: Source): Expectation
	local name = source.name
	local isEvent = source.kind == "ClientEvent" or source.kind == "ServerEvent"
	local label = LABELS[source.kind]

	local expectation = {} :: Expectation

	-- Errors pointing at the test line that called the expectation method.
	local function fail(message: string): never
		error(`[HYDROGEN] {message}`, 3)
	end

	local function requireKind(method: string, wanted: Middleware.Kind?, events: boolean)
		if wanted and source.kind ~= wanted then
			local hint = if wanted == "ServerEvent" then "firedBy" else "firedTo"
			if source.kind == "ClientFunction" or source.kind == "ServerFunction" then
				hint = "calledBy"
			end
			error(`[HYDROGEN] {method} is for {LABELS[wanted]}s; {name} is a {label}, use {hint}`, 3)
		end
		if events ~= isEvent then
			local alternative = if events then "called, calledBy, returned or notCalled" else "fired, firedTo, firedBy or notFired"
			error(`[HYDROGEN] {method} is for {if events then "events" else "functions"}; {name} is a {label}, use {alternative}`, 3)
		end
	end

	-- A nil player would match every delivery, so a typo'd player must not pass silently.
	local function requirePlayer(method: string, player: any)
		if player == nil or not source.isPlayer(player) then
			error(`[HYDROGEN] {method} expects a player from the test (t:join, t:player or the test function's arguments), got {typeof(player)}`, 3)
		end
	end

	local function find(player: Player?, expected: Packed?): Delivery?
		for _, delivery in source.deliveries() do
			if player ~= nil and delivery.player ~= player then
				continue
			end
			if expected and expected.n > 0 and not matches(expected, delivery.args, source.isPlayer) then
				continue
			end
			return delivery
		end
		return nil
	end

	local function filtered(player: Player?): { Delivery }
		if player == nil then
			return source.deliveries()
		end
		local list = {}
		for _, delivery in source.deliveries() do
			if delivery.player == player then
				table.insert(list, delivery)
			end
		end
		return list
	end

	function expectation:fired(...: any): Expectation
		requireKind("fired", nil, true)
		local expected = table.pack(...) :: Packed
		if not find(nil, expected) then
			fail(`Expected {name} to be fired{withArgs(source, expected)}, but {describeHistory(source, "fired", source.deliveries())}`)
		end
		return self
	end

	function expectation:firedTo(player: Player, ...: any): Expectation
		requireKind("firedTo", "ServerEvent", true)
		requirePlayer("firedTo", player)
		local expected = table.pack(...) :: Packed
		if not find(player, expected) then
			fail(`Expected {name} to be fired to {describeValue(player, source.isPlayer)}{withArgs(source, expected)}, but {describeHistory(source, "fired", source.deliveries())}`)
		end
		return self
	end

	function expectation:firedBy(player: Player, ...: any): Expectation
		requireKind("firedBy", "ClientEvent", true)
		requirePlayer("firedBy", player)
		local expected = table.pack(...) :: Packed
		if not find(player, expected) then
			fail(`Expected {name} to be fired by {describeValue(player, source.isPlayer)}{withArgs(source, expected)}, but {describeHistory(source, "fired", source.deliveries())}`)
		end
		return self
	end

	function expectation:notFired(player: Player?): Expectation
		requireKind("notFired", nil, true)
		if player ~= nil then
			requirePlayer("notFired", player)
		end
		local list = filtered(player)
		if #list > 0 then
			local target = if player == nil
				then ""
				elseif source.kind == "ServerEvent" then ` to {describeValue(player, source.isPlayer)}`
				else ` by {describeValue(player, source.isPlayer)}`
			fail(`Expected {name} not to be fired{target}, but {describeHistory(source, "fired", list)}`)
		end
		return self
	end

	function expectation:firedTimes(count: number): Expectation
		requireKind("firedTimes", nil, true)
		local list = source.deliveries()
		if #list ~= count then
			fail(`Expected {name} to be fired {times(count)}, but {describeHistory(source, "fired", list)}`)
		end
		return self
	end

	function expectation:called(...: any): Expectation
		requireKind("called", nil, false)
		local expected = table.pack(...) :: Packed
		if not find(nil, expected) then
			fail(`Expected {name} to be called{withArgs(source, expected)}, but {describeHistory(source, "called", source.deliveries())}`)
		end
		return self
	end

	function expectation:calledBy(player: Player, ...: any): Expectation
		requireKind("calledBy", nil, false)
		requirePlayer("calledBy", player)
		local expected = table.pack(...) :: Packed
		if not find(player, expected) then
			local verb = if source.kind == "ClientFunction" then "called by" else "answered by"
			fail(`Expected {name} to be {verb} {describeValue(player, source.isPlayer)}{withArgs(source, expected)}, but {describeHistory(source, "called", source.deliveries())}`)
		end
		return self
	end

	function expectation:returned(...: any): Expectation
		requireKind("returned", nil, false)
		local expected = table.pack(...) :: Packed
		local found = false
		for _, delivery in source.deliveries() do
			local returns = delivery.returns
			if returns and matches(expected, returns, source.isPlayer) then
				found = true
				break
			end
		end
		if not found then
			fail(`Expected {name} to return {Expect.describeArgs(expected, source.isPlayer)}, but {describeHistory(source, "called", source.deliveries())}`)
		end
		return self
	end

	function expectation:notCalled(): Expectation
		requireKind("notCalled", nil, false)
		local list = source.deliveries()
		if #list > 0 then
			fail(`Expected {name} not to be called, but {describeHistory(source, "called", list)}`)
		end
		return self
	end

	function expectation:calledTimes(count: number): Expectation
		requireKind("calledTimes", nil, false)
		local list = source.deliveries()
		if #list ~= count then
			fail(`Expected {name} to be called {times(count)}, but {describeHistory(source, "called", list)}`)
		end
		return self
	end

	function expectation:deliveries(): { Delivery }
		return table.clone(source.deliveries())
	end

	return expectation
end

-- Every delivery, for a failure message that says what did happen.
function Expect.describeAll(list: { Delivery }, isPlayer: (any) -> boolean): string
	local lines = {}
	for _, delivery in list do
		table.insert(lines, `  {delivery.name} {describeDelivery(delivery, isPlayer)}`)
	end
	return table.concat(lines, "\n")
end

return Expect
