extends SceneTree

## 전선 수요 대비 야전군 공급. army_cap 상한이 실제로 병목인지 본다.
##   godot4 --headless --path . --script res://tools/probe_capacity.gd -- --runs 8 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 8))
	var turns := int(args.get("turns", 300))
	var map_kind := MapSource.parse_kind(args.get("map-source", "noise"))

	var fronts_hist := {}
	var armies_hist := {}
	var wars_hist := {}
	var rebel_wars_hist := {}
	var capped := 0
	var nation_turns := 0
	var short_by := []
	var split_blocked := 0

	for i in range(runs):
		var world := WorldState.create(1 + i, map_kind)
		for t in range(turns):
			SimClock.tick(world)
			for n in world.nations:
				if not n.is_alive or not n.at_war:
					continue
				nation_turns += 1
				var fronts := WarAI._fronts(world, n)
				var field := WarAI._field_armies(world, n)
				var f := fronts.size()
				var a := field.size()
				fronts_hist[mini(f, 12)] = int(fronts_hist.get(mini(f, 12), 0)) + 1
				armies_hist[a] = int(armies_hist.get(a, 0)) + 1
				var wars := 0
				var rwars := 0
				for war in world.wars:
					if not war.is_active or war.side_of(n.id) == 0:
						continue
					wars += 1
					if war.is_rebel_war:
						rwars += 1
				wars_hist[mini(wars, 8)] = int(wars_hist.get(mini(wars, 8), 0)) + 1
				rebel_wars_hist[mini(rwars, 6)] = int(rebel_wars_hist.get(mini(rwars, 6), 0)) + 1
				if f > a:
					short_by.append(f - a)
					if a >= WarAI.army_cap(n):
						capped += 1
					else:
						split_blocked += 1

	print("runs=%d turns=%d  전쟁중 국가-턴 %d" % [runs, turns, nation_turns])
	print("전선 수 분포(12+ 합침): %s" % [_sorted(fronts_hist)])
	print("야전군 수 분포          : %s" % [_sorted(armies_hist)])
	print("동시 전쟁 수 분포(8+)   : %s" % [_sorted(wars_hist)])
	print("동시 반란전 수 분포(6+) : %s" % [_sorted(rebel_wars_hist)])
	var st := maxi(short_by.size(), 1)
	var sum := 0
	for v in short_by:
		sum += v
	print("전선 > 야전군 인 국가-턴 %d (%.1f%%), 평균 부족 %.2f 개" \
		% [short_by.size(), 100.0 * short_by.size() / maxi(nation_turns, 1), float(sum) / st])
	print("  그중 army_cap 상한에 걸림       %d (%.1f%%)" \
		% [capped, 100.0 * capped / st])
	print("  그중 병력 부족으로 못 쪼갬     %d (%.1f%%)" \
		% [split_blocked, 100.0 * split_blocked / st])
	quit(0)


func _sorted(d: Dictionary) -> String:
	var keys: Array = d.keys()
	keys.sort()
	var parts := PackedStringArray()
	for k in keys:
		parts.append("%s:%d" % [k, d[k]])
	return ", ".join(parts)


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
