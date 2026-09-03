class_name EarthMapSource extends MapSource

## M13 고정 지구 지도. 원본 지리 파일은 빌드 타임에만 쓰고 런타임은 이 에셋만 읽는다.

const W := 440
const H := 200
const TOTAL := 88000
const LAND_TARGET := 25000
const LAT_MIN := -60.0
const LAT_MAX := 90.0
const ASSET_PATH := "res://data/world/earth_map.bin"
const MAGIC := "CEMAP13"
const FORMAT_VERSION := 2
const ELEVATION_NORMALIZER := 6000.0
## 기준 격자(150x100 노이즈) 대비 타일이 잘아진 배율. 프로빈스·해역 분할 규격이 이 값을 곱해 쓴다.
const GRANULARITY := 1.74

const MIN_COMPONENTS := 2
const TOP2_MIN_SIZE := 4500
const LARGEST_MAX_FRAC := 0.70
const MIN_TOTAL_COMPONENTS := 12

static var _baked: Dictionary = {}


## 지리는 상수라 seed 를 소비하지 않는다. seed 는 뒤의 국가·문화·인물 배치에만 쓰인다.
static func generate(world_seed: int) -> Dictionary:
	var result := _load_asset().duplicate()
	result["seed"] = world_seed
	result["base_seed"] = world_seed
	result["attempts"] = 1
	return result


static func generate_once(world_seed: int) -> Dictionary:
	return generate(world_seed)


static func _load_asset() -> Dictionary:
	if not _baked.is_empty():
		return _baked
	var file := FileAccess.open(ASSET_PATH, FileAccess.READ)
	assert(file != null, "M13 지구 지도 에셋을 열 수 없음: %s" % ASSET_PATH)
	var magic := file.get_buffer(7).get_string_from_ascii()
	file.get_8() # NUL terminator
	assert(magic == MAGIC, "M13 지구 지도 magic 불일치: %s" % magic)
	var version := file.get_16()
	var width := file.get_16()
	var height := file.get_16()
	var land_target := file.get_16()
	assert(version == FORMAT_VERSION, "M13 지구 지도 포맷 버전 불일치: %d" % version)
	assert(width == W and height == H, "M13 지구 지도 크기 불일치: %dx%d" % [width, height])
	assert(land_target == LAND_TARGET, "M13 지구 지도 육지 목표 불일치: %d" % land_target)

	var land := file.get_buffer(TOTAL)
	var elevation := PackedFloat32Array()
	elevation.resize(TOTAL)
	for i in range(TOTAL):
		elevation[i] = minf(float(file.get_16()) / ELEVATION_NORMALIZER, 1.0)
	var land_coverage := file.get_buffer(TOTAL)
	var longitude := PackedFloat32Array()
	longitude.resize(TOTAL)
	for i in range(TOTAL):
		longitude[i] = float(file.get_16()) / 100.0 - 180.0
	var latitude := PackedFloat32Array()
	latitude.resize(TOTAL)
	for i in range(TOTAL):
		latitude[i] = float(file.get_16()) / 100.0 + LAT_MIN
	var regions := file.get_buffer(TOTAL)
	var forced_features := file.get_buffer(TOTAL)
	# 실제 국경. 프로빈스 경계로만 쓰고 국가 배치는 여전히 시드가 정한다 (§M13.5).
	var country := PackedInt32Array()
	country.resize(TOTAL)
	for i in range(TOTAL):
		country[i] = file.get_16()
	file.close()

	var nbr := MapSource.neighbor_cache(W, H)
	var components := MapSource.land_components(land, nbr)
	var map_stats := MapSource.stats(land, components)
	var checks := {
		"land_target": map_stats["land_count"] == LAND_TARGET,
		"two_components": map_stats["component_count"] >= MIN_COMPONENTS,
		"top2_big_enough": map_stats["second"] >= TOP2_MIN_SIZE,
		"no_pangaea": map_stats["largest_frac"] <= LARGEST_MAX_FRAC,
		"island_variety": map_stats["component_count"] >= MIN_TOTAL_COMPONENTS,
	}
	_baked = {
		"source": "earth",
		"source_kind": MapSource.Kind.EARTH,
		"width": W,
		"height": H,
		"granularity": GRANULARITY,
		"land": land,
		"elevation": elevation,
		"land_coverage": land_coverage,
		"longitude": longitude,
		"latitude": latitude,
		"regions": regions,
		"forced_features": forced_features,
		"country": country,
		"components": components,
		"stats": map_stats,
		"checks": checks,
		"valid": not checks.values().has(false),
	}
	assert(_baked["valid"], "M13 지구 지도 빌드 검증 실패: %s" % [checks])
	return _baked
