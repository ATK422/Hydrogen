--!strict

-- Keys are kept as names ("Space", "ButtonA", "MouseButton1"), so bindings are plain data:
-- cheap to compare, and saved as they are. EnumItems from game code are turned into names here.

export type Device = "keyboard" | "gamepad" | "touch"
export type Kind = "button" | "axis" | "vector2"

-- A binding in the form the engine uses: every key a name, every field checked.
export type Spec = {
	-- The key of a single-key binding.
	key: string?,
	-- Keys that must be held with `key` (button actions). Right-hand keys are stored as left-hand ones.
	modifiers: { string }?,
	up: string?,
	down: string?,
	left: string?,
	right: string?,
	positive: string?,
	negative: string?,
	scale: number,
	-- Which stick axis an axis action reads.
	axis: "x" | "y",
	device: Device,
	-- Every key that drives the binding (not modifiers), so input can be routed by key.
	parts: { string },
	-- The same binding as a string, for equality and change detection.
	id: string,
}

local Keys = {}

-- UserInputTypes that act as keys. Every other key is a KeyCode.
local MOUSE = {
	MouseButton1 = true,
	MouseButton2 = true,
	MouseButton3 = true,
	MouseMovement = true,
	MouseWheel = true,
}

-- Analog keys, by the value they report.
local STICKS = { Thumbstick1 = true, Thumbstick2 = true }
local TRIGGERS = { ButtonL2 = true, ButtonR2 = true }
-- Report movement since the last event rather than a position, so they reset every frame.
local DELTAS = { MouseMovement = "vector2", MouseWheel = "axis" }

-- Either hand satisfies a modifier.
local TWIN = {
	LeftShift = "RightShift",
	RightShift = "LeftShift",
	LeftControl = "RightControl",
	RightControl = "LeftControl",
	LeftAlt = "RightAlt",
	RightAlt = "LeftAlt",
	LeftMeta = "RightMeta",
	RightMeta = "LeftMeta",
	LeftSuper = "RightSuper",
	RightSuper = "LeftSuper",
}

local COMPOSITE_2D = { "up", "down", "left", "right" }
local COMPOSITE_1D = { "positive", "negative" }

local valid: { [string]: boolean } = {}

local function indexKeyCode(name: string): any
	return (Enum.KeyCode :: any)[name]
end

function Keys.isValid(name: string): boolean
	local known = valid[name]
	if known ~= nil then
		return known
	end
	local ok = MOUSE[name] == true or (name ~= "Unknown" and (pcall(indexKeyCode, name)))
	valid[name] = ok
	return ok
end

-- The name of a key given as an EnumItem or a name, or nil if it isn't one.
function Keys.name(key: any): string?
	if type(key) == "string" then
		return if Keys.isValid(key) then key else nil
	end
	if typeof(key) == "EnumItem" then
		local enum, name = string.match(tostring(key), "^Enum%.(%w+)%.(%w+)$")
		if enum == "KeyCode" and name ~= "Unknown" then
			return name
		elseif enum == "UserInputType" and name and MOUSE[name] then
			return name
		end
	end
	return nil
end

-- The EnumItem for a key name: a KeyCode, or a UserInputType for mouse keys.
function Keys.enum(name: string): Enum.KeyCode | Enum.UserInputType
	if MOUSE[name] then
		return (Enum.UserInputType :: any)[name]
	end
	return (Enum.KeyCode :: any)[name]
end

function Keys.device(name: string): Device
	if string.sub(name, 1, 6) == "Button" or string.sub(name, 1, 10) == "Thumbstick" or string.sub(name, 1, 4) == "DPad" then
		return "gamepad"
	end
	return "keyboard"
end

function Keys.isStick(name: string): boolean
	return STICKS[name] == true
end

function Keys.isTrigger(name: string): boolean
	return TRIGGERS[name] == true
end

function Keys.isDelta(name: string): boolean
	return DELTAS[name] ~= nil
end

function Keys.twin(name: string): string?
	return TWIN[name]
end

local function describe(binding: any): string
	if type(binding) == "string" then
		return binding
	elseif typeof(binding) == "EnumItem" then
		return tostring(binding)
	end
	return typeof(binding)
end

-- Checks a binding for an action and returns it as a Spec. Errors with a message that says how
-- to fix the binding; the caller adds where it came from.
function Keys.spec(binding: any, kind: Kind): Spec
	local source: { [string]: any }
	if type(binding) == "table" then
		source = binding
	else
		source = { key = binding }
	end

	local function keyField(field: string): string?
		local value = source[field]
		if value == nil then
			return nil
		end
		local name = Keys.name(value)
		if name == nil then
			error(`{field} = {describe(value)} is not a KeyCode or a mouse UserInputType`, 0)
		end
		return name
	end

	for field in source do
		if
			field ~= "key"
			and field ~= "modifiers"
			and field ~= "scale"
			and field ~= "axis"
			and not table.find(COMPOSITE_2D, field)
			and not table.find(COMPOSITE_1D, field)
		then
			error(`unknown field {field}; a binding has key, modifiers, up/down/left/right, positive/negative, scale and axis`, 0)
		end
	end

	local spec = {
		key = keyField("key"),
		up = keyField("up"),
		down = keyField("down"),
		left = keyField("left"),
		right = keyField("right"),
		positive = keyField("positive"),
		negative = keyField("negative"),
		scale = 1,
		axis = "y",
		parts = {},
		modifiers = nil,
	} :: any

	if source.scale ~= nil then
		if type(source.scale) ~= "number" or source.scale ~= source.scale then
			error(`scale must be a number`, 0)
		end
		spec.scale = source.scale
	end
	if source.axis ~= nil then
		if source.axis ~= "x" and source.axis ~= "y" then
			error(`axis must be "x" or "y"`, 0)
		end
		spec.axis = source.axis
	end

	local is2D = spec.up or spec.down or spec.left or spec.right
	local is1D = spec.positive or spec.negative
	if spec.key and (is2D or is1D) then
		error(`a binding has either key or composite keys (up/down/left/right, positive/negative), not both`, 0)
	elseif is2D and is1D then
		error(`up/down/left/right and positive/negative can't be mixed`, 0)
	elseif not (spec.key or is2D or is1D) then
		error(`no key: bind a KeyCode, a mouse UserInputType, or a table with key or composite keys`, 0)
	end

	if source.modifiers ~= nil then
		if kind ~= "button" or not spec.key then
			error(`modifiers only apply to single-key bindings of button actions`, 0)
		end
		if type(source.modifiers) ~= "table" then
			error(`modifiers must be a list of keys`, 0)
		end
		local modifiers = {}
		for _, modifier in source.modifiers do
			local name = Keys.name(modifier)
			if name == nil then
				error(`modifier {describe(modifier)} is not a KeyCode`, 0)
			end
			-- Stored as the left-hand key; either hand satisfies it.
			if string.sub(name, 1, 5) == "Right" and TWIN[name] then
				name = TWIN[name]
			end
			if not table.find(modifiers, name) then
				table.insert(modifiers, name)
			end
		end
		table.sort(modifiers)
		if #modifiers > 0 then
			spec.modifiers = modifiers
		end
	end

	if spec.key then
		local key = spec.key
		if kind == "button" then
			if STICKS[key] or DELTAS[key] then
				error(`{key} is analog; bind it to an axis or vector2 action`, 0)
			end
		elseif kind == "axis" then
			if key == "MouseMovement" then
				error(`MouseMovement is two-dimensional; bind it to a vector2 action`, 0)
			end
		elseif kind == "vector2" then
			if not (STICKS[key] or key == "MouseMovement") then
				error(`{key} is a single key; a vector2 action binds a thumbstick, MouseMovement, or \{ up, down, left, right }`, 0)
			end
		end
		table.insert(spec.parts, key)
	elseif is2D then
		if kind ~= "vector2" then
			error(`up/down/left/right bind a vector2 action; an axis action uses positive/negative`, 0)
		end
		for _, field in COMPOSITE_2D do
			local key = spec[field]
			if key then
				if STICKS[key] or DELTAS[key] then
					error(`{field} = {key} is analog; composite parts are buttons or keys`, 0)
				end
				table.insert(spec.parts, key)
			end
		end
	else
		if kind ~= "axis" then
			error(`positive/negative bind an axis action; a vector2 action uses up/down/left/right`, 0)
		end
		for _, field in COMPOSITE_1D do
			local key = spec[field]
			if key then
				if STICKS[key] or DELTAS[key] then
					error(`{field} = {key} is analog; composite parts are buttons or keys`, 0)
				end
				table.insert(spec.parts, key)
			end
		end
	end

	local device = Keys.device(spec.parts[1])
	for _, part in spec.parts do
		if Keys.device(part) ~= device then
			error(`it mixes keyboard and gamepad keys; give each device its own binding`, 0)
		end
	end
	if spec.modifiers then
		for _, modifier in spec.modifiers do
			if Keys.device(modifier) ~= device then
				error(`modifier {modifier} is on a different device than {spec.key}`, 0)
			end
		end
	end
	spec.device = device
	spec.id = Keys.id(spec)
	return spec :: Spec
end

function Keys.id(spec: Spec): string
	if spec.key then
		local id = spec.key
		if spec.modifiers then
			id = `{table.concat(spec.modifiers, "+")}+{id}`
		end
		if spec.scale ~= 1 then
			id ..= `*{spec.scale}`
		end
		if spec.axis ~= "y" and Keys.isStick(spec.key) then
			id ..= `:{spec.axis}`
		end
		return id
	end
	local fields: { string } = if spec.positive or spec.negative then COMPOSITE_1D else COMPOSITE_2D
	local parts = {}
	for _, field in fields do
		table.insert(parts, `{field}={(spec :: any)[field] or ""}`)
	end
	local id = `[{table.concat(parts, ",")}]`
	if spec.scale ~= 1 then
		id ..= `*{spec.scale}`
	end
	return id
end

-- The binding as plain data, for saving: names instead of EnumItems.
function Keys.save(spec: Spec): any
	if spec.key and not spec.modifiers and spec.scale == 1 and (spec.axis == "y" or not Keys.isStick(spec.key)) then
		return spec.key
	end
	local saved: { [string]: any } = {}
	for _, field in { "key", "up", "down", "left", "right", "positive", "negative" } do
		saved[field] = (spec :: any)[field]
	end
	if spec.modifiers then
		saved.modifiers = table.clone(spec.modifiers)
	end
	if spec.scale ~= 1 then
		saved.scale = spec.scale
	end
	if spec.key and spec.axis ~= "y" and Keys.isStick(spec.key) then
		saved.axis = spec.axis
	end
	return saved
end

-- The binding as game code writes it: EnumItems.
function Keys.public(spec: Spec): any
	local saved = Keys.save(spec)
	if type(saved) == "string" then
		return Keys.enum(saved)
	end
	for field, value in saved do
		if type(value) == "string" and field ~= "axis" then
			saved[field] = Keys.enum(value)
		end
	end
	if saved.modifiers then
		for index, modifier in saved.modifiers do
			saved.modifiers[index] = Keys.enum(modifier)
		end
	end
	return saved
end

-- Short names for keys whose KeyCode name reads badly in a prompt.
local TEXT: { [string]: string } = {
	LeftShift = "Shift",
	RightShift = "Shift",
	LeftControl = "Ctrl",
	RightControl = "Ctrl",
	LeftAlt = "Alt",
	RightAlt = "Alt",
	Return = "Enter",
	Escape = "Esc",
	Backspace = "Backspace",
	MouseButton1 = "LMB",
	MouseButton2 = "RMB",
	MouseButton3 = "MMB",
	MouseMovement = "Mouse",
	MouseWheel = "Wheel",
	ButtonA = "A",
	ButtonB = "B",
	ButtonX = "X",
	ButtonY = "Y",
	ButtonL1 = "LB",
	ButtonR1 = "RB",
	ButtonL2 = "LT",
	ButtonR2 = "RT",
	ButtonL3 = "LS",
	ButtonR3 = "RS",
	ButtonStart = "Menu",
	ButtonSelect = "View",
	Thumbstick1 = "Left Stick",
	Thumbstick2 = "Right Stick",
	DPadUp = "D-Pad Up",
	DPadDown = "D-Pad Down",
	DPadLeft = "D-Pad Left",
	DPadRight = "D-Pad Right",
	Zero = "0",
	One = "1",
	Two = "2",
	Three = "3",
	Four = "4",
	Five = "5",
	Six = "6",
	Seven = "7",
	Eight = "8",
	Nine = "9",
}

-- A readable name for a key, without asking the engine (which knows the keyboard layout).
function Keys.text(name: string): string
	return TEXT[name] or name
end

return Keys
