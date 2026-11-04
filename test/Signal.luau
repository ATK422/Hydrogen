--!strict

local frktest = require("@pkg/frktest")
local test = frktest.test
local check = frktest.assert.check

local Hydrogen = require("../src")
local Log = require("../src/Log")

local Signal = Hydrogen.Signal
local Clock = Hydrogen.Clock

-- Collects warnings until the returned function is called.
local function captureWarnings(): ({ string }, () -> ())
	local warnings = {}
	local stop = Log.capture(function(message: string)
		table.insert(warnings, message)
		return true
	end)
	return warnings, stop
end

-- Lune has no collectgarbage("collect"): allocate until the collector has run.
local function collected(weak: { [number]: any }): boolean
	for _ = 1, 200 do
		if weak[1] == nil then
			return true
		end
		for _ = 1, 10000 do
			local _garbage = { 1, 2, 3 }
		end
	end
	return weak[1] == nil
end

return function()
	test.on_test_leave(function()
		local fake = Clock.active()
		if fake then
			fake:restore()
		end
	end)

	test.suite("Signal", function()
		test.case("fires listeners in connection order with the arguments", function()
			local Damaged: Hydrogen.Signal<string, number> = Signal.new()
			local calls = {}
			Damaged:Connect(function(name: string, amount: number)
				table.insert(calls, `a:{name}:{amount}`)
			end)
			Damaged:Connect(function(name: string, amount: number)
				table.insert(calls, `b:{name}:{amount}`)
			end)
			Damaged:Fire("Alice", 10)
			check.equal(table.concat(calls, ","), "a:Alice:10,b:Alice:10")
			check.equal(Signal.is(Damaged), true)
			check.equal(Signal.is({}), false)
			return nil
		end)

		test.case("passes nil arguments through", function()
			local signal: Hydrogen.Signal<number?, string?, number?> = Signal.new()
			local got: { n: number, [number]: any }? = nil
			signal:Connect(function(...)
				got = table.pack(...)
			end)
			signal:Fire(nil, "x", nil)
			check.equal((got :: any).n, 3)
			check.equal((got :: any)[2], "x")
			return nil
		end)

		test.case("Disconnect stops a listener and is idempotent", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local count = 0
			local connection = signal:Connect(function()
				count += 1
			end)
			check.equal(connection.Connected, true)
			signal:Fire()
			connection:Disconnect()
			connection:Disconnect()
			check.equal(connection.Connected, false)
			signal:Fire()
			check.equal(count, 1)
			return nil
		end)

		test.case("Once runs once and disconnects first", function()
			local signal: Hydrogen.Signal<number> = Signal.new()
			local seen = {}
			local connection: Hydrogen.Connection = nil :: any
			connection = signal:Once(function(value: number)
				check.equal(connection.Connected, false)
				table.insert(seen, value)
			end)
			signal:Fire(1)
			signal:Fire(2)
			check.equal(#seen, 1)
			check.equal(seen[1], 1)
			return nil
		end)

		test.case("Wait yields until the next Fire and returns its arguments", function()
			local signal: Hydrogen.Signal<string, number> = Signal.new()
			local gotName, gotValue = nil, nil
			task.spawn(function()
				gotName, gotValue = signal:Wait()
			end)
			check.equal(gotName, nil)
			signal:Fire("done", 3)
			check.equal(gotName, "done")
			check.equal(gotValue, 3)
			-- The waiter's connection is gone.
			signal:Fire("again", 4)
			check.equal(gotName, "done")
			return nil
		end)

		test.case("an erroring listener is warned with a traceback and the rest still run", function()
			local warnings, stop = captureWarnings()
			local signal: Hydrogen.Signal<> = Signal.new("Hit")
			local after = 0
			signal:Connect(function()
				error("boom")
			end)
			signal:Connect(function()
				after += 1
			end)
			signal:Fire()
			signal:Fire()
			stop()
			check.equal(after, 2)
			check.equal(#warnings, 2)
			check.equal(string.find(warnings[1], "[HYDROGEN] Listener of signal Hit failed:", 1, true) ~= nil, true)
			check.equal(string.find(warnings[1], "boom", 1, true) ~= nil, true)
			-- The traceback names the test file the listener lives in.
			check.equal(string.find(warnings[1], "Signal", 1, true) ~= nil, true)
			check.equal(select(2, string.gsub(warnings[1], "\n", "")) > 0, true)
			return nil
		end)

		test.case("listeners connected during a Fire hear the next one", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local calls = {}
			signal:Connect(function()
				table.insert(calls, "first")
				signal:Connect(function()
					table.insert(calls, "late")
				end)
			end)
			signal:Fire()
			check.equal(table.concat(calls, ","), "first")
			table.clear(calls)
			signal:Fire()
			check.equal(table.concat(calls, ","), "first,late")
			return nil
		end)

		test.case("listeners disconnected during a Fire are skipped", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local calls = {}
			local second: Hydrogen.Connection = nil :: any
			signal:Connect(function()
				table.insert(calls, "first")
				second:Disconnect()
			end)
			second = signal:Connect(function()
				table.insert(calls, "second")
			end)
			signal:Connect(function()
				table.insert(calls, "third")
			end)
			signal:Fire()
			check.equal(table.concat(calls, ","), "first,third")
			return nil
		end)

		test.case("a listener can disconnect itself without skipping the next", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local calls = {}
			local first: Hydrogen.Connection = nil :: any
			first = signal:Connect(function()
				table.insert(calls, "first")
				first:Disconnect()
			end)
			signal:Connect(function()
				table.insert(calls, "second")
			end)
			signal:Fire()
			signal:Fire()
			check.equal(table.concat(calls, ","), "first,second,second")
			return nil
		end)

		test.case("DisconnectAll during a Fire skips the rest", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local calls = {}
			local second: Hydrogen.Connection = nil :: any
			signal:Connect(function()
				table.insert(calls, "first")
				signal:DisconnectAll()
			end)
			second = signal:Connect(function()
				table.insert(calls, "second")
			end)
			signal:Fire()
			check.equal(table.concat(calls, ","), "first")
			check.equal(second.Connected, false)
			-- Still usable.
			signal:Connect(function()
				table.insert(calls, "new")
			end)
			signal:Fire()
			check.equal(table.concat(calls, ","), "first,new")
			return nil
		end)

		test.case("a nested Fire runs every listener before the outer Fire continues", function()
			local signal: Hydrogen.Signal<number> = Signal.new()
			local calls = {}
			signal:Connect(function(depth: number)
				table.insert(calls, `a{depth}`)
				if depth == 1 then
					signal:Fire(2)
				end
			end)
			signal:Connect(function(depth: number)
				table.insert(calls, `b{depth}`)
			end)
			signal:Fire(1)
			check.equal(table.concat(calls, ","), "a1,a2,b2,b1")
			return nil
		end)

		test.case("a yielding listener doesn't hold up the others or Fire", function()
			local fake = Clock.fake()
			local signal: Hydrogen.Signal<string> = Signal.new()
			local calls = {}
			signal:Connect(function(value: string)
				table.insert(calls, `slow start {value}`)
				Clock.wait(1)
				table.insert(calls, `slow end {value}`)
			end)
			signal:Connect(function(value: string)
				table.insert(calls, `fast {value}`)
			end)
			signal:Connect(function(value: string)
				table.insert(calls, `last {value}`)
			end)

			signal:Fire("x")
			check.equal(table.concat(calls, ","), "slow start x,fast x,last x")

			-- Firing again while the first is still waiting works the same way.
			signal:Fire("y")
			check.equal(#calls, 6)

			fake:advance(1)
			check.equal(calls[7], "slow end x")
			check.equal(calls[8], "slow end y")

			-- And the signal still runs everything in one go afterwards.
			table.clear(calls)
			signal:Fire("z")
			check.equal(table.concat(calls, ","), "slow start z,fast z,last z")
			fake:advance(1)
			check.equal(calls[4], "slow end z")
			return nil
		end)

		test.case("a listener that errors after yielding is still reported", function()
			local fake = Clock.fake()
			local warnings, stop = captureWarnings()
			local signal: Hydrogen.Signal<> = Signal.new()
			signal:Connect(function()
				Clock.wait(1)
				error("late failure")
			end)
			signal:Fire()
			fake:advance(1)
			stop()
			check.equal(#warnings, 1)
			check.equal(string.find(warnings[1], "late failure", 1, true) ~= nil, true)
			return nil
		end)

		test.case("FireDeferred runs after the current thread yields", function()
			local signal: Hydrogen.Signal<number> = Signal.new()
			local got: number? = nil
			signal:Connect(function(value: number)
				got = value
			end)
			signal:FireDeferred(5)
			check.equal(got, nil)
			task.wait()
			check.equal(got, 5)
			return nil
		end)

		test.case("Destroy disconnects everything and makes the signal inert", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local count = 0
			local connection = signal:Connect(function()
				count += 1
			end)
			signal:Destroy()
			check.equal(connection.Connected, false)
			signal:Fire()
			check.equal(count, 0)
			local late = signal:Connect(function()
				count += 1
			end)
			check.equal(late.Connected, false)
			signal:Fire()
			check.equal(count, 0)
			check.should_error(function()
				signal:Wait()
				return nil
			end)
			return nil
		end)

		test.case("Connect rejects a non-function with a [HYDROGEN] error", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local ok, err = pcall(function()
				(signal :: any):Connect(nil)
			end)
			check.equal(ok, false)
			check.equal(string.find(tostring(err), "[HYDROGEN] signal:Connect expects a function, got nil", 1, true) ~= nil, true)
			return nil
		end)

		test.case("connections clean up through a scope", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local count = 0
			local scope = Hydrogen.Scope.new()
			local connection = scope:add(signal:Connect(function()
				count += 1
			end))
			-- scope:connect works with Hydrogen signals at runtime too.
			scope:connect(signal :: any, function()
				count += 1
			end)
			signal:Fire()
			check.equal(count, 2)
			scope:destroy()
			check.equal(connection.Connected, false)
			signal:Fire()
			check.equal(count, 2)
			return nil
		end)

		test.case("a disconnected listener can be garbage collected", function()
			local signal: Hydrogen.Signal<> = Signal.new()
			local weak = setmetatable({}, { __mode = "v" }) :: { [number]: any }
			local connection: Hydrogen.Connection
			do
				local captured = {}
				weak[1] = captured
				connection = signal:Connect(function()
					local _ = captured
				end)
			end
			signal:Fire()
			connection:Disconnect()
			-- The signal and the connection are still alive; the closure isn't held by either.
			check.equal(collected(weak), true)
			check.equal(connection.Connected, false)
			return nil
		end)
	end)
end
