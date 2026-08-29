extends SceneTree

## 시드 다수에 대해 프로빈스 분할 규격을 검증한다.
##
##   godot --headless --script res://tools/batch_provinces.gd -- --runs 100 --out res://out/provinces.csv


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 100))
	var seed0 := int(args.get("seed0", 1))
	var out_path: String = args.get("out", "res://out/provinces.csv")

	var lines := PackedStringArray(["seed,provinces,min_size,max_size,mean_size,orphans,"
		+ "double_assigned,island_comps,island_comps_ok,isthmus,strait"])

	var fail_size := 0
	var fail_orphan := 0
	var fail_island := 0
	var count_sum := 0
	var mean_sum := 0.0

	for i in range(runs):
		var s := seed0 + i
		var map: Dictionary = MapGenerator.generate(s)
		var nbr := MapGenerator.neighbor_cache()
		var tagged := FeatureTagger.tag(map["land"], nbr)
		var rng := RngPool.new(map["seed"]).get_rng("province_split")
		var provinces := ProvinceSplitter.split(map["land"], map["elevation"], tagged, rng)
		var st := ProvinceStats.summarize(provinces, map["land"], tagged)
		var fc: Dictionary = st["feature_counts"]

		lines.append(",".join(PackedStringArray([str(s), str(st["count"]), str(st["min_size"]),
			str(st["max_size"]), "%.2f" % st["mean_size"], str(st["orphan_tiles"]),
			str(st["double_assigned"]), str(st["island_comp_total"]), str(st["island_comp_ok"]),
			str(fc.get(FeatureTagger.Feature.ISTHMUS, 0)),
			str(fc.get(FeatureTagger.Feature.STRAIT, 0))])))

		if not st["size_ok"]:
			fail_size += 1
		if st["orphan_tiles"] > 0 or st["double_assigned"] > 0:
			fail_orphan += 1
		if st["island_comp_ok"] != st["island_comp_total"]:
			fail_island += 1
		count_sum += st["count"]
		mean_sum += st["mean_size"]

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_error("CSV 저장 실패: %s" % out_path)
		quit(1)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()

	print("runs=%d" % runs)
	print("크기 1~30 위반          : %d" % fail_size)
	print("고아/중복 타일 있는 시드 : %d" % fail_orphan)
	print("섬이 독립 프로빈스 아님  : %d" % fail_island)
	print("프로빈스 수 평균 %.1f, 타일 평균 %.1f" % [float(count_sum) / runs, mean_sum / runs])
	print("wrote %s" % ProjectSettings.globalize_path(out_path))
	quit(0)


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--"):
			var key := a.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[key] = argv[i + 1]
				i += 1
			else:
				out[key] = true
		i += 1
	return out
