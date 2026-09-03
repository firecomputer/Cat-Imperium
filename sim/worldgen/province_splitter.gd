class_name ProvinceSplitter extends RefCounted

## 제약 있는 성장으로 육지를 프로빈스로 쪼갠다. 보로노이는 크기 제어가 불가능해서 쓰지 않는다.
## 기준 격자(granularity 1.0) 목표 평균 17타일, 하드 상한 30타일.
## 실제 값은 MapSource 가 주는 granularity 배율을 곱해 쓴다 — 타일이 잘아지면
## 같은 실제 면적의 프로빈스가 더 많은 타일을 차지하기 때문이다.

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


static func max_tiles(granularity: float) -> int:
	return int(round(MAX_TILES * granularity))


## land/elevation 은 MapSource 결과, tagged 는 FeatureTagger.tag() 결과.
static func split(land: PackedByteArray, elevation: PackedFloat32Array,
		tagged: Dictionary, rng: RandomNumberGenerator, width: int, nbr: Array) -> Array[Province]:
	var total := land.size()
	var land_comp: PackedInt32Array = tagged["land_comp"]
	var country: PackedInt32Array = tagged.get("country", PackedInt32Array())
	if country.size() == total:
		# 실제 국경이 있으면 프로빈스는 국경을 넘지 않는다. 성장·고아 흡수·분할이
		# 전부 이 배열 하나만 보므로 그룹 정의를 바꾸는 것으로 충분하다.
		land_comp = _country_components(land, country, nbr)
	var granularity := float(tagged.get("granularity", 1.0))
	var cap := max_tiles(granularity)

	var barriers := _build_barriers(land, elevation, nbr, rng)

	var assigned := PackedInt32Array()
	assigned.resize(total)
	assigned.fill(-1)
	var sizes: Array[int] = []      # 프로빈스 id → 타일 수

	var comp_tiles := _tiles_by_component(land_comp, total)
	for comp_id in comp_tiles.keys():
		var tiles: Array = comp_tiles[comp_id]
		if tiles.size() <= cap:
			# 섬 요구사항 자동 충족: 작은 컴포넌트는 통째로 1 프로빈스
			var pid := sizes.size()
			sizes.append(0)
			for t: int in tiles:
				assigned[t] = pid
				sizes[pid] += 1
			continue
		_grow(tiles, comp_id, land_comp, nbr, barriers, assigned, sizes, rng, width, granularity)

	_absorb_orphans(tiles_flat(comp_tiles), land_comp, nbr, assigned, sizes, granularity)
	var provinces := _build_provinces(assigned, sizes, land, elevation, nbr, tagged, width)
	# 지형과 해안이 정해진 뒤라야 인프라 상한을 매길 수 있다.
	for p in provinces:
		p.assign_infra_cap(rng.randfn(0.0, Province.INFRA_CAP_JITTER))
	return provinces


## 육지 연결 성분을 국가 단위로 다시 쪼갠다. 같은 섬이라도 나라가 다르면 다른 그룹.
static func _country_components(land: PackedByteArray, country: PackedInt32Array,
		nbr: Array) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(land.size())
	out.fill(-1)
	var next_id := 0
	for start in range(land.size()):
		if land[start] == 0 or out[start] != -1:
			continue
		out[start] = next_id
		var stack: Array[int] = [start]
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			for n: int in nbr[cur]:
				if land[n] == 1 and out[n] == -1 and country[n] == country[cur]:
					out[n] = next_id
					stack.append(n)
		next_id += 1
	return out


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
		rng: RandomNumberGenerator, width: int, granularity: float) -> void:
	var total := land_comp.size()
	var seeds := _poisson_seeds(tiles, rng, width, granularity)
	var target_lo := int(round(TARGET_MIN * granularity))
	var target_hi := int(round(TARGET_MAX * granularity))

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
		target.append(rng.randi_range(target_lo, target_hi))

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


static func _poisson_seeds(tiles: Array, rng: RandomNumberGenerator, width: int,
		granularity: float) -> Array[int]:
	var want := maxi(1, int(round(tiles.size() / (AVG_TARGET * granularity))))
	var min_dist := int(round(SEED_MIN_DIST * sqrt(granularity)))
	var seeds: Array[int] = []
	var seed_coords: Array[Vector2i] = []
	var tries := want * SEED_TRIES_PER_SEED
	while seeds.size() < want and tries > 0:
		tries -= 1
		var t: int = tiles[rng.randi_range(0, tiles.size() - 1)]
		var c := Vector2i(t % width, t / width)
		var ok := true
		for other in seed_coords:
			if Hex.distance(c.x, c.y, other.x, other.y) < min_dist:
				ok = false
				break
		if ok:
			seeds.append(t)
			seed_coords.append(c)
	return seeds


# ---------------------------------------------------------------- 고아 타일 흡수

static func _absorb_orphans(all_tiles: Array, land_comp: PackedInt32Array, nbr: Array,
		assigned: PackedInt32Array, sizes: Array[int], granularity: float) -> void:
	for start: int in all_tiles:
		if assigned[start] != -1:
			continue
		var cluster := _unassigned_cluster(start, land_comp, nbr, assigned)
		_place_cluster(cluster, land_comp, nbr, assigned, sizes, granularity)


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


## 상한 이하면 가장 작은 인접 프로빈스에 흡수, 안 들어가면 독립 프로빈스. 초과면 먼저 쪼갠다.
static func _place_cluster(cluster: Array[int], land_comp: PackedInt32Array, nbr: Array,
		assigned: PackedInt32Array, sizes: Array[int], granularity: float) -> void:
	var cap := max_tiles(granularity)
	if cluster.size() > cap:
		for chunk in _chunk(cluster, nbr, granularity):
			_place_cluster(chunk, land_comp, nbr, assigned, sizes, granularity)
		return

	var host := _smallest_adjacent(cluster, land_comp, nbr, assigned, sizes)
	var pid := host
	if host == -1 or sizes[host] + cluster.size() > cap:
		pid = sizes.size()
		sizes.append(0)
	for t in cluster:
		assigned[t] = pid
		sizes[pid] += 1


## 그룹 밖으로는 흡수하지 않는다. land_comp 가 국경으로 갈린 그룹이면
## 이 조건이 프로빈스가 국경을 넘지 않게 막는 마지막 관문이다.
static func _smallest_adjacent(cluster: Array[int], land_comp: PackedInt32Array, nbr: Array,
		assigned: PackedInt32Array, sizes: Array[int]) -> int:
	var comp := land_comp[cluster[0]]
	var best := -1
	for t in cluster:
		for n: int in nbr[t]:
			var pid := assigned[n]
			if pid < 0 or land_comp[n] != comp:
				continue
			if best == -1 or sizes[pid] < sizes[best] or (sizes[pid] == sizes[best] and pid < best):
				best = pid
	return best


static func _chunk(cluster: Array[int], nbr: Array, granularity: float) -> Array:
	var chunk_size := int(round(CHUNK_SIZE * granularity))
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
		while not stack.is_empty() and piece.size() < chunk_size:
			var cur: int = stack.pop_back()
			piece.append(cur)
			for n: int in nbr[cur]:
				if pool.has(n) and piece.size() + stack.size() < chunk_size:
					pool.erase(n)
					stack.append(n)
		piece.sort()
		out.append(piece)
	return out


# ---------------------------------------------------------------- Province 객체 구성

static func _build_provinces(assigned: PackedInt32Array, sizes: Array[int], land: PackedByteArray,
		elevation: PackedFloat32Array, nbr: Array, tagged: Dictionary,
		width: int) -> Array[Province]:
	var sea_zone: PackedInt32Array = tagged["sea_zone"]
	var features: PackedInt32Array = tagged["features"]
	var regions: PackedByteArray = tagged.get("regions", PackedByteArray())
	var longitude: PackedFloat32Array = tagged.get("longitude", PackedFloat32Array())
	var latitude: PackedFloat32Array = tagged.get("latitude", PackedFloat32Array())

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
		var region_votes: Dictionary = {}
		var sum_pos := Vector2.ZERO
		var elev_sum := 0.0
		var lon_sin := 0.0
		var lon_cos := 0.0
		var lat_sum := 0.0
		var geo_count := 0
		for t in p.tiles:
			var col := t % width
			var row := t / width
			sum_pos += Hex.to_plane(col, row)
			elev_sum += elevation[t]
			if regions.size() == land.size() and regions[t] != MapSource.REGION_NONE:
				var region := int(regions[t])
				region_votes[region] = int(region_votes.get(region, 0)) + 1
			if longitude.size() == land.size() and latitude.size() == land.size():
				var lon_rad := deg_to_rad(longitude[t])
				lon_sin += sin(lon_rad)
				lon_cos += cos(lon_rad)
				lat_sum += latitude[t]
				geo_count += 1
			if features[t] == FeatureTagger.Feature.ISLAND:
				p.is_island = true
			for n: int in nbr[t]:
				if land[n] == 0:
					p.is_coastal = true
					zones[sea_zone[n]] = true
				elif assigned[n] != i and assigned[n] >= 0:
					neighbors[assigned[n]] = true
		p.centroid = sum_pos / maxf(p.tiles.size(), 1)
		if not region_votes.is_empty():
			var region_order: Array = region_votes.keys()
			region_order.sort_custom(func(a: int, b: int) -> bool:
				if region_votes[a] == region_votes[b]:
					return a < b
				return region_votes[a] > region_votes[b])
			p.region = region_order[0]
		if geo_count > 0:
			p.longitude = rad_to_deg(atan2(lon_sin, lon_cos))
			p.latitude = lat_sum / geo_count

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
