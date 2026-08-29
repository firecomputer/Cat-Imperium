class_name SeaSplitter extends RefCounted

## 바다를 해역으로 쪼갠다. ProvinceSplitter 와 같은 다중 소스 동시 확장이지만
## 고도 장벽이 없어 그만큼 단순하다. 분지(연결 성분)를 넘는 해역은 만들지 않는다.

const TARGET_MIN := 60
const TARGET_MAX := 130
const AVG_TARGET := 90.0          # 바다 10,000 타일 → 해역 약 110개
const SEED_MIN_DIST := 6
const SEED_TRIES_PER_SEED := 40


## 반환: {"zones": Array[SeaZone], "tile_zone": PackedInt32Array}  (육지는 -1)
static func split(land: PackedByteArray, sea_basin: PackedInt32Array,
		features: PackedInt32Array, rng: RandomNumberGenerator) -> Dictionary:
	var nbr := MapGenerator.neighbor_cache()
	var total := land.size()

	var assigned := PackedInt32Array()
	assigned.resize(total)
	assigned.fill(-1)
	var sizes: Array[int] = []
	var zone_basin: Array[int] = []

	var basin_tiles := _tiles_by_basin(sea_basin, total)
	var basins: Array = basin_tiles.keys()
	basins.sort()                                 # 결정론 (§15)
	for basin in basins:
		var tiles: Array = basin_tiles[basin]
		if tiles.size() <= TARGET_MAX:
			var zid := sizes.size()
			sizes.append(0)
			zone_basin.append(int(basin))
			for t: int in tiles:
				assigned[t] = zid
				sizes[zid] += 1
			continue
		_grow(tiles, int(basin), sea_basin, nbr, assigned, sizes, zone_basin, rng)

	for basin in basins:
		_absorb_orphans(basin_tiles[basin], int(basin), sea_basin, nbr, assigned, sizes)
		while zone_basin.size() < sizes.size():
			zone_basin.append(int(basin))

	return {
		"zones": _build_zones(assigned, sizes, zone_basin, features, nbr),
		"tile_zone": assigned,
	}


static func _tiles_by_basin(sea_basin: PackedInt32Array, total: int) -> Dictionary:
	var out: Dictionary = {}
	for idx in range(total):
		var b := sea_basin[idx]
		if b < 0:
			continue
		if not out.has(b):
			out[b] = []
		out[b].append(idx)
	return out


# ---------------------------------------------------------------- 다중 소스 동시 확장

static func _grow(tiles: Array, basin: int, sea_basin: PackedInt32Array, nbr: Array,
		assigned: PackedInt32Array, sizes: Array[int], zone_basin: Array[int],
		rng: RandomNumberGenerator) -> void:
	var seeds := _poisson_seeds(tiles, rng)

	var local_ids: Array[int] = []
	var frontier: Array = []
	var head: Array[int] = []
	var target: Array[int] = []
	for s in seeds:
		var zid := sizes.size()
		sizes.append(1)
		zone_basin.append(basin)
		assigned[s] = zid
		local_ids.append(zid)
		frontier.append(_expandable(s, basin, sea_basin, nbr, assigned))
		head.append(0)
		target.append(rng.randi_range(TARGET_MIN, TARGET_MAX))

	var progressed := true
	while progressed:
		progressed = false
		for i in range(local_ids.size()):
			var zid: int = local_ids[i]
			if sizes[zid] >= target[i]:
				continue
			var f: Array = frontier[i]
			while head[i] < f.size():
				var t: int = f[head[i]]
				head[i] += 1
				if assigned[t] != -1:
					continue
				assigned[t] = zid
				sizes[zid] += 1
				f.append_array(_expandable(t, basin, sea_basin, nbr, assigned))
				progressed = true
				break


static func _expandable(from: int, basin: int, sea_basin: PackedInt32Array, nbr: Array,
		assigned: PackedInt32Array) -> Array:
	var out: Array = []
	for n: int in nbr[from]:
		if sea_basin[n] != basin or assigned[n] != -1:
			continue
		out.append(n)
	return out


static func _poisson_seeds(tiles: Array, rng: RandomNumberGenerator) -> Array[int]:
	var want := maxi(1, int(round(tiles.size() / AVG_TARGET)))
	var seeds: Array[int] = []
	var seed_coords: Array[Vector2i] = []
	var tries := want * SEED_TRIES_PER_SEED
	while seeds.size() < want and tries > 0:
		tries -= 1
		var t: int = tiles[rng.randi_range(0, tiles.size() - 1)]
		var c := Vector2i(t % MapGenerator.W, t / MapGenerator.W)
		var ok := true
		for other in seed_coords:
			if Hex.distance(c.x, c.y, other.x, other.y) < SEED_MIN_DIST:
				ok = false
				break
		if ok:
			seeds.append(t)
			seed_coords.append(c)
	return seeds


# ---------------------------------------------------------------- 고아 타일 흡수

## 목표 크기를 다 채우고 남은 타일은 가장 가까운 해역에 하나씩 붙인다.
## 덩어리째 한 해역에 몰아주면 그 해역만 두 배로 부푼다 (실측 최대 238타일).
static func _absorb_orphans(tiles: Array, basin: int, sea_basin: PackedInt32Array,
		nbr: Array, assigned: PackedInt32Array, sizes: Array[int]) -> void:
	var queue: Array[int] = []
	for t: int in tiles:
		if assigned[t] >= 0:
			queue.append(t)
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for n: int in nbr[cur]:
			if sea_basin[n] != basin or assigned[n] >= 0:
				continue
			assigned[n] = assigned[cur]
			sizes[assigned[cur]] += 1
			queue.append(n)

	# 씨앗이 하나도 닿지 않은 덩어리는 그 자체로 해역이 된다 (아주 작은 호수 등).
	for start: int in tiles:
		if assigned[start] >= 0:
			continue
		var zid := sizes.size()
		sizes.append(0)
		var stack: Array[int] = [start]
		assigned[start] = zid
		sizes[zid] += 1
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			for n: int in nbr[cur]:
				if sea_basin[n] != basin or assigned[n] >= 0:
					continue
				assigned[n] = zid
				sizes[zid] += 1
				stack.append(n)


# ---------------------------------------------------------------- 해역 객체 구성

static func _build_zones(assigned: PackedInt32Array, sizes: Array[int],
		zone_basin: Array[int], features: PackedInt32Array, nbr: Array) -> Array[SeaZone]:
	var zones: Array[SeaZone] = []
	var tile_lists: Array = []
	for i in range(sizes.size()):
		var z := SeaZone.new()
		z.id = i
		z.zone_id = zone_basin[i] if i < zone_basin.size() else -1
		zones.append(z)
		tile_lists.append(PackedInt32Array())

	for idx in range(assigned.size()):
		var zid := assigned[idx]
		if zid >= 0:
			tile_lists[zid].append(idx)

	for i in range(zones.size()):
		var z := zones[i]
		z.tiles = tile_lists[i]
		var sum_pos := Vector2.ZERO
		var neighbors := {}
		for t in z.tiles:
			sum_pos += Hex.to_plane(t % MapGenerator.W, t / MapGenerator.W)
			if features[t] == FeatureTagger.Feature.STRAIT:
				z.is_strait = true
			for n: int in nbr[t]:
				var other := assigned[n]
				if other >= 0 and other != i:
					neighbors[other] = true
		# 평균 좌표는 해역이 반도를 감싸면 육지 위에 떨어진다. 마커가 땅에 뜨지
		# 않도록 평균에 가장 가까운 **자기 바다 타일**로 옮긴다.
		var mean := sum_pos / maxf(z.tiles.size(), 1)
		z.centroid = mean
		var best := INF
		for t in z.tiles:
			var pos := Hex.to_plane(t % MapGenerator.W, t / MapGenerator.W)
			var distance := pos.distance_squared_to(mean)
			if distance < best:
				best = distance
				z.centroid = pos
		var keys: Array = neighbors.keys()
		keys.sort()
		z.neighbors = PackedInt32Array(keys)
	return zones
