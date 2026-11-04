--!strict

-- Distances from a player's character to a target, for range checks. The target usually comes
-- straight from a client, so anything that isn't a position or a placed Instance is rejected.

local Log = require("../Log")
local Runtime = require("../Network/Runtime")

local Range = {
	-- Where a player's character is. Replace with Guards.configure({ position = ... }).
	position = nil :: ((player: Player) -> Vector3?)?,
	-- Extra studs every range check allows, for latency: 4 is a quarter second at the default WalkSpeed.
	slack = 4,
}

local function characterPosition(player: Player): Vector3?
	local character = player.Character
	if typeof(character) ~= "Instance" then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	local primary = (character :: Model).PrimaryPart
	if primary then
		return primary.Position
	end
	return nil
end

-- Where the player's character is, or nil without one.
function Range.of(player: Player): Vector3?
	local position = Range.position
	if position then
		local ok, result = xpcall(position, debug.traceback, player)
		if not ok then
			Log.warn(`[HYDROGEN] Guards position function failed; treating the player as having no character: {result}`)
			return nil
		end
		return if typeof(result) == "Vector3" then result else nil
	end
	return characterPosition(player)
end

local function instancePosition(value: Instance): Vector3?
	if value:IsA("BasePart") then
		return (value :: BasePart).Position
	elseif value:IsA("Model") then
		return (value :: Model):GetPivot().Position
	elseif value:IsA("Attachment") then
		return (value :: Attachment).WorldPosition
	end
	return nil
end

local function finite(position: Vector3): boolean
	local x, y, z = position.X, position.Y, position.Z
	-- NaN fails every comparison, and math.huge fails the bound.
	return x > -math.huge and x < math.huge and y > -math.huge and y < math.huge and z > -math.huge and z < math.huge
end

-- Where a target is: a Vector3, a CFrame, a BasePart, a Model, an Attachment or a player (their
-- character). nil for anything else, including NaN or infinite positions an exploiter could send.
function Range.target(value: any): Vector3?
	local kind = typeof(value)
	local position: Vector3? = nil
	if kind == "Vector3" then
		position = value
	elseif kind == "CFrame" then
		position = value.Position
	elseif kind == "Instance" then
		if value:IsA("Player") then
			position = Range.of(value)
		else
			-- Protected: a client can name any Instance, including ones mid-destroy.
			local ok, result = pcall(instancePosition, value)
			position = if ok then result else nil
		end
	elseif Runtime:isPlayer(value) then
		-- A loopback's fake player.
		position = Range.of(value)
	end
	if position and finite(position) then
		return position
	end
	return nil
end

-- Studs from the player's character to the target, or nil and why not.
function Range.distance(player: Player, target: any): (number?, string?)
	local from = Range.of(player)
	if not from then
		return nil, "no character"
	end
	local to = Range.target(target)
	if not to then
		return nil, "invalid target"
	end
	return (to - from).Magnitude, nil
end

return Range
