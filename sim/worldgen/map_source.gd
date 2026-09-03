class_name MapSource extends RefCounted

## 지도 소스 공통 계약과 격자 위상 유틸.
## 구현체는 generate()/generate_once() 결과에 width, height, land, elevation 을 넣는다.

enum Kind { EARTH, NOISE }

const NO_FORCED_FEATURE := 255
const REGION_NONE := 255
const REGION_NAMES := [
	"North America", "South America", "Europe", "North Africa & West Asia",
	"Sub-Saharan Africa", "South Asia", "East Asia", "Southeast Asia & Oceania",
	"North Eurasia",
]

static var _neighbor_caches: Dictionary = {}


static func default_kind() -> int:
	var configured := OS.get_environment("CAT_EMPIRE_MAP_SOURCE").to_lower()
	return Kind.NOISE if configured == "noise" else Kind.EARTH


static func parse_kind(value: String) -> int:
	match value.to_lower():
		"earth":
			return Kind.EARTH
		"noise":
			return Kind.NOISE
		_:
			push_error("알 수 없는 지도 소스: %s (earth|noise)" % value)
			return -1


static func kind_name(kind: int) -> String:
	return "noise" if kind == Kind.NOISE else "earth"


static func region_name(region: int) -> String:
	return REGION_NAMES[region] if region >= 0 and region < REGION_NAMES.size() else "Unmapped"


## load() 를 쓰는 이유: 구현체가 MapSource 를 상속하므로 여기서 preload 하면 순환 의존이다.
static func source_script(kind: int) -> Script:
	var path := "res://sim/worldgen/noise_map_source.gd" if kind == Kind.NOISE \
		else "res://sim/worldgen/earth_map_source.gd"
	return load(path)


static func create_map(world_seed: int, kind: int) -> Dictionary:
	return source_script(kind).generate(world_seed)


static func create_map_once(world_seed: int, kind: int) -> Dictionary:
	return source_script(kind).generate_once(world_seed)


static func neighbor_cache(width: int, height: int) -> Array:
	var key := "%dx%d" % [width, height]
	if not _neighbor_caches.has(key):
		_neighbor_caches[key] = Hex.build_neighbor_cache(width, height)
	return _neighbor_caches[key]


## 육지 연결 성분. 반환값[i] = 타일 i 의 컴포넌트 id (바다는 -1).
static func land_components(land: PackedByteArray, nbr: Array) -> PackedInt32Array:
	var comp := PackedInt32Array()
	comp.resize(land.size())
	comp.fill(-1)
	var next_id := 0
	for start in range(land.size()):
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


static func stats(land: PackedByteArray, comp: PackedInt32Array) -> Dictionary:
	var sizes: Dictionary = {}
	var land_count := 0
	for idx in range(land.size()):
		if land[idx] == 0:
			continue
		land_count += 1
		var c := comp[idx]
		sizes[c] = int(sizes.get(c, 0)) + 1
	var size_list: Array = sizes.values()
	size_list.sort()
	size_list.reverse()
	var largest: int = size_list[0] if not size_list.is_empty() else 0
	var second: int = size_list[1] if size_list.size() > 1 else 0
	return {
		"land_count": land_count,
		"component_count": size_list.size(),
		"largest": largest,
		"second": second,
		"largest_frac": float(largest) / float(maxi(land_count, 1)),
		"sizes": size_list,
	}
