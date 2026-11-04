--!strict

-- Required the Roblox way, through script, and defined without an id: under the Lune runtime
-- the id still comes from the module's name, as in Studio.
local Hydrogen = require(script.Parent.Parent.Parent.src)

return Hydrogen.define(function()
	return {
		hydrogen = Hydrogen,
	}
end)
