extends SceneTree

## 불만 drift 분해 진단. 어느 항이 반란을 만드는지 본다.
##   godot4 --headless --path . --script res://tools/probe_unrest.gd -- --runs 6 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 6))
	var turns := int(args.get("turns", 300))

	var terms := {"occupation": 0.0, "inflation": 0.0, "culture": 0.0, "distance": 0.0,
		"exclave": 0.0, "garrison": 0.0, "suppression": 0.0, "cohesion": 0.0, "net": 0.0}
	var samples := 0
	var dist_hist := PackedInt32Array([0, 0, 0, 0, 0, 0, 0])
	var garrison_zero := 0
	var reb_dist := PackedInt32Array([0, 0, 0, 0, 0, 0, 0])
	var reb_culture_zero := 0
	var rebellions := 0
	var reb_by_turn := PackedInt32Array([0, 0, 0, 0, 0, 0])
	var reb_drift := 0.0
	var reb_infl := 0.0
	var reb_hot_infl := 0
	var reb_no_garrison := 0
	var reb_from_rebel := 0
	var reb_city := 0
	var reb_drift_hist := PackedInt32Array([0, 0, 0, 0, 0, 0])

	for i in range(runs):
		var world := WorldState.create(1 + i)
		for t in range(turns):
			SimClock.tick(world)
			if world.turn % 25 != 0:
				continue
			for n in world.nations:
				if not n.is_alive or n.is_rebel:
					continue
				for pid in n.provinces:
					var p: Province = world.provinces[pid]
					samples += 1
					var cd := p.culture_distance(n.culture)
					var occ := 0.0
					if cd > 0.0 or p.occupied_by_nation >= 0:
						occ = n.occupation_law_severity() * Unrest.OCCUPATION_W
					terms["occupation"] += occ
					terms["inflation"] += maxf(n.inflation - Unrest.INFLATION_FREE, 0.0) * Unrest.INFLATION_W
					terms["culture"] += cd * Unrest.CULTURE_W
					terms["distance"] += minf(p.distance_from_capital, Unrest.DISTANCE_CAP) * Unrest.DISTANCE_W
					terms["exclave"] += Unrest.EXCLAVE_W if p.is_exclave else 0.0
					terms["garrison"] -= p.garrison_ratio * Unrest.GARRISON_W
					terms["suppression"] -= n.unrest_suppression * Unrest.SUPPRESSION_W
					terms["cohesion"] -= n.culture_bias("cohesion") * Unrest.COHESION_W
					terms["net"] += Unrest.drift(p, n)
					dist_hist[clampi(int(p.distance_from_capital), 0, 6)] += 1
					if p.garrison_ratio <= 0.0:
						garrison_zero += 1
		for e in world.events:
			if e["kind"] != "rebellion":
				continue
			rebellions += 1
			reb_dist[clampi(int(e["distance"]), 0, 6)] += 1
			if float(e["culture_distance"]) <= 0.0:
				reb_culture_zero += 1
			reb_by_turn[clampi(int(e["turn"]) / 50, 0, 5)] += 1
			reb_drift += float(e["drift"])
			reb_infl += float(e["inflation"])
			if float(e["inflation"]) > Unrest.INFLATION_FREE:
				reb_hot_infl += 1
			if float(e["garrison"]) <= 0.0:
				reb_no_garrison += 1
			if bool(e["from_rebel"]):
				reb_from_rebel += 1
			if bool(e["city"]):
				reb_city += 1
			reb_drift_hist[clampi(int(float(e["drift"]) / 0.02), 0, 5)] += 1

	var s := maxf(float(samples), 1.0)
	print("=== drift 항별 평균 (프로빈스-턴 %d 샘플) ===" % samples)
	for k in ["occupation", "inflation", "culture", "distance", "exclave", "garrison",
			"suppression", "cohesion", "net"]:
		print("  %-12s %+.5f" % [k, terms[k] / s])
	print("  주둔 0 프로빈스 비율 %.1f%%" % (float(garrison_zero) / s * 100.0))
	print("  수도거리 히스토그램 0..6+: %s" % str(dist_hist))
	print("=== 반란 %d 건 (%.1f/런) ===" % [rebellions, float(rebellions) / runs])
	print("  스폰 시 수도거리 0..6+: %s  (로그 버그로 항상 0 이면 무시)" % str(reb_dist))
	print("  문화거리 0 인 반란: %d (%.0f%%)" % [reb_culture_zero,
		float(reb_culture_zero) / maxf(rebellions, 1) * 100.0])
	print("  50턴 구간별: %s" % str(reb_by_turn))
	var rn := maxf(float(rebellions), 1.0)
	print("  스폰 시 drift 평균 %+.4f  구간(0,.02,.04,.06,.08,.1+) %s" % [reb_drift / rn,
		str(reb_drift_hist)])
	print("  스폰 시 인플레 평균 %+.3f  인플레>%.2f 인 반란 %d (%.0f%%)" % [reb_infl / rn,
		Unrest.INFLATION_FREE, reb_hot_infl, float(reb_hot_infl) / rn * 100.0])
	print("  주둔 0 %d (%.0f%%)  반란국에서 재분열 %d (%.0f%%)  도시 %d" % [
		reb_no_garrison, float(reb_no_garrison) / rn * 100.0,
		reb_from_rebel, float(reb_from_rebel) / rn * 100.0, reb_city])
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
				out[key] = "1"
		i += 1
	return out
