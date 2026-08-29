extends SceneTree

## 튜닝 진단용 임시 스크립트. 도시 게이트와 전쟁 통계를 뜯어본다.
##   godot4 --headless --path . --script res://tools/probe_tune.gd -- --runs 6 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 6))
	var turns := int(args.get("turns", 300))

	var fail := {"infra_abs": 0, "infra_rel": 0, "pop": 0, "spacing": 0}
	var infra_hist := PackedInt32Array([0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
	var pop_ok := 0
	var total_prov := 0
	var cities := 0
	var mean_infra_sum := 0.0
	var nations_counted := 0
	var war_len := []
	var war_score := []
	var foreign_wars := 0
	var rebellions := 0
	var annexed := 0
	var end_reasons := {}

	for i in range(runs):
		var world := WorldState.create(1 + i)
		for t in range(turns):
			SimClock.tick(world)
		for p in world.provinces:
			total_prov += 1
			if p.has_city:
				cities += 1
				continue
			var n: Nation = world.nations[p.owner_nation]
			var f_abs := p.infra < Economy.CITY_ABSOLUTE_MIN
			var f_rel := p.infra < n.infra_mean + Economy.CITY_RELATIVE_BONUS
			var f_pop := p.population < Economy.CITY_MIN_POP
			var f_sp := Economy.nearest_city_distance(world, p, n) < Economy.CITY_MIN_SPACING
			if f_abs: fail["infra_abs"] += 1
			if f_rel: fail["infra_rel"] += 1
			if f_pop: fail["pop"] += 1
			if f_sp: fail["spacing"] += 1
			if not f_pop: pop_ok += 1
			var b := clampi(int(p.infra), 0, 9)
			infra_hist[b] += 1
		for n in world.nations:
			if n.is_alive and not n.is_rebel:
				mean_infra_sum += n.infra_mean
				nations_counted += 1
		for w in world.wars:
			var reb := false
			for nid in w.participants():
				if world.nations[nid].is_rebel:
					reb = true
			if reb:
				rebellions += 1
			else:
				foreign_wars += 1
				war_len.append(world.turn - w.start_turn)
				war_score.append(absf(w.warscore))
		for e in world.events:
			if e["kind"] == "war_ended":
				var r: String = e.get("reason", "?")
				end_reasons[r] = int(end_reasons.get(r, 0)) + 1
			elif e["kind"] == "province_ceded":
				annexed += 1

	print("=== 도시 게이트 (도시 없는 프로빈스 기준) ===")
	print("프로빈스 %d, 도시 %d (평균 %.1f/런)" % [total_prov, cities, float(cities) / runs])
	print("탈락 사유: infra<%.1f %d | infra<mean+%.1f %d | pop<%d %d | spacing %d"
		% [Economy.CITY_ABSOLUTE_MIN, fail["infra_abs"], Economy.CITY_RELATIVE_BONUS,
		fail["infra_rel"], int(Economy.CITY_MIN_POP), fail["pop"], fail["spacing"]])
	print("인구 조건 통과 %d" % pop_ok)
	print("infra 히스토그램 0..9: %s" % str(infra_hist))
	print("국가 인구가중 평균 인프라: %.2f" % (mean_infra_sum / maxf(nations_counted, 1)))
	print("=== 전쟁 ===")
	print("개전 게이트: %s" % str(Diplomacy.debug_gates))
	print("대외전쟁 %d (%.1f/런), 반란전쟁 %d" % [foreign_wars, float(foreign_wars) / runs, rebellions])
	print("종전 사유: %s" % str(end_reasons))
	print("병합 프로빈스 %d" % annexed)
	print("대외전쟁 길이 평균 %.1f, |warscore| 평균 %.1f, ACCEPT(%.0f) 도달 %d/%d"
		% [_mean(war_len), _mean(war_score), Peace.ACCEPT_SCORE,
		_count_ge(war_score, Peace.ACCEPT_SCORE), war_score.size()])
	quit(0)


func _mean(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += float(v)
	return s / a.size()


func _count_ge(a: Array, th: float) -> int:
	var c := 0
	for v in a:
		if float(v) >= th:
			c += 1
	return c


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
