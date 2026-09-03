extends SceneTree

## M14 계측. 개전 게이트 분포, crusade/suppression 이벤트, 지지도·분리주의 분포.
##   godot --headless --script res://tools/probe_m14.gd -- --runs 8 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 8))
	var turns := int(args.get("turns", 300))
	var map_kind := MapSource.parse_kind(args.get("map-source", "earth"))

	var events := {}
	var support_hist := {}
	var sep_hist := {}
	var caps := {}
	Diplomacy.debug_gates.clear()
	for r in range(runs):
		var world := WorldState.create(1 + r, map_kind)
		for t in range(turns):
			SimClock.tick(world)
			for e in world.events:
				var k: String = e["kind"]
				if k in ["crusade_declared", "suppression", "rebellion",
						"rebellion_suppressed", "war_declared", "nation_died"]:
					events[k] = int(events.get(k, 0)) + 1
			world.events.clear()
		for n in world.nations:
			if not n.is_alive or n.is_rebel:
				continue
			var b := int(clampf(n.war_support, 0.0, 1.0) * 10.0)
			support_hist[b] = int(support_hist.get(b, 0)) + 1
			var c := WarAI.army_cap(n)
			caps[c] = int(caps.get(c, 0)) + 1
		for p in world.provinces:
			if p.owner_nation < 0:
				continue
			var b := int(clampf(p.separatism, 0.0, 1.0) * 10.0)
			sep_hist[b] = int(sep_hist.get(b, 0)) + 1

	print("runs=%d turns=%d" % [runs, turns])
	print("이벤트           : %s" % [events])
	print("개전 게이트      : %s" % [Diplomacy.debug_gates])
	print("지지도 분포(0.1) : %s" % [_sorted(support_hist)])
	print("분리주의 분포    : %s" % [_sorted(sep_hist)])
	print("army_cap 분포    : %s" % [_sorted(caps)])
	quit(0)


func _sorted(d: Dictionary) -> String:
	var keys: Array = d.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for k in keys:
		parts.append("%s:%s" % [k, d[k]])
	return ", ".join(parts)


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	while i < argv.size():
		var a := argv[i]
		if a.begins_with("--") and i + 1 < argv.size():
			out[a.substr(2)] = argv[i + 1]
			i += 2
		else:
			i += 1
	return out
