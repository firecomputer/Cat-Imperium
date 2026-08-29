extends SceneTree

## M8.5 반란·주둔 진단. §9 의 지표를 그대로 찍는다.
##   godot4 --headless --path . --script res://tools/probe_rebellion.gd -- --runs 6 --turns 300

const HIGH_UNREST := 0.5


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 6))
	var turns := int(args.get("turns", 300))

	# 주둔 표본 (평시/전시 분리)
	var samples := {"peace": 0.0, "war": 0.0}
	var garrison_troops := {"peace": 0.0, "war": 0.0}
	var total_troops := {"peace": 0.0, "war": 0.0}
	var prov_samples := 0.0
	var prov_garrisoned := 0.0
	var garrison_ratio_sum := 0.0
	var high_samples := 0.0
	var high_garrisoned := 0.0

	var rebellions := 0
	var reb_joined := 0
	var reb_zero_garrison := 0
	var results := {"suppressed": 0, "annihilated": 0, "independence_recognized": 0}
	var durations: Array[int] = []
	var stalled := 0
	var recognition_sum := 0.0
	var warscore_sum := 0.0
	var reclaimed_sum := 0.0
	var origin_sum := 0
	var max_origin := 0
	var island_reb := 0
	var island_indep := 0
	var mainland_indep := 0
	var mainland_wars := 0
	var respawn_15 := 0
	var respawn_50 := 0
	var reintegrations := 0

	for i in range(runs):
		var world := WorldState.create(1 + i)
		for t in range(turns):
			SimClock.tick(world)
			if world.turn % 5 != 0:
				continue
			for n in world.nations:
				if not n.is_alive or n.is_rebel:
					continue
				var key := "war" if n.at_war else "peace"
				var total := 0.0
				var garrisoned := 0.0
				for army_id in n.armies:
					var a: Army = world.armies[army_id]
					if not a.is_alive:
						continue
					total += a.troops
					if a.garrison_province >= 0:
						garrisoned += a.troops
				samples[key] += 1.0
				total_troops[key] += total
				garrison_troops[key] += garrisoned
				for pid in n.provinces:
					var p: Province = world.provinces[pid]
					prov_samples += 1.0
					garrison_ratio_sum += p.garrison_ratio
					if p.garrison_ratio > 0.0:
						prov_garrisoned += 1.0
					if p.unrest >= HIGH_UNREST:
						high_samples += 1.0
						if p.garrison_ratio > 0.0:
							high_garrisoned += 1.0

		# 프로빈스 단위 재통합 → 재반란 간격
		var reintegrated := {}          # province id → 마지막 재통합 턴
		for e in world.events:
			match e["kind"]:
				"rebellion":
					rebellions += 1
					# 육상 인접이 없는 섬은 제해권 없이는 진압군이 닿지 못한다.
					if world.provinces[int(e["province"])].land_neighbors.is_empty():
						island_reb += 1
					if bool(e.get("joined", false)):
						reb_joined += 1
					if float(e["garrison"]) <= 0.0:
						reb_zero_garrison += 1
					var pid := int(e["province"])
					if reintegrated.has(pid):
						var gap := int(e["turn"]) - int(reintegrated[pid])
						if gap <= 15:
							respawn_15 += 1
						if gap <= 50:
							respawn_50 += 1
				"rebellion_suppressed":
					reintegrations += 1
					reintegrated[int(e["province"])] = int(e["turn"])
				"rebel_war_end":
					var island := world.provinces[
						world.nations[int(e["rebel"])].capital].land_neighbors.is_empty() \
						if world.nations[int(e["rebel"])].capital >= 0 else false
					if not island:
						mainland_wars += 1
					var result := String(e["result"])
					if result == "independence_recognized":
						if island:
							island_indep += 1
						else:
							mainland_indep += 1
					results[result] = int(results.get(result, 0)) + 1
					var d := int(e["duration"])
					durations.append(d)
					if d >= 150:
						stalled += 1
					recognition_sum += float(e["recognition"])
					warscore_sum += float(e["parent_warscore"])
					reclaimed_sum += float(e["parent_reclaimed_ratio"])
					origin_sum += int(e["origin_provinces"])
					max_origin = maxi(max_origin, int(e["origin_provinces"]))

	var wars := maxi(durations.size(), 1)
	durations.sort()
	var median := durations[durations.size() / 2] if not durations.is_empty() else 0
	var rn := maxf(float(rebellions), 1.0)

	print("=== 주둔 (%d런 × %d턴) ===" % [runs, turns])
	for key in ["peace", "war"]:
		var s: float = maxf(samples[key], 1.0)
		var tt: float = maxf(total_troops[key], 1.0)
		print("  %-5s 국가-표본 %6d   전체 병력 중 치안 비율 %.1f%%" % [
			key, int(samples[key]), garrison_troops[key] / tt * 100.0])
	print("  avg_garrison_ratio            %.4f" % (garrison_ratio_sum / maxf(prov_samples, 1.0)))
	print("  share_provinces_garrisoned    %.1f%%" % (prov_garrisoned / maxf(prov_samples, 1.0) * 100.0))
	print("  share_high_unrest_garrisoned  %.1f%%" % (high_garrisoned / maxf(high_samples, 1.0) * 100.0))

	print("=== 반란 %d 건 (%.1f/런) ===" % [rebellions, rn / runs])
	print("  기존 반란국 합류 %d (%.0f%%)" % [reb_joined, float(reb_joined) / rn * 100.0])
	print("  rebellions_with_zero_garrison %d (%.0f%%)   [목표 <= 60%%]" % [
		reb_zero_garrison, float(reb_zero_garrison) / rn * 100.0])

	print("=== 반란전 %d 건 ===" % durations.size())
	for key in ["suppressed", "annihilated", "independence_recognized"]:
		print("  %-24s %4d (%.0f%%)" % [key, results.get(key, 0),
			float(results.get(key, 0)) / wars * 100.0])
	var put_down: int = int(results.get("suppressed", 0)) + int(results.get("annihilated", 0))
	print("  정부 진압률 %.0f%%  독립 인정률 %.0f%%   [둘 다 목표 30~60%%]" % [
		float(put_down) / wars * 100.0,
		float(results.get("independence_recognized", 0)) / wars * 100.0])
	print("  지속시간 중앙값 %d턴  [목표 20~90]   150턴+ %d (%.0f%%)  [목표 <5%%]" % [
		median, stalled, float(stalled) / wars * 100.0])
	print("  종료 시 평균 recognition %.1f  parent_warscore %.1f  탈환률 %.2f" % [
		recognition_sum / wars, warscore_sum / wars, reclaimed_sum / wars])
	print("  origin_provinces 평균 %.2f  최대 %d" % [float(origin_sum) / wars, max_origin])
	print("  섬 반란 %d (%.0f%%)   독립 중 섬 %d / 본토 %d" % [
		island_reb, float(island_reb) / rn * 100.0, island_indep, mainland_indep])
	print("  본토 반란전 %d 건 중 독립 %d (%.0f%%)  진압 %d (%.0f%%)" % [
		mainland_wars, mainland_indep, float(mainland_indep) / maxf(mainland_wars, 1) * 100.0,
		mainland_wars - mainland_indep,
		float(mainland_wars - mainland_indep) / maxf(mainland_wars, 1) * 100.0])
	print("  재통합 %d 건 → 15턴 내 재반란 %d (%.0f%%)  50턴 내 %d (%.0f%%)" % [
		reintegrations, respawn_15, float(respawn_15) / maxf(reintegrations, 1) * 100.0,
		respawn_50, float(respawn_50) / maxf(reintegrations, 1) * 100.0])
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
