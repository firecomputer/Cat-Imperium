extends SceneTree

## M13 구운 지구 지도·런타임 통합 회귀.


func _initialize() -> void:
	var first := MapSource.create_map(1, MapSource.Kind.EARTH)
	var second := MapSource.create_map(999, MapSource.Kind.EARTH)
	assert(first["width"] == 440 and first["height"] == 200)
	assert(first["land"].count(1) == 25000)
	assert(first["land"] == second["land"] and first["elevation"] == second["elevation"],
		"world_seed 가 고정 지리를 바꾸면 안 된다")
	assert(first["valid"], "지구 지도 빌드 불변식 실패: %s" % [first["checks"]])
	assert(first["stats"]["component_count"] >= 12)
	assert(first["stats"]["largest_frac"] <= 0.70)

	var forced_count := 0
	for feature in first["forced_features"]:
		if feature != MapSource.NO_FORCED_FEATURE:
			forced_count += 1
	assert(forced_count >= 6, "주요 요충지 6곳이 구운 에셋에 있어야 한다")

	var manifest = JSON.parse_string(FileAccess.get_file_as_string(
		"res://data/world/earth_map.json"))
	assert(manifest is Dictionary)
	assert(float(manifest["named_island_preservation"]) >= 0.90)
	assert(manifest["chokepoints"].size() >= 6)

	var world := WorldState.create(7, MapSource.Kind.EARTH)
	assert(world.map_source_name == "earth")
	assert(world.map_width == 440 and world.map_height == 200)
	assert(world.provinces.size() >= 750 and world.provinces.size() <= 950,
		"프로빈스 규모 가정이 무너짐: %d" % world.provinces.size())
	var covered := 0
	var regions := {}
	for p in world.provinces:
		assert(p.size() >= 1 and p.size() <= ProvinceSplitter.max_tiles(EarthMapSource.GRANULARITY))
		assert(p.region >= 0, "지구 프로빈스에 지역 라벨이 빠짐: %d" % p.id)
		covered += p.size()
		regions[p.region] = true
	assert(covered == 25000, "프로빈스 고아/중복으로 육지 합계가 달라짐: %d" % covered)
	assert(regions.size() >= 7, "지역 라벨 분포가 지나치게 좁음: %s" % [regions])
	assert(world.nations.size() == NationPlacer.nation_count(25000, EarthMapSource.GRANULARITY),
		"지구 지도 국가 수가 세계 크기 배율과 어긋남: %d" % world.nations.size())
	for n in world.nations:
		assert(n.start_region >= 0, "건국 국가의 시작 지역이 비어 있음: %d" % n.id)

	var noise := MapSource.create_map(7, MapSource.Kind.NOISE)
	assert(noise["width"] == 100 and noise["height"] == 150)
	assert(noise["land"].count(1) == 5000, "NoiseMapSource 회귀 불변식 실패")
	print("earth map tests: PASS")
	quit(0)
