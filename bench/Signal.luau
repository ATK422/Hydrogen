-- Signal.Fire against a plain table of callbacks. Run: lune run bench/Signal
-- Lune resumes threads far slower than Roblox does, so absolute numbers here are pessimistic.
local Lune = require("../src/Testing/Lune")
Lune.install()
local Signal = Lune.require("../src/Signal")

local FIRES = 200000
local sink = 0
local function listener(a: number, _b: string)
	sink += a
end

local function measure(label: string, listeners: number, run: () -> ())
	local started = os.clock()
	run()
	local elapsed = os.clock() - started
	print(string.format("%-26s %3d listener(s): %7.0f ns/Fire  %6.0f ns/listener", label, listeners, elapsed / FIRES * 1e9, elapsed / FIRES / listeners * 1e9))
end

for _, listeners in { 1, 5, 20 } do
	local plain = {}
	for _ = 1, listeners do
		table.insert(plain, listener)
	end
	measure("plain table", listeners, function()
		for i = 1, FIRES do
			for _, callback in plain do
				callback(i, "x")
			end
		end
	end)

	measure("plain table + xpcall", listeners, function()
		for i = 1, FIRES do
			for _, callback in plain do
				xpcall(callback, debug.traceback, i, "x")
			end
		end
	end)

	local signal = Signal.new()
	for _ = 1, listeners do
		signal:Connect(listener)
	end
	measure("Hydrogen.Signal", listeners, function()
		for i = 1, FIRES do
			signal:Fire(i, "x")
		end
	end)
end

local started = os.clock()
local signal = Signal.new()
for _ = 1, FIRES do
	signal:Connect(listener):Disconnect()
end
print(string.format("Connect + Disconnect: %.0f ns", (os.clock() - started) / FIRES * 1e9))
