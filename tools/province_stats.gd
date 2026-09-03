class_name ProvinceStats extends RefCounted

## 분할 결과 검증 지표. 덤프 도구와 배치 도구가 공유한다.


static func summarize(provinces: Array[Province], land: PackedByteArray,
		tagged: Dictionary) -> Dictionary:
	var land_comp: PackedInt32Array = tagged["land_comp"]
	var comp_sizes: Dictionary = tagged["comp_sizes"]
	var features: PackedInt32Array = tagged["features"]
	var country: PackedInt32Array = tagged.get("country", PackedInt32Array())
	var has_country := country.size() == land.size()
	var granularity := float(tagged.get("granularity", 1.0))
	var cap := ProvinceSplitter.max_tiles(granularity)
	var island_max := FeatureTagger.island_max_tiles(granularity)

	var covered := PackedByteArray()
	covered.resize(land.size())
	covered.fill(0)

	var min_size := 1 << 30
	var max_size := 0
	var total_tiles := 0
	var islands := 0
	var double_assigned := 0
	# 작은 컴포넌트(섬) 별로 몇 개의 프로빈스가 걸쳐 있는지.
	# 국경이 있으면 한 섬을 여러 나라가 나눠 가지므로 (컴포넌트, 국가) 쌍으로 센다.
	var comp_province_count: Dictionary = {}

	for p in provinces:
		min_size = mini(min_size, p.size())
		max_size = maxi(max_size, p.size())
		total_tiles += p.size()
		if p.is_island:
			islands += 1
		var comps_here: Dictionary = {}
		for t in p.tiles:
			if covered[t] == 1:
				double_assigned += 1
			covered[t] = 1
			comps_here[land_comp[t] * 65536 + (country[t] if has_country else 0)] = true
		for c in comps_here.keys():
			comp_province_count[c] = int(comp_province_count.get(c, 0)) + 1

	var orphans := 0
	for idx in range(land.size()):
		if land[idx] == 1 and covered[idx] == 0:
			orphans += 1

	# 섬(컴포넌트 ≤ ISLAND_MAX_TILES) 위의 나라별 조각이 정확히 1개의 프로빈스인지
	var island_comp_total := 0
	var island_comp_ok := 0
	for key in comp_province_count.keys():
		if int(comp_sizes[int(key) / 65536]) > island_max:
			continue
		island_comp_total += 1
		if int(comp_province_count[key]) == 1:
			island_comp_ok += 1

	var feature_counts: Dictionary = {}
	for f in features:
		feature_counts[f] = int(feature_counts.get(f, 0)) + 1

	return {
		"count": provinces.size(),
		"min_size": min_size if provinces.size() > 0 else 0,
		"max_size": max_size,
		"mean_size": float(total_tiles) / maxf(provinces.size(), 1),
		"orphan_tiles": orphans,
		"double_assigned": double_assigned,
		"island_provinces": islands,
		"island_comp_total": island_comp_total,
		"island_comp_ok": island_comp_ok,
		"feature_counts": feature_counts,
		"max_tiles": cap,
		"size_ok": min_size >= 1 and max_size <= cap,
	}
