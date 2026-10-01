--- Town Clustering - redistribute generated towns into clusters.
---
--- The engine places towns uniformly during map generation and there is no way
--- to influence that from the new game dialog (see NOTES.md - no mod code runs
--- in the menu, and a terrain generator can only shape terrain). So instead we
--- let generation finish untouched and rearrange towns afterwards, on the first
--- tick of a new game.
---
--- Towns are *relocated*, not deleted: the town count the player chose with the
--- Town Density setting is preserved exactly. Each town either keeps the
--- position the generator gave it, or is destroyed and re-created next to a
--- cluster centre. Terrain, rivers and industries are never touched.
---
--- The rebuild uses the same calls the Map Editor uses for its own town import
--- (gui/map_editor/map_editor.tl, makeTowns):
---
---   api.engine.terrain.makeMapFromGame  ->  the current towns, with names,
---                                           size factors and cargo needs
---   api.engine.mapgen.createTowns       ->  { toRemove, toAdd }
---   makeTownDestroyCmd / makeTownCreateCmd
---
--- A town that is listed with its `existing` entity is left alone; one listed
--- without it is created fresh, and any town in the world that the list no
--- longer mentions is returned in `toRemove`.
---
--- The mod only needs to be active when the game starts; afterwards it does
--- nothing and can safely be removed from the savegame.

local entity_util = ug_require "::/scripts/entity_util.tl" as EntityUtil

local LOG <const> = "[town-clustering] "
local MOD_ID <const> = "town_clustering_1"

--- Slider index (1-based) to value. Index 0 or missing falls back to DEFAULT.
--- Confirmed 1-based against the stock climate generators, which default to
--- index 3 of five values and mean "Medium" by it.
local CLUSTER_COUNTS <const> = { 2, 3, 4, 5, 6, 8 }
local KEEP_FRACTIONS <const> = { 0.30, 0.45, 0.60, 0.75, 1.00 }
local ISOLATED_SHARES <const> = { 0.0, 0.05, 0.10, 0.20 }

--- Isolated towns are scaled to this share of their generated size. They are
--- meant to read as hamlets left behind by the clustering, not as peers of the
--- towns in the conurbations.
local ISOLATED_SIZE_SCALE <const> = 0.45

--- Only rearrange a genuinely fresh game. Adding this mod to an established
--- save and silently rebuilding half its towns would be catastrophic, so bail
--- out if any meaningful time has passed.
local MAX_START_GAME_TIME <const> = 60 * 60 * 24 * 10

--- Placement rules for a relocated town, all in metres.
---
--- MIN_TOWN_SPACING is deliberately far below the generator's own roughly one
--- town per 5 km2: packing towns tighter than the engine ever would is the
--- entire point. It still has to be wide enough that two town centres do not
--- try to grow through each other.
local MIN_TOWN_SPACING <const> = 800.0
local FIRST_RING <const> = 420.0
local RING_STEP <const> = 240.0
local MAX_RINGS <const> = 14
local ANGLES_PER_RING <const> = 12

--- A candidate is rejected if the ground rises or falls more than this across
--- a probe of SLOPE_PROBE metres either side of it. Towns need buildable
--- ground, and the generator's own placer applies a similar test.
local SLOPE_PROBE <const> = 24.0
local MAX_SLOPE_DROP <const> = 14.0

--- Creating towns is asynchronous. Stop waiting for the world to settle after
--- this many ticks and connect whatever is actually there.
local MAX_SETTLE_TICKS <const> = 240

local record Candidate
	--- the town as the generator left it
	source : GameMap.Town
	x : number
	y : number
	--- distance to the nearest chosen cluster centre
	dist : number
	--- which of the three fates this town met
	kind : string
end

local record State
	--- 0/nil = not started, 1 = towns rebuilt and awaiting the world settling,
	--- 2 = finished. The road rebuild has to wait: the destroy and create
	--- commands must land before we ask the engine to lay out a network.
	phase : integer
	--- how many towns we expect once the rebuild lands
	expected : integer
	--- ticks spent waiting in phase 1
	waited : integer
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

local function countTowns() : integer
	local n = 0
	api.engine.forEachEntityWithComponent(function(_entity : Engine.Entity)
		n = n + 1
	end, api.type.ComponentType.TOWN)
	return n
end

local function distance2(ax : number, ay : number, bx : number, by : number) : number
	local dx, dy = ax - bx, ay - by
	return dx * dx + dy * dy
end

--- Farthest-point sampling: start somewhere, then repeatedly take the town
--- furthest from everything chosen so far. Gives centres spread across the map
--- rather than bunched in one corner, without needing a map-size constant.
local function chooseCentres(towns : {Candidate}, count : integer, rng : Rng) : {Candidate}
	local centres : {Candidate} = { towns[1 + math.floor(nextRandom(rng) * #towns)] }
	while #centres < count and #centres < #towns do
		local best : Candidate = nil
		local bestDist = -1.0
		for __, town in ipairs(towns) do
			local nearest = math.huge
			for __, centre in ipairs(centres) do
				local d = distance2(town.x, town.y, centre.x, centre.y)
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

--- Is this somewhere a town could plausibly stand? The engine will happily
--- create a town in a lake or up a cliff if we ask it to, so we ask carefully.
local function isBuildable(x : number, y : number) : boolean
	local pos = api.type.Vec2f.new(x, y)
	if not api.engine.terrain.isValidCoordinate(pos) then
		return false
	end
	if api.engine.terrain.isOnWater(pos) then
		return false
	end

	local centre = api.engine.terrain.getHeightAt(pos)
	local lo, hi = centre, centre
	local probes = {
		{ x - SLOPE_PROBE, y }, { x + SLOPE_PROBE, y },
		{ x, y - SLOPE_PROBE }, { x, y + SLOPE_PROBE },
	}
	for __, p in ipairs(probes) do
		local probe = api.type.Vec2f.new(p[1], p[2])
		if not api.engine.terrain.isValidCoordinate(probe) then
			return false
		end
		if api.engine.terrain.isOnWater(probe) then
			return false
		end
		local h = api.engine.terrain.getHeightAt(probe)
		if h < lo then lo = h end
		if h > hi then hi = h end
	end
	return (hi - lo) <= MAX_SLOPE_DROP
end

--- Find somewhere near `centre` for one relocated town: work outwards ring by
--- ring, and take the first spot that is buildable and far enough from every
--- town already placed. Returns false if the neighbourhood is full, in which
--- case the caller leaves the town where the generator put it rather than
--- losing it. The flag is a separate return rather than a nil position, so the
--- signature stays honest to Teal - the game type-checks this file at load.
local function findSpot(cx : number, cy : number, placed : {{number, number}}, rng : Rng) : boolean, number, number
	for ring = 1, MAX_RINGS do
		local radius = FIRST_RING + (ring - 1) * RING_STEP
		local phase = nextRandom(rng) * math.pi * 2
		for slot = 0, ANGLES_PER_RING - 1 do
			local angle = phase + slot * math.pi * 2 / ANGLES_PER_RING
			local x = cx + math.cos(angle) * radius
			local y = cy + math.sin(angle) * radius

			local clear = true
			for __, p in ipairs(placed) do
				if distance2(x, y, p[1], p[2]) < MIN_TOWN_SPACING * MIN_TOWN_SPACING then
					clear = false
					break
				end
			end
			if clear and isBuildable(x, y) then
				return true, x, y
			end
		end
	end
	return false, 0, 0
end

--- Rebuild the town layout. Returns the number of towns the world should end up
--- with, or 0 if there was nothing worth doing.
local function redistribute() : integer
	local map = api.engine.terrain.makeMapFromGame(false, true, false, false)
	if map == nil or map.towns == nil or #map.towns < 2 then
		log.message(LOG .. "no towns to work with")
		return 0
	end

	local towns : {Candidate} = {}
	for __, source in ipairs(map.towns) do
		towns[#towns + 1] = {
			source = source, x = source.pos.x, y = source.pos.y, dist = 0, kind = "move",
		}
	end
	local total = #towns

	local clusterCount, keepFraction, isolatedShare = readParams()
	local stayCount = math.max(1, math.floor(total * keepFraction + 0.5))
	if stayCount >= total then
		log.message(LOG .. "every town stays put; nothing to do")
		return 0
	end

	-- Seed from the map itself so the same map always clusters the same way.
	local seed = total * 7919
	for __, town in ipairs(towns) do
		seed = (seed + math.floor(town.x) * 31 + math.floor(town.y) * 17) % 2147483648
	end
	local rng : Rng = { seed = math.abs(seed) + 1 }

	local centres = chooseCentres(towns, clusterCount, rng)
	for __, town in ipairs(towns) do
		local nearest = math.huge
		for __, centre in ipairs(centres) do
			local d = distance2(town.x, town.y, centre.x, centre.y)
			if d < nearest then nearest = d end
		end
		town.dist = nearest
	end

	-- Nearest to a centre keep the position the generator gave them; they are
	-- already where we want towns to be.
	table.sort(towns, function(a : Candidate, b : Candidate) : boolean
		return a.dist < b.dist
	end)

	local movers = total - stayCount
	local isolatedCount = math.floor(movers * isolatedShare + 0.5)
	for i, town in ipairs(towns) do
		if i <= stayCount then
			town.kind = "stay"
		else
			town.kind = "move"
		end
	end

	-- Spare a few of the movers as isolated towns: they stay out in the country
	-- where they were generated and are scaled down, so they read as outlying
	-- hamlets rather than as peers of the towns in the conurbations. Taken from
	-- the far end and spaced out, so they sit well away from the clusters.
	local isolated : {Candidate} = {}
	for i = 1, isolatedCount do
		local index = total - (i - 1) * 2
		if index > stayCount and towns[index] ~= nil and towns[index].kind == "move" then
			towns[index].kind = "isolated"
			isolated[#isolated + 1] = towns[index]
		end
	end

	-- Everything that is not moving occupies its spot already.
	local placed : {{number, number}} = {}
	for __, town in ipairs(towns) do
		if town.kind ~= "move" then
			placed[#placed + 1] = { town.x, town.y }
		end
	end

	-- Hand each mover to the centre that currently has the fewest, so the
	-- clusters grow at roughly the same rate instead of the first one taking
	-- everything within reach.
	local load : {integer} = {}
	for i = 1, #centres do load[i] = 0 end

	local moved, stranded = 0, 0
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			local target = 1
			for i = 2, #centres do
				if load[i] < load[target] then target = i end
			end
			local ok, x, y = findSpot(centres[target].x, centres[target].y, placed, rng)
			if not ok then
				-- No room left near that centre: leave the town alone rather
				-- than destroy it. A quieter result than losing a town.
				town.kind = "stay"
				stranded = stranded + 1
				placed[#placed + 1] = { town.x, town.y }
			else
				town.x = x
				town.y = y
				load[target] = load[target] + 1
				moved = moved + 1
				placed[#placed + 1] = { x, y }
			end
		end
	end

	if moved == 0 then
		log.message(LOG .. "found nowhere to move any town to; leaving the map alone")
		return 0
	end

	-- The desired layout. A town listed with its `existing` entity is left
	-- untouched; one listed without is built fresh at the new position.
	local desired : {GameMap.Town} = {}
	for __, town in ipairs(towns) do
		local entry = api.type.Map.Town.new()
		entry.pos = api.type.Vec2f.new(town.x, town.y)
		entry.name = town.source.name or ""
		entry.sizeFactors = town.source.sizeFactors
		entry.landUse2CargoNeeds = town.source.landUse2CargoNeeds
		if town.kind ~= "move" then
			entry.existing = town.source.existing
		end
		desired[#desired + 1] = entry
	end

	local result = api.engine.mapgen.createTowns(tostring(rng.seed), desired)
	for __, entity in ipairs(result.toRemove) do
		api.cmd.sendCommand(api.cmd.makeTownDestroyCmd(entity))
	end
	if #result.toAdd > 0 then
		api.cmd.sendCommand(api.cmd.makeTownCreateCmd(result.toAdd))
	end

	-- Isolated towns keep their entity, so they can simply be scaled down.
	for __, town in ipairs(isolated) do
		if town.source.existing ~= nil and town.source.sizeFactors ~= nil then
			local scaled : {number} = {}
			for i, factor in ipairs(town.source.sizeFactors) do
				scaled[i] = factor * ISOLATED_SIZE_SCALE
			end
			api.cmd.sendCommand(
				api.cmd.makeTownUpdateSizeCmd(town.source.existing, scaled, true))
		end
	end

	log.message(LOG .. string.format(
		"%d towns -> %d clusters: %d moved, %d left in place, %d isolated, %d stranded "
		.. "(%d destroyed, %d created)",
		total, #centres, moved, stayCount, #isolated, stranded,
		#result.toRemove, #result.toAdd))
	return total
end

--- Rebuild the inter-town road network.
---
--- getDefaultTownConnections is a *proposal*, not a finished network - the Map
--- Editor merges it into whatever connections already exist rather than
--- treating it as complete (map_editor.tl, "Propose Default Connections"). On a
--- clustered map it reliably leaves each cluster an island, so we stitch the
--- components together ourselves before handing the lot to the engine.
local function connectAll()
	local entities : {Engine.Entity} = {}
	local xs : {number} = {}
	local ys : {number} = {}
	local mapTowns : {GameMap.Town} = {}

	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		local pos = entity_util.getPosition(entity)
		if pos ~= nil then
			local i = #entities + 1
			entities[i] = entity
			xs[i] = pos.x
			ys[i] = pos.y
			local mapTown = api.type.Map.Town.new()
			mapTown.pos = api.type.Vec2f.new(pos.x, pos.y)
			mapTown.name = entity_util.getEntityName(entity) or ""
			mapTown.existing = entity
			mapTowns[i] = mapTown
		end
	end, api.type.ComponentType.TOWN)

	local count = #entities
	if count < 2 then
		return
	end

	local connections = api.engine.mapgen.getDefaultTownConnections(mapTowns)

	-- Union-find over the proposed connections.
	local parent : {integer} = {}
	for i = 1, count do parent[i] = i end

	local function find(i : integer) : integer
		while parent[i] ~= i do
			parent[i] = parent[parent[i]]
			i = parent[i]
		end
		return i
	end

	local components = count
	local function union(a : integer, b : integer) : boolean
		local ra, rb = find(a), find(b)
		if ra == rb then return false end
		parent[ra] = rb
		components = components - 1
		return true
	end

	for __, conn in ipairs(connections) do
		-- The engine indexes the town list it was given, 1-based.
		if conn[1] >= 1 and conn[1] <= count and conn[2] >= 1 and conn[2] <= count then
			union(conn[1], conn[2])
		end
	end

	-- Join whatever is still separate by the shortest link available, which for
	-- clustered towns is the pair of towns facing each other across the gap.
	local added = 0
	while components > 1 do
		local bestA, bestB, bestD = 0, 0, math.huge
		for i = 1, count do
			for j = i + 1, count do
				if find(i) ~= find(j) then
					local d = distance2(xs[i], ys[i], xs[j], ys[j])
					if d < bestD then
						bestD = d
						bestA = i
						bestB = j
					end
				end
			end
		end
		if bestA == 0 then break end
		union(bestA, bestB)
		connections[#connections + 1] = { bestA, bestB }
		added = added + 1
	end

	-- keep = false: clear the streets left over from the old layout and lay out
	-- a fresh network for the towns that are actually there now.
	api.cmd.sendCommand(
		api.cmd.makeTownConnectWithIndustriesCmd(entities, connections, false))
	log.message(LOG .. string.format(
		"connected %d towns with %d links (%d added to join %s)",
		count, #connections, added,
		added == 0 and "nothing - already connected" or "separate clusters"))
end

local mod = {}

mod.update = function(_userParams : table, state : GameScriptState<State>, _dt : number)
	local current = state:get()
	if current ~= nil and current.done then
		return
	end

	if current ~= nil and current.phase == 1 then
		-- Town creation is asynchronous. Wait for the world to show the town
		-- count we expect before laying out roads, but do not wait forever.
		local waited = (current.waited or 0) + 1
		if countTowns() < current.expected and waited < MAX_SETTLE_TICKS then
			state:set({ phase = 1, expected = current.expected, waited = waited, done = false })
			return
		end
		if countTowns() < current.expected then
			log.message(LOG .. string.format(
				"gave up waiting: %d of %d towns present", countTowns(), current.expected))
		end
		connectAll()
		state:set({ phase = 2, expected = current.expected, waited = waited, done = true })
		return
	end

	local gameTimeComponent = api.engine.getComponent(
		api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
	if gameTimeComponent ~= nil and gameTimeComponent.gameTime > MAX_START_GAME_TIME then
		-- Not a fresh game: almost certainly the mod was added to an existing
		-- save. Do nothing, ever, rather than rearrange someone's towns.
		log.message(LOG .. "not a new game; clustering skipped")
		state:set({ phase = 2, expected = 0, waited = 0, done = true })
		return
	end

	-- Towns may not exist on the very first tick; wait for generation.
	if countTowns() < 2 then
		return
	end

	local expected = redistribute()
	if expected > 0 then
		state:set({ phase = 1, expected = expected, waited = 0, done = false })
	else
		state:set({ phase = 2, expected = 0, waited = 0, done = true })
	end
end

return mod
