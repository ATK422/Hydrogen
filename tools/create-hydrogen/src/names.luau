--!strict

-- Name rules. Pure functions, so the tests can cover them without touching the disk.

local Names = {}

local WINDOWS_RESERVED = {
	con = true,
	prn = true,
	aux = true,
	nul = true,
}
for i = 1, 9 do
	WINDOWS_RESERVED[`com{i}`] = true
	WINDOWS_RESERVED[`lpt{i}`] = true
end

-- A project name becomes a folder name, the Rojo project name and the default package name, so
-- it has to be a valid folder name on Windows, macOS and Linux.
function Names.validateProject(name: string): (boolean, string?)
	if name == "" then
		return false, "the project name can't be empty"
	end
	if #name > 64 then
		return false, "the project name can be at most 64 characters"
	end
	if not string.match(name, "^[%w%.%-_]+$") then
		return false, "use only letters, digits, '-', '_' and '.' (no spaces)"
	end
	if not string.match(name, "^%w") then
		return false, "the project name must start with a letter or a digit"
	end
	if string.sub(name, -1) == "." then
		return false, "the project name can't end with '.'"
	end
	local stem = string.lower(string.match(name, "^[^%.]*") :: string)
	if WINDOWS_RESERVED[stem] then
		return false, `'{name}' is a reserved name on Windows`
	end
	return true, nil
end

-- pesde's rules: scope/name, a-z 0-9 and _, the scope 3-32 characters, the name 1-32, neither
-- all digits nor starting or ending with _.
function Names.validatePackage(full: string): (boolean, string?)
	local scope, name = string.match(full, "^([^/]*)/([^/]*)$")
	if not scope or not name then
		return false, "a pesde package name looks like scope/name"
	end
	for _, part in { { "scope", scope, 3 }, { "name", name, 1 } } do
		local label, value, minLength = part[1] :: string, part[2] :: string, part[3] :: number
		if #value < minLength or #value > 32 then
			return false, `the package {label} must be {minLength}-32 characters`
		end
		if not string.match(value, "^[a-z0-9_]+$") then
			return false, `the package {label} can only use a-z, 0-9 and _`
		end
		if string.match(value, "^%d+$") then
			return false, `the package {label} can't be only digits`
		end
		if string.sub(value, 1, 1) == "_" or string.sub(value, -1) == "_" then
			return false, `the package {label} can't start or end with _`
		end
	end
	return true, nil
end

-- "My-Cool.Game" -> "my_cool_game", or nil if nothing usable is left.
function Names.slug(text: string, maxLength: number?): string?
	local slug = string.lower(text)
	slug = string.gsub(slug, "[^a-z0-9]+", "_")
	slug = string.gsub(slug, "^_+", "")
	slug = string.gsub(slug, "_+$", "")
	slug = string.sub(slug, 1, maxLength or 32)
	slug = string.gsub(slug, "_+$", "")
	if slug == "" or string.match(slug, "^%d+$") then
		return nil
	end
	return slug
end

-- The default package name: the author's slug as the scope (when it's long enough), and the
-- project's slug as the name.
function Names.defaultPackage(project: string, author: string?): string
	local scope = author and Names.slug(author)
	if not scope or #scope < 3 then
		scope = "game"
	end
	local name = Names.slug(project) or "game"
	return `{scope}/{name}`
end

-- The last part of a path, ignoring trailing slashes.
function Names.basename(path: string): string
	path = string.gsub(path, "[/\\]+$", "")
	return string.match(path, "[^/\\]+$") or path
end

return Names
