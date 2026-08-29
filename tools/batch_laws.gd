extends SceneTree

## 문화별 법률 채택 분포를 뽑는다 (M4 완료 기준).
##
##   godot --headless --script res://tools/batch_laws.gd -- --runs 60 --turns 150 --out res://out/laws.csv
##   .venv/bin/python tools/analyze_laws.py out/laws.csv


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 60))
	var turns := int(args.get("turns", 150))
	var seed0 := int(args.get("seed0", 1))
	var out_path: String = args.get("out", "res://out/laws.csv")

	var lines := PackedStringArray(["seed,nation,culture,turn,category,law_id,severity,"
		+ "desperation,debt_limit_used,provinces"])

	for i in range(runs):
		var s := seed0 + i
		var world := WorldState.create(s)
		_dump(lines, world)
		SimClock.run(world, turns)
		_dump(lines, world)

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_error("CSV 저장 실패: %s" % out_path)
		quit(1)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("runs=%d turns=%d  wrote %s" % [runs, turns, ProjectSettings.globalize_path(out_path)])
	quit(0)


func _dump(lines: PackedStringArray, world: WorldState) -> void:
	for n in world.nations:
		var d := LawEvaluator.desperation(n)
		for cat in Law.CATEGORIES:
			var law: Law = n.laws.get(cat)
			if law == null:
				continue
			lines.append(",".join(PackedStringArray([str(world.world_seed), str(n.id),
				Culture.NAMES[n.culture], str(world.turn), cat, law.id,
				"%.2f" % law.severity, "%.4f" % d,
				"%.4f" % (n.debt / maxf(Credit.credit_limit(n), 1.0)), str(n.provinces.size())])))


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
