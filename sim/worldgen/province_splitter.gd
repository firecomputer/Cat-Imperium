class_name ProvinceSplitter extends RefCounted

## 제약 있는 성장으로 육지를 프로빈스로 쪼갠다. 보로노이는 크기 제어가 불가능해서 쓰지 않는다.
## 목표 평균 17타일, 하드 상한 30타일.

const MAX_TILES := 30
const TARGET_MIN := 8
const TARGET_MAX := 30
const AVG_TARGET := 18.5           # 문서 목표 평균 17타일 / 약 294 프로빈스에 맞춘 실측값 (고아 흡수분 보정)
const SEED_MIN_DIST := 3          # 씨앗 간 최소 헥스 거리 (포아송 디스크)
const SEED_TRIES_PER_SEED := 40
const CHUNK_SIZE := 22            # 흡수 불가한 큰 고아 덩어리를 쪼갤 때 크기

# 고도차 차단 — 이것이 프로빈스 경계를 지형에 맞춰 그려주어 밋밋한 육각 덩어리를 방지한다.
const ELEV_BLOCK_DIFF := 0.18
const ELEV_BLOCK_CHANCE := 0.65

# 고도 순위 기반 지형 분류 (문서에 지형 분류 정의가 없어 고도에서 도출한다)
const MOUNTAIN_TOP_PCT := 0.15
const HILL_NEXT_PCT := 0.30


## land/elevation 은 MapGenerator 결과, tagged 는 FeatureTagger.tag() 결과.
static func split(land: PackedByteArray, elevation: PackedFloat32Array,
		tagged: Dictionary, rng: RandomNumberGenerator) -> Array[Province]:
	var nbr := MapGenerator.neighbor_cache()
	var total := land.size()
	var land_comp: PackedInt32Array = tagged["land_comp"]
	var comp_sizes: Dictionary = tagged["comp_sizes"]

	var barriers := _build_barriers(land, elevation, nbr, rng)

	var assigned := PackedInt32Array()
	assigned.resize(total)
	assigned.fill(-1)
	var sizes: Array[int] = []      # 프로빈스 id → 타일 수

	var comp_tiles := _tiles_by_component(land_comp, total)
	for comp_id in comp_tiles.keys():
		var tiles: Array = comp_tiles[comp_id]
		if tiles.size() <= MAX_TILES:
			# 섬 요구사항 자동 충족: 작은 컴포넌트는 통째로 1 프로빈스
			var pid := sizes.size()
			sizes.append(0)
			for t: int in tiles:
				assigned[t] = pid
				sizes[pid] += 1
			continue
		_grow(tiles, comp_id, land_comp, nbr, barriers, assigned, sizes, rng)

	_absorb_orphans(tiles_flat(comp_tiles), land_comp, nbr, assigned, sizes)
	return _build_provinces(assigned, sizes, land, elevation, nbr, tagged)


static func tiles_flat(comp_tiles: Dictionary) -> Array:
	var out: Array = []
	for k in comp_tiles.keys():
		out.append_array(comp_tiles[k])
	out.sort()
	return out


static func _tiles_by_component(land_comp: PackedInt32Array, total: int) -> Dictionary:
	var out: Dictionary = {}
	for idx in range(total):
		var c := land_comp[idx]
		if c < 0:
			continue
		if not out.has(c):
			out[c] = []
		out[c].append(idx)
	return out


## 고도차가 큰 방향은 확률적으로 막는다. 타일 쌍마다 한 번만 굴려 모든 프로빈스에 같은 산맥이 보이게 한다.
static func _build_barriers(land: PackedByteArray, elevation: PackedFloat32Array,
		nbr: Array, rng: RandomNumberGenerator) -> Dictionary:
	var out: Dictionary = {}
	var total := land.size()
	for idx in range(total):
		if land[idx] == 0:
			continue
		for n: int in nbr[idx]:
			if n <= idx or land[n] == 0:
				continue
			if absf(elevation[idx] - elevation[n]) > ELEV_BLOCK_DIFF and rng.randf() < ELEV_BLOCK_CHANCE:
				out[idx * total + n] = true
	return out


static func _blocked(barriers: Dictionary, a: int, b: int, total: int) -> bool:
	return barriers.has((mini(a, b)) * total + maxi(a, b))


# ---------------------------------------------------------------- 다중 소스 동시 확장

static func _grow(tiles: Array, comp_id: int, land_comp: PackedInt32Array, nbr: Array,
		barriers: Dictionary, assigned: PackedInt32Array, sizes: Array[int],
		rng: RandomNumberGenerator) -> void:
	var total := land_comp.size()
	var seeds := _poisson_seeds(tiles, rng)

	var local_ids: Array[int] = []
	var frontier: Array = []
	var head: Array[int] = []
	var target: Array[int] = []
	for s in seeds:
		var pid := sizes.size()
		sizes.append(1)
		assigned[s] = pid
		local_ids.append(pid)
		frontier.append(_expandable(s, comp_id, land_comp, nbr, barriers, assigned, total))
		head.append(0)
		target.append(rng.randi_range(TARGET_MIN, TARGET_MAX))

	var progressed := true
	while progressed:
		progressed = false
		for i in range(local_ids.size()):
			var pid: int = local_ids[i]
			if sizes[pid] >= target[i]:
				continue
			var f: Array = frontier[i]
			while head[i] < f.size():
				var t: int = f[head[i]]
				head[i] += 1
				if assigned[t] != -1:
					continue
				assigned[t] = pid
				sizes[pid] += 1
				f.append_array(_expandable(t, comp_id, land_comp, nbr, barriers, assigned, total))
				progressed = true
				break


static func _expandable(from: int, comp_id: int, land_comp: PackedInt32Array, nbr: Array,
		barriers: Dictionary, assigned: PackedInt32Array, total: int) -> Array:
	var out: Array = []
	for n: int in nbr[from]:
		if land_comp[n] != comp_id or assigned[n] != -1:
			continue
		if _blocked(barriers, from, n, total):
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

static func _absorb_orphans(all_tiles: Array, land_comp: PackedInt32Array, nbr: Array,
		assigned: PackedInt32Array, sizes: Array[int]) -> void:
	for start: int in all_tiles:
		if assigned[start] != -1:
			continue
		var cluster := _unassigned_cluster(start, land_comp, nbr, assigned)
		_place_cluster(cluster, nbr, assigned, sizes)


static func _unassigned_cluster(start: int, land_comp: PackedInt32Array, nbr: Array,
		assigned: PackedInt32Array) -> Array[int]:
	var comp := land_comp[start]
	var seen: Dictionary = {start: true}
	var cluster: Array[int] = [start]
	var stack: Array[int] = [start]
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		for n: int in nbr[cur]:
			if land_comp[n] != comp or assigned[n] != -1 or seen.has(n):
				continue
			seen[n] = true
			cluster.append(n)
			stack.append(n)
	cluster.sort()
	return cluster


## 30 이하면 가장 작은 인접 프로빈스에 흡수, 안 들어가면 독립 프로빈스. 30 초과면 먼저 쪼갠다.
static func _place_cluster(cluster: Array[int], nbr: Array, assigned: PackedInt32Array,
		sizes: Array[int]) -> void:
	if cluster.size() > MAX_TILES:
		for chunk in _chunk(cluster, nbr):
			_place_cluster(chunk, nbr, assigned, sizes)
		return

	var host := _smallest_adjacent(cluster, nbr, assigned, sizes)
	var pid := host
	if host == -1 or sizes[host] + cluster.size() > MAX_TILES:
		pid = sizes.size()
		sizes.append(0)
	for t in cluster:
		assigned[t] = pid
		sizes[pid] += 1


static func _smallest_adjacent(cluster: Array[int], nbr: Array, assigned: PackedInt32Array,
		sizes: Array[int]) -> int:
	var best := -1
	for t in cluster:
		for n: int in nbr[t]:
			var pid := assigned[n]
			if pid < 0:
				continue
			if best == -1 or sizes[pid] < sizes[best] or (sizes[pid] == sizes[best] and pid < best):
				best = pid
	return best


static func _chunk(cluster: Array[int], nbr: Array) -> Array:
	var pool: Dictionary = {}
	for t in cluster:
		pool[t] = true
	var out: Array = []
	for start in cluster:
		if not pool.has(start):
			continue
		var piece: Array[int] = []
		var stack: Array[int] = [start]
		pool.erase(start)
		while not stack.is_empty() and piece.size() < CHUNK_SIZE:
			var cur: int = stack.pop_back()
			piece.append(cur)
			for n: int in nbr[cur]:
				if pool.has(n) and piece.size() + stack.size() < CHUNK_SIZE:
					pool.erase(n)
					stack.append(n)
		piece.sort()
		out.append(piece)
	return out


# ---------------------------------------------------------------- Province 객체 구성

static func _build_provinces(assigned: PackedInt32Array, sizes: Array[int], land: PackedByteArray,
		elevation: PackedFloat32Array, nbr: Array, tagged: Dictionary) -> Array[Province]:
	var sea_zone: PackedInt32Array = tagged["sea_zone"]
	var features: PackedInt32Array = tagged["features"]

	var provinces: Array[Province] = []
	var tile_lists: Array = []
	for i in range(sizes.size()):
		var p := Province.new()
		p.id = i
		provinces.append(p)
		tile_lists.append(PackedInt32Array())

	for idx in range(assigned.size()):
		var pid := assigned[idx]
		if pid >= 0:
			tile_lists[pid].append(idx)

	for i in range(provinces.size()):
		var p := provinces[i]
		p.tiles = tile_lists[i]

		var neighbors: Dictionary = {}
		var zones: Dictionary = {}
		var sum_pos := Vector2.ZERO
		var elev_sum := 0.0
		for t in p.tiles:
			var col := t % MapGenerator.W
			var row := t / MapGenerator.W
			sum_pos += Hex.to_plane(col, row)
			elev_sum += elevation[t]
			if features[t] == FeatureTagger.Feature.ISLAND:
				p.is_island = true
			for n: int in nbr[t]:
				if land[n] == 0:
					p.is_coastal = true
					zones[sea_zone[n]] = true
				elif assigned[n] != i and assigned[n] >= 0:
					neighbors[assigned[n]] = true
		p.centroid = sum_pos / maxf(p.tiles.size(), 1)

		var nb_keys: Array = neighbors.keys()
		nb_keys.sort()
		p.land_neighbors = nb_keys

		var zone_keys: Array = zones.keys()
		zone_keys.sort()
		p.sea_zone_ids = PackedInt32Array(zone_keys)

		p.set_meta("mean_elevation", elev_sum / maxf(p.tiles.size(), 1))

	_assign_terrain(provinces)
	return provinces


## 평균 고도 순위로 산악/구릉/평지 분류. 절대 임계값이 아니라 순위라서 노이즈 파라미터에 흔들리지 않는다.
static func _assign_terrain(provinces: Array[Province]) -> void:
	var order: Array = range(provinces.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		var ea: float = provinces[a].get_meta("mean_elevation")
		var eb: float = provinces[b].get_meta("mean_elevation")
		if ea == eb:
			return a < b
		return ea > eb)

	var n := provinces.size()
	var mountain_cut := int(round(n * MOUNTAIN_TOP_PCT))
	var hill_cut := mountain_cut + int(round(n * HILL_NEXT_PCT))
	for rank in range(n):
		var p: Province = provinces[order[rank]]
		if rank < mountain_cut:
			p.set_terrain(Province.Terrain.MOUNTAIN)
		elif rank < hill_cut:
			p.set_terrain(Province.Terrain.HILL)
		else:
			p.set_terrain(Province.Terrain.PLAIN)
		p.remove_meta("mean_elevation")
