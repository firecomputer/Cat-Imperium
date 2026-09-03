extends SceneTree

## 시드 다수를 재시도 없이 1회씩 생성해 검증 통과율과 대륙/섬 분포를 뽑는다.
##
##   godot --headless --script res://tools/batch_mapgen.gd -- --runs 100 --out res://out/mapgen.csv


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 100))
	var seed0 := int(args.get("seed0", 1))
	var out_path: String = args.get("out", "res://out/mapgen.csv")
	var source_kind := MapSource.parse_kind(args.get("map-source", "earth"))
	if source_kind < 0:
		quit(2)
		return

	var check_keys := ["two_components", "top2_big_enough", "no_pangaea", "island_variety"]
	var lines := PackedStringArray(["seed,land_count,components,largest,second,largest_frac,"
		+ ",".join(check_keys) + ",valid"])

	var pass_count := 0
	var check_pass := {}
	for k in check_keys:
		check_pass[k] = 0
	var land_ok := 0
	var comp_values: Array[int] = []
	var frac_sum := 0.0

	for i in range(runs):
		var s := seed0 + i
		var r := MapSource.create_map_once(s, source_kind)
		var st: Dictionary = r["stats"]
		var ck: Dictionary = r["checks"]

		var row := PackedStringArray([str(s), str(st["land_count"]), str(st["component_count"]),
			str(st["largest"]), str(st["second"]), "%.4f" % st["largest_frac"]])
		for k in check_keys:
			row.append("1" if ck[k] else "0")
			if ck[k]:
				check_pass[k] += 1
		row.append("1" if r["valid"] else "0")
		lines.append(",".join(row))

		if r["valid"]:
			pass_count += 1
		if st["land_count"] == 5000:
			land_ok += 1
		comp_values.append(st["component_count"])
		frac_sum += st["largest_frac"]

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_error("CSV 저장 실패: %s" % out_path)
		quit(1)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()

	comp_values.sort()
	print("runs=%d" % runs)
	print("map_source=%s" % MapSource.kind_name(source_kind))
	print("land == %d : %d/%d" % [5000, land_ok, runs])
	for k in check_keys:
		print("  %-16s %5.1f%%" % [k, 100.0 * check_pass[k] / runs])
	print("VALID (4조건 전부) : %.1f%%" % (100.0 * pass_count / runs))
	print("components  min=%d median=%d max=%d" % [comp_values[0],
		comp_values[runs / 2], comp_values[runs - 1]])
	print("largest_frac mean=%.3f" % (frac_sum / runs))
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
