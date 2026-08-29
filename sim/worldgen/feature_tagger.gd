class_name FeatureTagger extends RefCounted

## 타일 단위 지형 특징 태깅 + 바다 분지(sea_basin) 라벨링.

enum Feature { INLAND, COAST, ISTHMUS, STRAIT, ISLAND }

const ISLAND_MAX_TILES := 30


## 반환: {
##   "features": PackedInt32Array,      타일별 Feature
##   "land_comp": PackedInt32Array,     육지 컴포넌트 id (바다 -1)
##   "sea_basin": PackedInt32Array,     바다 분지 id (육지 -1)
##   "comp_sizes": Dictionary,          컴포넌트 id → 타일 수
## }
static func tag(land: PackedByteArray, nbr: Array) -> Dictionary:
	var total := land.size()
	var land_comp := MapGenerator.land_components(land, nbr)
	var sea_basin := _sea_basins(land, nbr)

	var comp_sizes: Dictionary = {}
	for idx in range(total):
		var c := land_comp[idx]
		if c >= 0:
			comp_sizes[c] = int(comp_sizes.get(c, 0)) + 1

	var isthmus := _isthmuses(land, nbr, land_comp)

	var features := PackedInt32Array()
	features.resize(total)
	for idx in range(total):
		features[idx] = _classify(idx, land, nbr, land_comp, comp_sizes, isthmus)

	return {
		"features": features,
		"land_comp": land_comp,
		"sea_basin": sea_basin,
		"comp_sizes": comp_sizes,
	}


static func _classify(idx: int, land: PackedByteArray, nbr: Array, land_comp: PackedInt32Array,
		comp_sizes: Dictionary, isthmus: Dictionary) -> int:
	# 열린 바다는 별도 enum 값이 없어 INLAND 로 둔다 (문서 enum 준수).
	if land[idx] == 0:
		return Feature.STRAIT if _is_strait(idx, land, nbr, land_comp, comp_sizes) else Feature.INLAND
	if isthmus.has(idx):
		return Feature.ISTHMUS
	if int(comp_sizes[land_comp[idx]]) <= ISLAND_MAX_TILES:
		return Feature.ISLAND
	for n: int in nbr[idx]:
		if land[n] == 0:
			return Feature.COAST
	return Feature.INLAND


## 바다 타일인데 서로 다른 대륙(섬 제외) 두 개 이상에 인접 → 해군 통제권/교역로 병목.
static func _is_strait(idx: int, land: PackedByteArray, nbr: Array, land_comp: PackedInt32Array,
		comp_sizes: Dictionary) -> bool:
	var seen: Array[int] = []
	for n: int in nbr[idx]:
		if land[n] == 0:
			continue
		var c := land_comp[n]
		if int(comp_sizes[c]) <= ISLAND_MAX_TILES:
			continue
		if not seen.has(c):
			seen.append(c)
			if seen.size() >= 2:
				return true
	return false


## 육지 관절점(articulation point). 제거하면 컴포넌트가 쪼개지는 타일.
## 5000 타일 전부 검사하면 느리다 — 육지 이웃이 2~3개인 타일만 후보로 거른 뒤 플러드필한다.
static func _isthmuses(land: PackedByteArray, nbr: Array, land_comp: PackedInt32Array) -> Dictionary:
	var out: Dictionary = {}
	for idx in range(land.size()):
		if land[idx] == 0:
			continue
		var land_nbrs: Array[int] = []
		for n: int in nbr[idx]:
			if land[n] == 1:
				land_nbrs.append(n)
		if land_nbrs.size() < 2 or land_nbrs.size() > 3:
			continue
		if _splits_component(idx, land_nbrs, land, nbr, land_comp):
			out[idx] = true
	return out


## idx 를 지운 상태에서 land_nbrs[0] 으로부터 나머지 이웃 전부에 닿는지 확인.
static func _splits_component(idx: int, land_nbrs: Array[int], land: PackedByteArray,
		nbr: Array, land_comp: PackedInt32Array) -> bool:
	var targets: Dictionary = {}
	for i in range(1, land_nbrs.size()):
		targets[land_nbrs[i]] = true

	var comp := land_comp[idx]
	var seen: Dictionary = {land_nbrs[0]: true}
	var stack: Array[int] = [land_nbrs[0]]
	while not stack.is_empty():
		var cur: int = stack.pop_back()
		targets.erase(cur)
		if targets.is_empty():
			return false
		for n: int in nbr[cur]:
			if n == idx or land[n] == 0 or land_comp[n] != comp or seen.has(n):
				continue
			seen[n] = true
			stack.append(n)
	return true


static func _sea_basins(land: PackedByteArray, nbr: Array) -> PackedInt32Array:
	var basin := PackedInt32Array()
	basin.resize(land.size())
	basin.fill(-1)
	var next_id := 0
	for start in range(land.size()):
		if land[start] == 1 or basin[start] != -1:
			continue
		basin[start] = next_id
		var stack: Array[int] = [start]
		while not stack.is_empty():
			var cur: int = stack.pop_back()
			for n: int in nbr[cur]:
				if land[n] == 0 and basin[n] == -1:
					basin[n] = next_id
					stack.append(n)
		next_id += 1
	return basin
