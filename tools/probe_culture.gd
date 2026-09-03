extends SceneTree

## 문화 12종 분포·생존율 계측. 티어 정원과 앵커가 실제 런에서 어떻게 나오는지 본다.
##   godot4 --headless --path . --script res://tools/probe_culture.gd -- --runs 6 --turns 400

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 6))
	var turns := int(args.get("turns", 400))
	var kind := MapSource.parse_kind(args.get("map-source", "earth"))
	var start := {}
	var survived := {}
	var absent_runs := {}
	var anchored := 0
	var regional := 0
	for i in range(runs):
		var world := WorldState.create(1 + i, kind)
		var present := {}
		for n in world.nations:
			start[n.culture] = int(start.get(n.culture, 0)) + 1
			present[n.culture] = true
			var region: int = world.provinces[n.capital].region
			if region >= 0:
				regional += 1
				if int(Culture.ORIGIN_REGION[n.culture]) == region:
					anchored += 1
		for c in range(Culture.Kind.size()):
			if not present.has(c):
				absent_runs[c] = int(absent_runs.get(c, 0)) + 1
		for t in range(turns):
			SimClock.tick(world)
		for n in world.nations:
			if n.is_alive and not n.is_rebel and n.provinces.size() >= 3:
				survived[n.culture] = int(survived.get(n.culture, 0)) + 1
	print("runs=%d turns=%d map=%s  앵커 적중 %.2f (%d/%d)"
		% [runs, turns, MapSource.kind_name(kind),
		float(anchored) / maxf(regional, 1), anchored, regional])
	for c in range(Culture.Kind.size()):
		var s := int(start.get(c, 0))
		var alive := int(survived.get(c, 0))
		print("  %-14s 시작 %3d  실효생존 %3d  생존율 %5.1f%%  미등장런 %d/%d"
			% [Culture.NAMES[c], s, alive,
			100.0 * float(alive) / maxf(s, 1), int(absent_runs.get(c, 0)), runs])
	quit(0)


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		if argv[i].begins_with("--") and i + 1 < argv.size():
			out[argv[i].substr(2)] = argv[i + 1]
			i += 2
		else:
			i += 1
	return out
