local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hydrogen = require(ReplicatedStorage.roblox_packages.hydrogen)

return Hydrogen.define(function()
	local Menu = {}
	function Menu:start()
		local Lazy = require(ReplicatedStorage.Shared.Lazy)
		Lazy.Later:On(function(_n) end)
	end

	return Menu
end)
