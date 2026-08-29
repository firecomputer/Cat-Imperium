class_name MapGenerator extends RefCounted

## 헥스 지형 생성기.
## 임계값이 아니라 "순위 선택"을 쓴다 — 노이즈를 어떻게 만지든 육지는 항상 정확히 LAND_TARGET 개.

const W := 100
const H := 150
const TOTAL := 15000
const LAND_TARGET := 5000
const MAX_ATTEMPTS := 12

# --- 고도장 합성 가중치 ---
const WARP_WEIGHT := 0.45
const RIDGE_WEIGHT := 0.25
const DETAIL_WEIGHT := 0.12
const EDGE_MARGIN := 12.0
const EDGE_STRENGTH := 1.4

# --- 대륙 씨앗 ---
const BIG_SEEDS_MIN := 2
const BIG_SEEDS_MAX := 3
const BIG_RADIUS_MIN := 26.0
const BIG_RADIUS_MAX := 40.0
## 씨앗 개수별 반경대. 3개일 때 큰 반경을 쓰면 서로 붙어 판게아가 된다.
const BIG_RADIUS_BY_COUNT := {2: Vector2(33.0, 40.0), 3: Vector2(26.0, 32.0)}
const BIG_CANDIDATES := 64
const BIG_RADIUS_JITTER := 0.12  # 대륙 간 크기 격차를 줄여 최대 대륙 점유율을 낮춘다
const SMALL_SEEDS_MIN := 8
const SMALL_SEEDS_MAX := 14
const SMALL_RADIUS_MIN := 4.0
const SMALL_RADIUS_MAX := 11.0
const SMALL_STRENGTH_MIN := 0.45
const SMALL_STRENGTH_MAX := 0.75

# --- 후처리 ---
const SPECK_REMOVE_RATE := 0.7

# --- 검증 조건 ---
const MIN_COMPONENTS := 2
const TOP2_MIN_SIZE := 900
const LARGEST_MAX_FRAC := 0.70
const MIN_TOTAL_COMPONENTS := 12

static var _neighbor_cache: Array = []


## 검증을 통과할 때까지 시드를 바꿔가며 최대 MAX_ATTEMPTS 회 재생성.
static func generate(world_seed: int) -> Dictionary:
	var result := {}
	for attempt in range(MAX_ATTEMPTS):
		result = generate_once(world_seed + attempt * 7919)
		result["attempts"] = attempt + 1
		result["base_seed"] = world_seed
		if result["valid"]:
			return result
	return result


## 재시도 없이 1회만 생성. 검증 통과율 측정용.
static func generate_once(world_seed: int) -> Dictionary:
	var rng := RngPool.new(world_seed).get_rng("worldgen")
	var nbr := neighbor_cache()

	var elevation := _build_elevation(rng)
	var land := _rank_select(elevation)
	_cleanup(land, elevation, rng, nbr)

	var components := land_components(land, nbr)
	var stats := _stats(land, components)
	var checks := _validate(stats)

	return {
		"seed": world_seed,
		"attempts": 1,
		"base_seed": world_seed,
		"land": land,
		"elevation": elevation,
		"components": components,
		"stats": stats,
		"checks": checks,
		"valid": not checks.values().has(false),
	}


static func neighbor_cache() -> Array:
	if _neighbor_cache.is_empty():
		_neighbor_cache = Hex.build_neighbor_cache(W, H)
	return _neighbor_cache


# ---------------------------------------------------------------- 고도장

static func _build_elevation(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var mask := _continent_mask(rng)

	# 도메인 워프가 핵심이다. 이것 없이는 옥타브를 아무리 쌓아도 감자 모양 대륙만 나온다.
	var warp := FastNoiseLite.new()
	warp.seed = rng.randi()
	warp.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	warp.frequency = 0.020
	warp.fractal_octaves = 5
	warp.fractal_lacunarity = 2.1
	warp.domain_warp_enabled = true
	warp.domain_warp_amplitude = 55.0
	warp.domain_warp_frequency = 0.012

	var ridge := FastNoiseLite.new()
	ridge.seed = rng.randi()
	ridge.noise_type = FastNoiseLite.TYPE_SIMPLEX
	ridge.frequency = 0.035
	ridge.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridge.fractal_octaves = 4

	var detail := FastNoiseLite.new()
	detail.seed = rng.randi()
	detail.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	detail.frequency = 0.11

	var elevation := PackedFloat32Array()
	elevation.resize(TOTAL)
	for row in range(H):
		for col in range(W):
			var p := Hex.to_plane(col, row)
			var e := mask[row * W + col]
			e += warp.get_noise_2d(p.x, p.y) * WARP_WEIGHT
			e += ridge.get_noise_2d(p.x, p.y) * RIDGE_WEIGHT
			e += detail.get_noise_2d(p.x, p.y) * DETAIL_WEIGHT
			e -= _edge_falloff(col, row)
			elevation[row * W + col] = e
	return elevation


## 지도 테두리는 바다로 밀어낸다.
static func _edge_falloff(col: int, row: int) -> float:
	var dx := float(mini(col, W - 1 - col)) / EDGE_MARGIN
	var dy := float(mini(row, H - 1 - row)) / EDGE_MARGIN
	var d := minf(1.0, minf(dx, dy))
	return (1.0 - d) * EDGE_STRENGTH


## 씨앗 합성은 sum 이 아니라 max — 겹친 씨앗이 뭉쳐 감자가 되는 것을 막는다.
static func _continent_mask(rng: RandomNumberGenerator) -> PackedFloat32Array:
	var mask := PackedFloat32Array()
	mask.resize(TOTAL)
	mask.fill(0.0)

	var plane_h := H * Hex.SQRT3_2
	var centers: Array[Vector2] = []
	var radii: Array[float] = []
	var strengths: Array[float] = []

	# 대륙 씨앗: 후보를 여러 개 뽑아 기존 씨앗에서 가장 먼 것을 고른다(최원점 배치).
	# 단순 기각 샘플링은 반경을 줄여야 배치가 되고, 반경이 줄면 노이즈가 대륙을 이어붙여 판게아가 된다.
	var big_count := rng.randi_range(BIG_SEEDS_MIN, BIG_SEEDS_MAX)
	var band: Vector2 = BIG_RADIUS_BY_COUNT[big_count]
	var base_radius := rng.randf_range(band.x, band.y)
	for i in range(big_count):
		var best := Vector2.ZERO
		var best_score := -INF
		for k in range(BIG_CANDIDATES):
			var c := Vector2(
				rng.randf_range(W * 0.18, W * 0.82),
				rng.randf_range(plane_h * 0.14, plane_h * 0.86)
			)
			var score := INF
			for other in centers:
				score = minf(score, c.distance_to(other))
			if score > best_score:
				best_score = score
				best = c
		centers.append(best)
		radii.append(clampf(base_radius * rng.randf_range(1.0 - BIG_RADIUS_JITTER, 1.0 + BIG_RADIUS_JITTER),
			BIG_RADIUS_MIN, BIG_RADIUS_MAX))
		strengths.append(1.0)

	var small_count := rng.randi_range(SMALL_SEEDS_MIN, SMALL_SEEDS_MAX)
	for i in range(small_count):
		centers.append(Vector2(
			rng.randf_range(W * 0.08, W * 0.92),
			rng.randf_range(plane_h * 0.08, plane_h * 0.92)
		))
		radii.append(rng.randf_range(SMALL_RADIUS_MIN, SMALL_RADIUS_MAX))
		strengths.append(rng.randf_range(SMALL_STRENGTH_MIN, SMALL_STRENGTH_MAX))

	for row in range(H):
		for col in range(W):
			var p := Hex.to_plane(col, row)
			var v := 0.0
			for i in range(centers.size()):
				var t: float = p.distance_to(centers[i]) / radii[i]
				v = maxf(v, strengths[i] * smoothstep(1.0, 0.0, t))
			mask[row * W + col] = v
	return mask


# ---------------------------------------------------------------- 순위 선택

static func _rank_select(elevation: PackedFloat32Array) -> PackedByteArray:
	var order: Array = range(TOTAL)
	order.sort_custom(func(a: int, b: int) -> bool:
		if elevation[a] == elevation[b]:
			return a < b
		return elevation[a] > elevation[b])

	var land := PackedByteArray()
	land.resize(TOTAL)
	land.fill(0)
	for i in range(LAND_TARGET):
		land[order[i]] = 1
	return land


# ---------------------------------------------------------------- 후처리

static func _cleanup(land: PackedByteArray, elevation: PackedFloat32Array,
		rng: RandomNumberGenerator, nbr: Array) -> void:
	# 1. 고립된 1타일 섬의 70% 만 제거 (30% 는 남겨 점섬의 맛을 유지)
	for idx in range(TOTAL):
		if land[idx] == 0:
			continue
		var alone := true
		for n: int in nbr[idx]:
			if land[n] == 1:
				alone = false
				break
		if alone and rng.randf() < SPECK_REMOVE_RATE:
			land[idx] = 0

	# 2. 육지에 둘러싸인 1타일 바다(호수)는 메운다
	for idx in range(TOTAL):
		if land[idx] == 1:
			continue
		var ns: PackedInt32Array = nbr[idx]
		if ns.size() < 6:
			continue
		var surrounded := true
		for n in ns:
			if land[n] == 0:
				surrounded = false
				break
		if surrounded:
			land[idx] = 1

	# 3. 정확히 LAND_TARGET 으로 복원
	_restore_count(land, elevation, nbr)


static func _restore_count(land: PackedByteArray, elevation: PackedFloat32Array, nbr: Array) -> void:
	var count := _count_land(land)

	while count < LAND_TARGET:
		var cands := _coastal(land, nbr, 0)  # 육지에 인접한 바다
		if cands.is_empty():
			break
		cands.sort_custom(func(a: int, b: int) -> bool:
			if elevation[a] == elevation[b]:
				return a < b
			return elevation[a] > elevation[b])
		var take: int = mini(LAND_TARGET - count, cands.size())
		for i in range(take):
			land[cands[i]] = 1
		count += take

	while count > LAND_TARGET:
		var cands := _coastal(land, nbr, 1)  # 바다에 인접한 육지
		if cands.is_empty():
			break
		cands.sort_custom(func(a: int, b: int) -> bool:
			if elevation[a] == elevation[b]:
				return a < b
			return elevation[a] < elevation[b])
		var take: int = mini(count - LAND_TARGET, cands.size())
		for i in range(take):
			land[cands[i]] = 0
		count -= take


## want 값 타일 중 반대 값 이웃을 가진 것들.
static func _coastal(land: PackedByteArray, nbr: Array, want: int) -> Array:
	var out: Array = []
	var other := 1 - want
	for idx in range(TOTAL):
		if land[idx] != want:
			continue
		for n: int in nbr[idx]:
			if land[n] == other:
				out.append(idx)
				break
	return out


static func _count_land(land: PackedByteArray) -> int:
	var c := 0
	for v in land:
		c += v
	return c


# ---------------------------------------------------------------- 컴포넌트 / 검증

## 육지 연결 성분. 반환값[i] = 타일 i 의 컴포넌트 id (바다는 -1).
static func land_components(land: PackedByteArray, nbr: Array) -> PackedInt32Array:
	var comp := PackedInt32Array()
	comp.resize(TOTAL)
	comp.fill(-1)
	var next_id := 0
	for start in range(TOTAL):
		if land[start] == 0 or comp[start] != -1:
			continue
		comp[start] = next_id
		var stack: Array[int] = [start]
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			for n: int in nbr[cur]:
				if land[n] == 1 and comp[n] == -1:
					comp[n] = next_id
					stack.append(n)
		next_id += 1
	return comp


static func _stats(land: PackedByteArray, comp: PackedInt32Array) -> Dictionary:
	var sizes: Dictionary = {}
	for idx in range(TOTAL):
		var c := comp[idx]
		if c >= 0:
			sizes[c] = int(sizes.get(c, 0)) + 1

	var size_list: Array = sizes.values()
	size_list.sort()
	size_list.reverse()

	var land_count := _count_land(land)
	var largest: int = size_list[0] if size_list.size() > 0 else 0
	var second: int = size_list[1] if size_list.size() > 1 else 0
	return {
		"land_count": land_count,
		"component_count": size_list.size(),
		"largest": largest,
		"second": second,
		"largest_frac": float(largest) / float(maxi(land_count, 1)),
		"sizes": size_list,
	}


static func _validate(stats: Dictionary) -> Dictionary:
	return {
		"two_components": stats["component_count"] >= MIN_COMPONENTS,
		"top2_big_enough": stats["second"] >= TOP2_MIN_SIZE,
		"no_pangaea": stats["largest_frac"] <= LARGEST_MAX_FRAC,
		"island_variety": stats["component_count"] >= MIN_TOTAL_COMPONENTS,
	}
