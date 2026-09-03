extends SceneTree

## 반란전 판정 경로 진단. origin 프로빈스 수, recognition 증가율, 종결 사유.
##   godot4 --headless --path . --script res://tools/probe_rebel.gd -- --runs 8 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 8))
	var turns := int(args.get("turns", 300))
	var map_kind := MapSource.parse_kind(args.get("map-source", "noise"))

	var origin_sizes := {}
	var ratios := {}
	var gains := {}
	var ends := {}
	var durations := []
	var starts := {}
	var pressure := {}

	for i in range(runs):
		var world := WorldState.create(1 + i, map_kind)
		for t in range(turns):
			SimClock.tick(world)
			for war in world.wars:
				if not war.is_active or not war.is_rebel_war:
					continue
				if not starts.has(war.id):
					starts[war.id] = world.turn
				var k := war.rebel_origin_provinces.size()
				origin_sizes[k] = int(origin_sizes.get(k, 0)) + 1
				var r := Peace._rebel_origin_ratio(world, war, war.rebel_nation_id)
				var bucket := "1.0" if r >= 0.999 else ("0.0" if r <= 0.001 \
					else ("0<r<0.3" if r < 0.3 else "0.3<=r<1"))
				ratios[bucket] = int(ratios.get(bucket, 0)) + 1
				var g := r * Peace.RECOGNITION_CONTROL_GAIN
				if world.provinces[war.rebel_capital_province].controller() == war.rebel_nation_id:
					g += Peace.RECOGNITION_CAPITAL_GAIN
				g *= Peace.RECOGNITION_LUCK_MEAN
				var press: float = maxf(Peace._parent_pressure(world, war),
					Peace._rebel_attrition_pressure(war))
				g -= press * Peace.RECOGNITION_PRESSURE_GAIN
				if r < Peace.RECOGNITION_LOSING_RATIO:
					g -= Peace.RECOGNITION_LOSING_PENALTY
				if r <= Peace.RECOGNITION_COLLAPSE_RATIO:
					g -= Peace.RECOGNITION_COLLAPSE_PENALTY
				var gb := "감소" if g < 0.0 else ("정체" if g < 0.01 else "증가")
				gains[gb] = int(gains.get(gb, 0)) + 1
				var pb := "0" if press < 0.01 else ("0<p<0.5" if press < 0.5 \
					else ("0.5" if press < 0.51 else "0.5<p<=1"))
				pressure[pb] = int(pressure.get(pb, 0)) + 1
		for e in world.events:
			if e["kind"] == "rebel_war_end":
				var r2 := str(e["result"])
				ends[r2] = int(ends.get(r2, 0)) + 1

	print("runs=%d turns=%d" % [runs, turns])
	print("반란전-턴의 origin 프로빈스 수 분포: %s" % [origin_sizes])
	print("반란국 origin 통제율 분포: %s" % [ratios])
	print("모국 압박 분포: %s" % [pressure])
	print("recognition 턴당 변화(기대값): %s" % [gains])
	print("반란전 종결 사유: %s" % [ends])
	quit(0)


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var k: String = argv[i]
		if k.begins_with("--") and i + 1 < argv.size():
			out[k.substr(2)] = argv[i + 1]
			i += 2
		else:
			i += 1
	return out
