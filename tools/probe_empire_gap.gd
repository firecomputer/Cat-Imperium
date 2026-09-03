extends SceneTree

## noise vs earth 제국 형성 격차 진단. 지도별로 전쟁 산출량과 행정 부하를 비교한다.
##   godot4 --headless --path . --script res://tools/probe_empire_gap.gd -- --runs 3 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 3))
	var turns := int(args.get("turns", 300))
	var maps: Array = args.get("map-source", "noise,earth").split(",")
	for kind_name in maps:
		var kind := MapSource.parse_kind(kind_name)
		_run(kind_name, kind, runs, turns)
	quit(0)


func _run(kind_name: String, kind: int, runs: int, turns: int) -> void:
	var provs := 0
	var nations0 := 0
	var peaces := 0
	var cedes := 0
	var warscore_sum := 0.0
	var war_turns := 0
	var vassalized := 0
	var wars_declared := 0
	var max_share := 0.0
	var max_realm := 0
	var load_sum := 0.0
	var cap_sum := 0.0
	var over_sum := 0.0
	var over_n := 0
	var occ_sum := 0.0
	var occ_n := 0
	## 제국 판정 두 가지. 0.12 는 40국 세계 기준 상수라, 국가 수로 환산한
	## EmpireSystem.empire_threshold() 와 나란히 센다.
	var empire_turns := 0
	var empire_turns_rel := 0
	var sampled := 0
	var share_trace := PackedStringArray()
	for i in range(runs):
		var world := WorldState.create(1 + i, kind)
		provs += world.provinces.size()
		nations0 += world.nations.size()
		for t in range(turns):
			SimClock.tick(world)
			if t % 20 == 0:
				for n in world.nations:
					if n.is_alive and not n.is_rebel and n.overlord < 0:
						load_sum += n.admin_load
						cap_sum += n.admin_capacity
						over_sum += n.overextension
						over_n += 1
				# 점령 진행: 전쟁중 국가가 상대 땅을 쥐고 있나
				for war in world.wars:
					if war.is_active and not war.is_rebel_war:
						occ_sum += war.warscore
						occ_n += 1
				sampled += 1
				var rel_threshold := EmpireSystem.empire_threshold(world)
				var top := 0.0
				for n in world.nations:
					if not n.is_alive or n.is_rebel or n.overlord >= 0:
						continue
					var sh := EmpireSystem.realm_share(world, n)
					top = maxf(top, sh)
					if n.vassals.is_empty():
						continue
					if sh >= EmpireSystem.EMPIRE_THRESHOLD_BASE:
						empire_turns += 1
					if sh >= rel_threshold:
						empire_turns_rel += 1
				if i == 0 and t % 100 == 0:
					share_trace.append("t%d=%.3f" % [t, top])
		for e in world.events:
			match e["kind"]:
				"peace_signed":
					peaces += 1
					warscore_sum += absf(float(e["warscore"]))
					war_turns += int(e["turns"])
					for term in e["terms"]:
						if String(term).begins_with("cede:"):
							cedes += 1
				"vassalized":
					vassalized += 1
				"war_declared":
					wars_declared += 1
		for n in world.nations:
			if not n.is_alive or n.is_rebel or n.overlord >= 0:
				continue
			max_share = maxf(max_share, EmpireSystem.realm_share(world, n))
			max_realm = maxi(max_realm, EmpireSystem.realm_province_count(world, n))
	var r := float(runs)
	print("== %s  runs=%d turns=%d" % [kind_name, runs, turns])
	print("  프로빈스 %.0f  초기국가 %.0f  국가당 %.1f" % [provs / r, nations0 / r,
		float(provs) / maxf(float(nations0), 1.0)])
	print("  개전 %.1f/런  강화 %.1f/런  평균 warscore %.1f  평균 전쟁길이 %.1f턴"
		% [wars_declared / r, peaces / r, warscore_sum / maxf(peaces, 1),
		float(war_turns) / maxf(peaces, 1)])
	print("  할양 %.1f/런  강화당 할양 %.2f칸  속국화 %.1f/런"
		% [cedes / r, float(cedes) / maxf(peaces, 1), vassalized / r])
	print("  admin_load %.1f  capacity %.1f  overextension %.3f"
		% [load_sum / maxf(over_n, 1), cap_sum / maxf(over_n, 1), over_sum / maxf(over_n, 1)])
	print("  전쟁중 평균 warscore %.1f" % [occ_sum / maxf(occ_n, 1)])
	print("  제국(0.12) 표본턴 %d/%d  제국(국가수 환산) %d/%d  시드1 최대share추이 %s"
		% [empire_turns, sampled, empire_turns_rel, sampled, share_trace])
	print("  최대 realm_share %.4f  최대 realm 프로빈스 %d (전체의 %.1f%%)"
		% [max_share, max_realm, 100.0 * max_realm / maxf(provs / r, 1.0)])


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
