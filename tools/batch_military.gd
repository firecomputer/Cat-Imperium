extends SceneTree

## M7 보급 필드 + 상비군 배치 출력. M8 전에는 원정군이 없으므로 국내 보급망만 측정한다.
##
##   godot4 --headless --path . --script res://tools/batch_military.gd -- \
##     --runs 20 --turns 120 --out res://out/supply.csv


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 20))
	var turns := int(args.get("turns", 120))
	var seed0 := int(args.get("seed0", 1))
	var out_path: String = args.get("out", "res://out/supply.csv")
	var lines := PackedStringArray(["seed,turn,nation,culture,province,supply,infra,unrest,"
		+ "terrain,city,capital,province_count,troops,mil_share,manpower_cap,gdp"])
	var t0 := Time.get_ticks_msec()

	for run_idx in range(runs):
		var world := WorldState.create(seed0 + run_idx)
		_dump(lines, world)
		SimClock.run(world, turns)
		_dump(lines, world)

	var file := FileAccess.open(out_path, FileAccess.WRITE)
	if file == null:
		push_error("CSV 저장 실패: %s" % out_path)
		quit(1)
		return
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("runs=%d turns=%d rows=%d (%.1fs)" % [runs, turns, lines.size() - 1,
		(Time.get_ticks_msec() - t0) / 1000.0])
	print("wrote %s" % ProjectSettings.globalize_path(out_path))
	quit(0)


func _dump(lines: PackedStringArray, world: WorldState) -> void:
	for n in world.nations:
		var troops := Military.total_troops(world, n)
		var mil_share := troops * Military.troop_cost(n) / maxf(n.gdp, 1.0)
		for pid in n.provinces:
			var p: Province = world.provinces[pid]
			lines.append(",".join(PackedStringArray([
				str(world.world_seed), str(world.turn), str(n.id), Culture.NAMES[n.culture],
				str(pid), "%.5f" % n.supply_field[pid], "%.4f" % p.infra,
				"%.4f" % p.unrest, str(p.terrain), str(int(p.has_city)),
				str(int(pid == n.capital)), str(n.provinces.size()),
				str(troops), "%.5f" % mil_share, "%.1f" % Military.manpower_cap(n),
				"%.1f" % n.gdp,
			])))


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var arg := argv[i]
		if arg.begins_with("--"):
			var key := arg.substr(2)
			if i + 1 < argv.size() and not argv[i + 1].begins_with("--"):
				out[key] = argv[i + 1]
				i += 1
			else:
				out[key] = true
		i += 1
	return out
