--!strict

-- Hydrogen's warnings go through here, so a test can capture them (Hydrogen.test does).
-- Warnings are rare, so the extra call costs nothing that matters.

-- Returns true to keep the message from reaching the output.
export type Capture = (message: string) -> boolean?

local Log = {
	-- Where warnings go when nothing captures them.
	output = warn :: (message: string) -> (),
}

local captures: { Capture } = {}

-- The newest capture sees a message first.
function Log.warn(message: string)
	for index = #captures, 1, -1 do
		if captures[index](message) then
			return
		end
	end
	Log.output(message)
end

-- Sees every warning until the returned function is called.
function Log.capture(capture: Capture): () -> ()
	table.insert(captures, capture)
	return function()
		local index = table.find(captures, capture)
		if index then
			table.remove(captures, index)
		end
	end
end

return Log
