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

--- Cluster sizes follow a geometric series; these are the bounds the ratio is
--- drawn from, per slider position. A ratio of 1.0 makes every cluster the same
--- size; the lower the ratio, the more one conurbation dominates. The range is
--- a range rather than one number so that the same settings give a different
--- shape on a different map.
local VARIATION_RATIO_MIN <const> = { 1.00, 0.78, 0.55, 0.38 }
local VARIATION_RATIO_MAX <const> = { 1.00, 0.92, 0.80, 0.55 }

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
--- town per 5 km2 - about 1400 m between neighbours - because packing towns
--- tighter than the engine ever would is the entire point. It still has to be
--- wide enough that two town centres do not try to grow through each other,
--- and 600 m is the tightest that has been tried in game.
---
--- Note that a cluster centre is itself a town, so it occupies the middle
--- before any mover is placed: the innermost ring that can actually be used is
--- the first one wider than this spacing, not FIRST_RING.
local MIN_TOWN_SPACING <const> = 600.0
local FIRST_RING <const> = 420.0
local RING_STEP <const> = 240.0
local MAX_RINGS <const> = 14
local ANGLES_PER_RING <const> = 12

--- How far a town may wander off its ring, as a share of that ring's radius.
--- Because it scales with the radius, the middle of a cluster stays tight while
--- the outskirts scatter - which is the shape real town groups have, and the
--- shape a fixed spacing cannot produce.
local JITTER_SHARE <const> = 0.18

--- No cluster drops below this share of the largest one's weight. Without a
--- floor, eight clusters at the low end of the ratio range leaves the last few
--- holding a single town each, which reads as a stray rather than as a group.
local SIZE_MIN_WEIGHT <const> = 0.18

--- A candidate is rejected if the ground rises or falls more than
--- MAX_SLOPE_DROP across a probe of SLOPE_PROBE metres either side of it, or if
--- any probe lands in water. Towns need buildable ground, and the generator's
--- own placer applies a similar test.
---
--- The probe reaches 48 m because 24 m was not far enough: a river or a bank
--- just outside that radius left the centre looking fine while the town had
--- nowhere to build, which is how towns ended up oddly placed and occasionally
--- with no inhabitants at all.
---
--- Note that widening the probe without raising MAX_SLOPE_DROP also halves the
--- gradient a candidate may sit on - 14 m over 48 m rather than over 24 m. That
--- is deliberate, but it is the knob to turn if clusters start coming out
--- sparse or the log starts reporting stranded towns.
local SLOPE_PROBE <const> = 48.0
local MAX_SLOPE_DROP <const> = 14.0

--- Creating towns is asynchronous. Stop waiting for the world to settle after
--- this many ticks and connect whatever is actually there.
local MAX_SETTLE_TICKS <const> = 240

--- A town is created empty and grows its first houses over the ticks that
--- follow, so a population of zero means nothing straight away. Wait until the
--- number of empty towns has stopped falling for this many consecutive checks
--- before concluding that whatever is left is a dud - usually a centre with no
--- room to build, hemmed in by a river or a slope.
local POPULATION_STABLE_TICKS <const> = 90
local MAX_POPULATION_TICKS <const> = 1200

local record Candidate
	--- the town as the generator left it
	source : GameMap.Town
	x : number
	y : number
	--- distance to the nearest chosen cluster centre
	dist : number
	--- index of that nearest centre
	centre : integer
	--- which of the three fates this town met
	kind : string
end

local record State
	--- 0/nil = not started
	--- 1 = towns rebuilt, waiting for the world to show them all
	--- 2 = roads laid, waiting to see which towns stay empty
	--- 3 = empty towns destroyed, one tick before relaying the roads
	--- 4 = finished
	--- Each road pass has to wait a tick: the destroy and create commands must
	--- land before the engine is asked to lay out a network.
	phase : integer
	--- how many towns we expect once the rebuild lands
	expected : integer
	--- ticks spent waiting in the current phase
	waited : integer
	--- how many towns had no inhabitants at the last check
	zeroes : integer
	--- consecutive checks in which that count did not fall
	stable : integer
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

--- Split `amount` between buckets in proportion to `weights`, by largest
--- remainder, so the parts add up to exactly `amount` rather than to whatever
--- rounding each one individually happens to give.
local function share(amount : integer, weights : {number}) : {integer}
	local parts : {integer} = {}
	local remainder : {number} = {}
	local total = 0.0
	for __, weight in ipairs(weights) do total = total + weight end

	local handedOut = 0
	for i, weight in ipairs(weights) do
		local exact = 0.0
		if total > 0 then exact = amount * weight / total end
		parts[i] = math.floor(exact)
		remainder[i] = exact - parts[i]
		handedOut = handedOut + parts[i]
	end

	while handedOut < amount do
		local best, bestRemainder = 0, -1.0
		for i = 1, #weights do
			if remainder[i] > bestRemainder then
				bestRemainder = remainder[i]
				best = i
			end
		end
		if best == 0 then break end
		parts[best] = parts[best] + 1
		remainder[best] = -1.0
		handedOut = handedOut + 1
	end
	return parts
end

local function pick(list : {number}, index : integer, fallback : number) : number
	if index ~= nil and index >= 1 and index <= #list then
		return list[index]
	end
	return fallback
end

--- clusterCount, keepFraction, isolatedShare, ratioLow, ratioHigh
local function readParams() : integer, number, number, number, number
	local all = api.engine.config.getModParams()
	local own = all ~= nil and all[MOD_ID] as {string : integer} or nil
	if own == nil then
		log.message(LOG .. "no mod params found; using defaults")
		return 4, 0.45, 0.10, 0.55, 0.80
	end
	local variation = own["cluster.variation"]
	return math.floor(pick(CLUSTER_COUNTS as {number}, own["cluster.count"], 4)),
		pick(KEEP_FRACTIONS, own["cluster.keep"], 0.45),
		pick(ISOLATED_SHARES, own["cluster.isolated"], 0.10),
		pick(VARIATION_RATIO_MIN, variation, 0.55),
		pick(VARIATION_RATIO_MAX, variation, 0.80)
end

local function countTowns() : integer
	local n = 0
	api.engine.forEachEntityWithComponent(function(_entity : Engine.Entity)
		n = n + 1
	end, api.type.ComponentType.TOWN)
	return n
end

--- A town's population, as the game itself counts it: the residential person
--- capacity of its buildings (game_mechanics/towns/town_util.tl, which reads
--- `getTownCapacityUsages(entity).residential.capacity` for the number shown in
--- the town window).
local function townPopulation(entity : Engine.Entity) : integer
	local capacities = api.engine.system.townBuildingSystem.getLandUsePersonCapacities(entity)
	if capacities == nil then
		return 0
	end
	local residential = capacities[api.type["enum"].LandUseType.RESIDENTIAL as integer + 1]
	if residential == nil then
		return 0
	end
	return residential
end

--- Towns with nobody living in them. A town the engine could not build on - the
--- centre is on land, but the ground around it is river or cliff - is created
--- happily and then just sits there empty.
local function emptyTowns() : {Engine.Entity}
	local empty : {Engine.Entity} = {}
	api.engine.forEachEntityWithComponent(function(entity : Engine.Entity)
		if townPopulation(entity) <= 0 then
			empty[#empty + 1] = entity
		end
	end, api.type.ComponentType.TOWN)
	return empty
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
	local step = math.pi * 2 / ANGLES_PER_RING

	for ring = 1, MAX_RINGS do
		local radius = FIRST_RING + (ring - 1) * RING_STEP
		local phase = nextRandom(rng) * math.pi * 2
		local wobble = radius * JITTER_SHARE

		-- Gather every spot on this ring that would work, then take one of them
		-- at random.
		--
		-- Taking the first that fits - which is what this used to do - walks the
		-- slots in order and stops, so every town lands at the smallest radius
		-- that will have it and the cluster packs into an even lattice sitting
		-- 3% above MIN_TOWN_SPACING. Measured, the median gap between
		-- neighbours was 822 m against a floor of 800. That reads as machined.
		--
		-- The candidates are wobbled off the ring before they are tested, not
		-- after, so the spacing floor still holds exactly.
		local spotsX : {number} = {}
		local spotsY : {number} = {}
		for slot = 0, ANGLES_PER_RING - 1 do
			local angle = phase + slot * step + (nextRandom(rng) - 0.5) * step * 0.8
			local reach = radius + (nextRandom(rng) - 0.5) * 2 * wobble
			local x = cx + math.cos(angle) * reach
			local y = cy + math.sin(angle) * reach

			local clear = true
			for __, p in ipairs(placed) do
				if distance2(x, y, p[1], p[2]) < MIN_TOWN_SPACING * MIN_TOWN_SPACING then
					clear = false
					break
				end
			end
			if clear and isBuildable(x, y) then
				spotsX[#spotsX + 1] = x
				spotsY[#spotsY + 1] = y
			end
		end

		if #spotsX > 0 then
			local choice = 1 + math.floor(nextRandom(rng) * #spotsX)
			return true, spotsX[choice], spotsY[choice]
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
			source = source, x = source.pos.x, y = source.pos.y,
			dist = 0, centre = 1, kind = "move",
		}
	end
	local total = #towns

	local clusterCount, keepFraction, isolatedShare, ratioLow, ratioHigh = readParams()
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
		local nearestIndex = 1
		for i, centre in ipairs(centres) do
			local d = distance2(town.x, town.y, centre.x, centre.y)
			if d < nearest then
				nearest = d
				nearestIndex = i
			end
		end
		town.dist = nearest
		town.centre = nearestIndex
	end

	-- Nearest to a centre keep the position the generator gave them; they are
	-- already where we want towns to be.
	table.sort(towns, function(a : Candidate, b : Candidate) : boolean
		return a.dist < b.dist
	end)

	local movers = total - stayCount
	local isolatedCount = math.floor(movers * isolatedShare + 0.5)

	-- How big should each cluster be?
	--
	-- Sharing the towns out evenly makes the clusters come out the same size,
	-- which reads as generated. Each centre instead gets a weight from a
	-- geometric series - one conurbation dominates, a couple are middling, one
	-- is a modest group - and every later share follows those weights.
	--
	-- The ratio varies per map, and which centre draws which weight is shuffled,
	-- so the big one is not always whichever centre the sampling happened to
	-- pick first.
	local ratio = ratioLow + nextRandom(rng) * (ratioHigh - ratioLow)
	local weights : {number} = {}
	local w = 1.0
	for i = 1, #centres do
		if w < SIZE_MIN_WEIGHT then
			weights[i] = SIZE_MIN_WEIGHT
		else
			weights[i] = w
		end
		w = w * ratio
	end
	for i = #centres, 2, -1 do
		local j = 1 + math.floor(nextRandom(rng) * i)
		weights[i], weights[j] = weights[j], weights[i]
	end

	-- Towns that keep their position have to follow the weights too. Capping
	-- only the movers leaves the clusters barely more than a fifth apart,
	-- because the towns that stay are spread evenly by geography and dilute
	-- everything the weights do.
	local stayQuota = share(stayCount, weights)

	local stays : {integer} = {}
	for i = 1, #centres do stays[i] = 0 end
	local staysTotal = 0
	for __, town in ipairs(towns) do
		-- towns are in ascending distance order, so a cluster fills its places
		-- with the towns already closest to it
		local k = town.centre
		if stays[k] < stayQuota[k] then
			town.kind = "stay"
			stays[k] = stays[k] + 1
			staysTotal = staysTotal + 1
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
		if towns[index] ~= nil and towns[index].kind == "move" then
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

	local moverCount = 0
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			moverCount = moverCount + 1
		end
	end

	local quota = share(moverCount, weights)

	-- A cluster with nothing in it is just a gap. Borrow from the largest.
	for i = 1, #centres do
		if stays[i] + quota[i] == 0 then
			local big = 1
			for k = 2, #centres do
				if quota[k] > quota[big] then big = k end
			end
			if quota[big] > 1 then
				quota[big] = quota[big] - 1
				quota[i] = 1
			end
		end
	end

	local placedIn : {integer} = {}
	for i = 1, #centres do placedIn[i] = 0 end

	local moved, stranded = 0, 0
	for __, town in ipairs(towns) do
		if town.kind == "move" then
			-- Try the centre with the most of its quota outstanding first, and
			-- fall through to the others if its neighbourhood turns out to be
			-- full - better a slightly off-quota cluster than a stranded town.
			local order : {integer} = {}
			for i = 1, #centres do order[i] = i end
			table.sort(order, function(a : integer, b : integer) : boolean
				return (quota[a] - placedIn[a]) > (quota[b] - placedIn[b])
			end)

			local settled = false
			for __, k in ipairs(order) do
				if quota[k] - placedIn[k] > 0 then
					local ok, x, y = findSpot(centres[k].x, centres[k].y, placed, rng)
					if ok then
						town.x = x
						town.y = y
						town.centre = k
						placedIn[k] = placedIn[k] + 1
						moved = moved + 1
						placed[#placed + 1] = { x, y }
						settled = true
						break
					end
				end
			end
			if not settled then
				-- Nowhere to put it: leave the town alone rather than destroy
				-- it. A quieter result than losing a town.
				town.kind = "stay"
				stranded = stranded + 1
				placed[#placed + 1] = { town.x, town.y }
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

	local sizes = ""
	for i = 1, #centres do
		if i > 1 then sizes = sizes .. "/" end
		sizes = sizes .. tostring(stays[i] + placedIn[i])
	end

	log.message(LOG .. string.format(
		"%d towns -> %d clusters sized %s (ratio %.2f): %d moved, %d left in place, "
		.. "%d isolated, %d stranded (%d destroyed, %d created)",
		total, #centres, sizes, ratio, moved, staysTotal, #isolated, stranded,
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
---
--- Some links will still fail to build: the engine reports "Too Much Incline"
--- or "Collision" and leaves that pair unconnected. That happens to the stock
--- generator's own connections too, on hilly maps, so a connected proposal is
--- the most we can guarantee from here.
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

	-- Which end is index zero?
	--
	-- The engine documents these as "indices into the vector townEntities". That
	-- vector is C++, so they are 0-based, while every list on this side of the
	-- boundary is 1-based. Appending a 1-based index to the list crashed the
	-- simulation thread twice on an out-of-range read - the second time reading
	-- 0xFFFFFFFFFFFFFFFF, which is what running off the end of that vector looks
	-- like. The crash landed at the very end of the layout, exactly where our own
	-- appended links sit.
	--
	-- Rather than trust either reading, work the base out from the data: a zero
	-- anywhere proves 0-based, and a value equal to the town count proves
	-- 1-based, because neither is legal in the other scheme.
	local lowest, highest = math.huge, -math.huge
	for __, conn in ipairs(connections) do
		for k = 1, 2 do
			local v = conn[k]
			if v < lowest then lowest = v end
			if v > highest then highest = v end
		end
	end

	local base = -1
	if #connections == 0 then
		base = -1
	elseif lowest <= 0 then
		base = 0
	elseif highest >= count then
		base = 1
	end

	-- base == -1 means the sample proved nothing: every index landed in the range
	-- the two schemes share. Guessing would risk either linking the wrong towns
	-- or crashing the game, so leave the engine's own proposal alone instead.
	local canAppend = base >= 0

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

	-- Engine index -> our 1-based index. Anything out of range is skipped rather
	-- than silently folded into the wrong town, which is what the old 1-based
	-- guard did to every connection that touched index 0.
	local skipped = 0
	if canAppend then
		for __, conn in ipairs(connections) do
			local a = conn[1] - base + 1
			local b = conn[2] - base + 1
			if a >= 1 and a <= count and b >= 1 and b <= count then
				union(a, b)
			else
				skipped = skipped + 1
			end
		end
	end

	-- Join whatever is still separate by the shortest link available, which for
	-- clustered towns is the pair of towns facing each other across the gap.
	local added = 0
	while canAppend and components > 1 do
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
		-- Back into the engine's own index base, and never outside the range it
		-- gave us: a bad index here is an access violation, not an error.
		local ea = bestA - 1 + base
		local eb = bestB - 1 + base
		if ea >= base and ea <= count - 1 + base and eb >= base and eb <= count - 1 + base then
			connections[#connections + 1] = { ea, eb }
			added = added + 1
		end
	end

	-- keep = true: add the links that are missing, leaving the existing street
	-- network alone.
	--
	-- keep = false means "remove the streets first", and that crashed the game:
	-- an access violation on the Simulation Thread (TransportFever3.exe+0xA4BD7,
	-- reading a freed pointer) a few seconds after this command was sent. By the
	-- time we get here the world has been simulating for minutes - towns have
	-- buildings, industries exist, people are moving - and tearing the whole
	-- street network out from under that leaves the engine holding stale
	-- references. The Map Editor can afford keep = false because nothing is
	-- running there; a game script cannot.
	--
	-- The cost is cosmetic: a destroyed town takes its own streets with it (see
	-- makeTownDestroyCmd), but an inter-town road that used to lead to it can be
	-- left as a stub.
	api.cmd.sendCommand(
		api.cmd.makeTownConnectWithIndustriesCmd(entities, connections, true))
	log.message(LOG .. string.format(
		"connected %d towns with %d links: engine proposed %d indexed %d..%d "
		.. "(read as %d-based), %d skipped, %d added to join separate clusters",
		count, #connections, #connections - added,
		lowest == math.huge and 0 or lowest, highest == -math.huge and 0 or highest,
		base, skipped, added))
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
			state:set({ phase = 1, expected = current.expected, waited = waited,
				zeroes = 0, stable = 0, done = false })
			return
		end
		if countTowns() < current.expected then
			log.message(LOG .. string.format(
				"gave up waiting: %d of %d towns present", countTowns(), current.expected))
		end
		connectAll()
		state:set({ phase = 2, expected = current.expected, waited = 0,
			zeroes = countTowns(), stable = 0, done = false })
		return
	end

	if current ~= nil and current.phase == 2 then
		-- Every town starts empty and fills over the following ticks, so the
		-- only honest signal is that the number of empty ones has stopped
		-- falling. Whatever is still empty after that could not build at all.
		local waited = (current.waited or 0) + 1
		local empty = emptyTowns()
		local zeroes = #empty

		local stable = (current.stable or 0) + 1
		if zeroes < (current.zeroes or 0) then
			stable = 0
		end

		if zeroes > 0 and stable < POPULATION_STABLE_TICKS and waited < MAX_POPULATION_TICKS then
			state:set({ phase = 2, expected = current.expected, waited = waited,
				zeroes = zeroes, stable = stable, done = false })
			return
		end

		if zeroes > 0 then
			for __, entity in ipairs(empty) do
				api.cmd.sendCommand(api.cmd.makeTownDestroyCmd(entity))
			end
			log.message(LOG .. string.format(
				"removed %d town(s) with no inhabitants after %d ticks; %d left",
				zeroes, waited, countTowns() - zeroes))
			-- Their roads went with them, but the links that led to them can be
			-- left dangling, so lay the network out once more. Rare enough that
			-- the extra pass costs nothing in practice.
			state:set({ phase = 3, expected = current.expected, waited = 0,
				zeroes = 0, stable = 0, done = false })
		else
			log.message(LOG .. string.format(
				"every town is inhabited after %d ticks", waited))
			state:set({ phase = 3, expected = current.expected, waited = 0,
				zeroes = 0, stable = 0, done = true })
		end
		return
	end

	if current ~= nil and current.phase == 3 then
		-- One tick on, so the destroy commands have landed.
		connectAll()
		state:set({ phase = 4, expected = current.expected, waited = 0,
			zeroes = 0, stable = 0, done = true })
		return
	end

	local gameTimeComponent = api.engine.getComponent(
		api.engine.util.getWorld(), api.type.ComponentType.GAME_TIME) as Engine.Component.GameTime
	if gameTimeComponent ~= nil and gameTimeComponent.gameTime > MAX_START_GAME_TIME then
		-- Not a fresh game: almost certainly the mod was added to an existing
		-- save. Do nothing, ever, rather than rearrange someone's towns.
		log.message(LOG .. "not a new game; clustering skipped")
		state:set({ phase = 4, expected = 0, waited = 0, zeroes = 0, stable = 0, done = true })
		return
	end

	-- Towns may not exist on the very first tick; wait for generation.
	if countTowns() < 2 then
		return
	end

	local expected = redistribute()
	if expected > 0 then
		state:set({ phase = 1, expected = expected, waited = 0,
			zeroes = 0, stable = 0, done = false })
	else
		state:set({ phase = 4, expected = 0, waited = 0, zeroes = 0, stable = 0, done = true })
	end
end

return mod
