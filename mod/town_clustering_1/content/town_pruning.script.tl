--- Town Clustering - prune generated towns into clusters.
---
--- The engine places towns uniformly during map generation and there is no way
--- to influence that from the new game dialog (see NOTES.md - no mod code runs
--- in the menu, and a terrain generator can only shape terrain). So instead we
--- let generation finish untouched and remove towns afterwards, on the first
--- tick of a new game.
---
--- Pruning rather than relocating is deliberate:
---   * terrain, rivers and industries are left exactly as the stock generator
---     made them - no artificial roughening, which is what sank the earlier
---     terrain-based approach
---   * surviving towns sit on positions the engine already judged valid
---   * clusters can be as tight as the engine's own spacing, because the
---     one-town-per-5km2 cap applies to generation, not to our selection
---
--- The mod only needs to be active when the game starts; afterwards it does
--- nothing and can safely be removed from the savegame.

local entity_util = ug_require "::/scripts/entity_util.tl" as EntityUtil

local LOG <const> = "[town-clustering] "
local MOD_ID <const> = "town_clustering_1"

--- Slider index (1-based) to value. Index 0 or missing falls back to DEFAULT.
local CLUSTER_COUNTS <const> = { 2, 3, 4, 5, 6, 8 }
local KEEP_FRACTIONS <const> = { 0.30, 0.45, 0.60, 0.75, 1.00 }
local ISOLATED_SHARES <const> = { 0.0, 0.05, 0.10, 0.20 }

--- Isolated towns are scaled to this share of their generated size. They are
--- meant to read as hamlets left behind by the clustering, not as peers of the
--- towns in the conurbations.
local ISOLATED_SIZE_SCALE <const> = 0.45

--- Only prune a genuinely fresh game. Adding this mod to an established save
--- and silently deleting half its towns would be catastrophic, so bail out if
--- any meaningful time has passed.
local MAX_START_GAME_TIME <const> = 60 * 60 * 24 * 10

local record Town
	entity : Engine.Entity
	x : number
	y : number
	--- distance to the nearest chosen cluster centre
	dist : number
end

local record State
	--- 0/nil = not started, 1 = towns pruned and awaiting the road rebuild,
	--- 2 = finished. The rebuild has to wait a tick: the destroy commands must
	--- land before we ask the engine to lay out a network for what is left.
	phase : integer
	done : boolean
end

--- Small deterministic RNG. We avoid math.random so that the result depends
--- only on the generated map, not on whatever else has consumed randomness.
local record Rng
	seed : integer
end

local function nextRandom(rng : Rng) : number
	rng.seed = (rng.seed * 1103515245 + 12345) % 2147483648
	return rng.seed / 2147483648
end

local function pick(list : {number}, index : integer, fallback : number) : number
	if index ~= nil and index >= 1 and index <= #list then
		return list[index]
	end
	return fallback
end

local function readParams() : integer, number, number
	local all = api.engine.config.getModParams()
	local own = all ~= nil and all[MOD_ID] as {string : integer} or nil
	if own == nil then
		log.message(LOG .. "no mod params found; using defaults")
		return 4, 0.45, 0.10
	end
	return math.floor(pick(CLUSTER_COUNTS as {number}, own["cluster.count"], 4)),
		pick(KEEP_FRACTIONS, own["cluster.keep"], 0.45),
		pick(ISOLATED_SHARES, own["cluster.isolated"], 0.10)
end

local function collectTowns() : {Town}
	local towns : {Town} = {}
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		local pos = entity_util.getPosition(entity)
		if pos ~= nil then
			towns[#towns + 1] = { entity = entity, x = pos.x, y = pos.y, dist = 0 }
		end
	end, api.type.ComponentType.TOWN)
	return towns
end

local function distance2(a : Town, b : Town) : number
	local dx, dy = a.x - b.x, a.y - b.y
	return dx * dx + dy * dy
end

--- Farthest-point sampling: start somewhere, then repeatedly take the town
--- furthest from everything chosen so far. Gives centres spread across the map
--- rather than bunched in one corner, without needing a map-size constant.
local function chooseCentres(towns : {Town}, count : integer, rng : Rng) : {Town}
	local centres : {Town} = { towns[1 + math.floor(nextRandom(rng) * #towns)] }
	while #centres < count and #centres < #towns do
		local best : Town = nil
		local bestDist = -1.0
		for __, town in ipairs(towns) do
			local nearest = math.huge
			for __, centre in ipairs(centres) do
				local d = distance2(town, centre)
				if d < nearest then nearest = d end
			end
			if nearest > bestDist then
				bestDist = nearest
				best = town
			end
		end
		if best == nil then break end
		centres[#centres + 1] = best
	end
	return centres
end

local function shrink(town : Town)
	local component = api.engine.getComponent(town.entity, api.type.ComponentType.TOWN) as Engine.Component.Town
	if component == nil or component.sizeFactors == nil then
		return
	end
	local scaled : {number} = {}
	for i, factor in ipairs(component.sizeFactors) do
		scaled[i] = factor * ISOLATED_SIZE_SCALE
	end
	api.cmd.sendCommand(api.cmd.makeTownUpdateSizeCmd(town.entity, scaled, true))
end

local function prune() : boolean
	local towns = collectTowns()
	local total = #towns
	local clusterCount, keepFraction, isolatedShare = readParams()

	local keepTotal = math.max(1, math.floor(total * keepFraction + 0.5))
	if keepTotal >= total then
		log.message(LOG .. "keeping every town; nothing to prune")
		return false
	end
	local isolatedCount = math.floor(keepTotal * isolatedShare + 0.5)
	local clusteredCount = math.max(1, keepTotal - isolatedCount)

	-- Seed from the map itself so the same map always prunes the same way.
	local seed = total * 7919
	for __, town in ipairs(towns) do
		seed = (seed + math.floor(town.x) * 31 + math.floor(town.y) * 17) % 2147483648
	end
	local rng : Rng = { seed = math.abs(seed) + 1 }

	local centres = chooseCentres(towns, clusterCount, rng)
	for __, town in ipairs(towns) do
		local nearest = math.huge
		for __, centre in ipairs(centres) do
			local d = distance2(town, centre)
			if d < nearest then nearest = d end
		end
		town.dist = nearest
	end

	-- Nearest to a centre survive as the clusters.
	table.sort(towns, function(a : Town, b : Town) : boolean
		return a.dist < b.dist
	end)

	local keep : {Town} = {}
	local doomed : {Town} = {}
	for i, town in ipairs(towns) do
		if i <= clusteredCount then
			keep[#keep + 1] = town
		else
			doomed[#doomed + 1] = town
		end
	end

	-- Spare a few of the doomed as isolated towns. Taken from the far end and
	-- spaced out, so they sit well away from the conurbations and from each
	-- other. Marked by index rather than removed, because blanking entries
	-- would leave holes that ipairs stops at.
	local spared : {integer : boolean} = {}
	local isolated : {Town} = {}
	for i = 1, isolatedCount do
		local index = #doomed - (i - 1) * 2
		if index >= 1 and not spared[index] then
			spared[index] = true
			isolated[#isolated + 1] = doomed[index]
		end
	end

	local destroyed = 0
	for i, town in ipairs(doomed) do
		if not spared[i] then
			api.cmd.sendCommand(api.cmd.makeTownDestroyCmd(town.entity))
			destroyed = destroyed + 1
		end
	end
	for __, town in ipairs(isolated) do
		shrink(town)
	end

	log.message(LOG .. string.format(
		"pruned: %d towns -> %d in %d clusters + %d isolated (%d removed)",
		total, #keep + #isolated, #centres, #isolated, destroyed))
	return destroyed > 0
end

--- Rebuild the inter-town road network for whatever towns are left.
---
--- Destroying a town leaves the roads that ran to it, which dead-end in open
--- country. Passing keep = false makes the engine clear the existing street
--- network and lay out a fresh one for the towns we hand it, so the orphans go
--- and the survivors end up properly connected - one command instead of
--- hunting individual segments.
local function reconnect()
	local towns = collectTowns()
	if #towns < 2 then
		return
	end

	local entities : {Engine.Entity} = {}
	local mapTowns : {GameMap.Town} = {}
	for i, town in ipairs(towns) do
		entities[i] = town.entity
		local mapTown = api.type.Map.Town.new()
		mapTown.pos = api.type.Vec2f.new(town.x, town.y)
		mapTown.name = entity_util.getEntityName(town.entity) or ""
		mapTown.existing = town.entity
		mapTowns[i] = mapTown
	end

	-- Let the engine decide which towns ought to be joined; this is the same
	-- call the Map Editor uses for its own town connections.
	local connections = api.engine.mapgen.getDefaultTownConnections(mapTowns)
	api.cmd.sendCommand(
		api.cmd.makeTownConnectWithIndustriesCmd(entities, connections, false))
	log.message(LOG .. string.format(
		"rebuilt road network for %d towns (%d connections)",
		#entities, #connections))
end

local mod = {}

mod.update = function(_userParams : table, state : GameScriptState<State>, _dt : number)
	local current = state:get()
	if current ~= nil and current.done then
		return
	end

	if current ~= nil and current.phase == 1 then
		reconnect()
		state:set({ phase = 2, done = true })
		return
	end

	local gameTimeComponent = api.engine.getComponent(
		api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
	if gameTimeComponent ~= nil and gameTimeComponent.gameTime > MAX_START_GAME_TIME then
		-- Not a fresh game: almost certainly the mod was added to an existing
		-- save. Do nothing, ever, rather than delete someone's towns.
		log.message(LOG .. "not a new game; pruning skipped")
		state:set({ phase = 2, done = true })
		return
	end

	-- Towns may not exist on the very first tick; wait for generation.
	local towns = collectTowns()
	if #towns < 2 then
		return
	end

	-- prune() reports whether it actually removed anything; only bother
	-- rebuilding roads if it did.
	if prune() then
		state:set({ phase = 1, done = false })
	else
		state:set({ phase = 2, done = true })
	end
end

return mod
