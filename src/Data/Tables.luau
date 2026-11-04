--!strict

-- Table helpers for profile data. Saved data is plain: no metatables, no cycles.
local Tables = {}

function Tables.copy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local result = {}
	for key, inner in value :: any do
		result[key] = Tables.copy(inner)
	end
	return result :: any
end

-- Freezes every nested table too, so a read-only view can't be changed by accident.
function Tables.freeze<T>(value: T): T
	if type(value) ~= "table" or table.isfrozen(value :: any) then
		return value
	end
	for _, inner in value :: any do
		Tables.freeze(inner)
	end
	table.freeze(value :: any)
	return value
end

function Tables.equal(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in a do
		if not Tables.equal(value, b[key]) then
			return false
		end
	end
	for key in b do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- Fills keys the template has and the data lacks, at every depth where both are tables.
-- Existing values are never replaced, and an empty template table adds nothing.
function Tables.reconcile(data: { [any]: any }, template: { [any]: any })
	for key, default in template do
		local current = data[key]
		if current == nil then
			data[key] = Tables.copy(default)
		elseif type(current) == "table" and type(default) == "table" then
			Tables.reconcile(current, default)
		end
	end
end

-- After an update copied the whole table, keeps the old (frozen) value for every top-level
-- key that didn't change, so unchanged fields keep their identity and only changes are frozen.
-- Returns the keys whose values changed.
function Tables.share(new: { [any]: any }, old: { [any]: any }): { any }
	local changed = {}
	for key, value in new do
		local previous = old[key]
		if previous ~= value and Tables.equal(value, previous) then
			new[key] = previous
		elseif previous ~= value then
			table.insert(changed, key)
		end
	end
	for key in old do
		if new[key] == nil then
			table.insert(changed, key)
		end
	end
	return changed
end

return Tables
