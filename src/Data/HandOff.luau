--!strict

-- Internal, for Hydrogen.Teleport: saves and releases every Data.player store's session for a
-- player before a teleport, and takes them back if the teleport fails. Not part of the public API.

local Store = require("./Store")

type Store = Store.Store

export type Held = {
	player: Player,
	-- Stores whose session this hand-off released.
	stores: { Store },
}

type Entry = {
	onLoadFailed: (player: Player, message: string) -> (),
}

-- Weak keys: a player store that nothing else holds can't have sessions anyway.
local stores: { [Store]: Entry } = setmetatable({}, { __mode = "k" }) :: any

local HandOff = {}

-- Called by Data.player for every player store.
function HandOff.register(store: Store, onLoadFailed: (player: Player, message: string) -> ())
	stores[store] = { onLoadFailed = onLoadFailed }
end

-- Takes back what a hand-off released. A store that can't take its data back (another server
-- holds it, DataStore outage, shutdown) runs its onLoadFailed, which kicks by default: the
-- player must not keep playing on data this server no longer saves.
function HandOff.reclaim(held: Held): (boolean, string?)
	local player = held.player
	local failure: string? = nil
	for _, store in held.stores do
		if store._closing then
			-- Shutting down: the data is saved and released, which is all shutdown would do.
			failure = failure or `{store.name}: the server is shutting down`
			continue
		end
		local ok, err = store:reclaim(player, function()
			return player.Parent == nil
		end)
		if not ok and player.Parent ~= nil then
			failure = failure or `{store.name}: {err}`
			local entry = stores[store]
			if entry then
				task.spawn(entry.onLoadFailed, player, `{store.name} couldn't take {player.Name}'s data back after a failed teleport: {err}`)
			end
		end
	end
	return failure == nil, failure
end

-- Saves and releases every player store's session for the player. If one store fails, the
-- ones already released are taken back and nil is returned with the reason.
function HandOff.release(player: Player): (Held?, string?)
	local held: Held = { player = player, stores = {} }
	for store in stores do
		if store:status(player) == nil then
			continue
		end
		local ok, err = store:handOff(player)
		if not ok then
			HandOff.reclaim(held)
			return nil, `{store.name}: {err}`
		end
		if store:status(player) == "handedOff" then
			table.insert(held.stores, store)
		end
	end
	return held, nil
end

return HandOff
