extends SceneTree

const EmpireSystem = preload("res://sim/systems/empire_system.gd")
const EMPIRE_CONFIRM_TURNS := 12

## M8 외교·전쟁·평화 배치 출력.
##
##   godot4 --headless --path . --script res://tools/batch_war.gd -- \
##     --runs 20 --turns 300 --map-source earth --out res://out/war.csv


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 20))
	var turns := int(args.get("turns", 300))
	var seed0 := int(args.get("seed0", 1))
	var out_path: String = args.get("out", "res://out/war.csv")
	var map_kind := MapSource.parse_kind(args.get("map-source", "noise"))
	if map_kind < 0:
		quit(2)
		return

	var lines := PackedStringArray(["seed,nation,culture,alive,provinces,fragments,"
		+ "exclaves,gdp,troops,ships,allies,vassals,wars,rebellions_lost,"
		+ "provinces_annexed,provinces_ceded,share_of_world,realm_share,"
		+ "imperial_authority,admin_load,admin_capacity,overextension,overlord,vassal_loyalty,"
		+ "army_quality,military_readiness,strategic_power"])
	var event_lines := PackedStringArray([
		"seed,turn,kind,nation,other,reason,warscore,duration,lost,readiness,"
		+ "consumed_attackers,consumed_defenders"])
	var empire_lines := PackedStringArray([
		"seed,nation,enter_turn,exit_turn,duration,peak_realm_share,reason"])
	var t0 := Time.get_ticks_msec()

	for run_idx in range(runs):
		var world := WorldState.create(seed0 + run_idx, map_kind)
		var tracker := {}
		for t in range(turns):
			SimClock.tick(world)
			_track_empires(world, tracker, empire_lines, false)
		_track_empires(world, tracker, empire_lines, true)
		_dump(lines, event_lines, world)

	_write(out_path, lines)
	_write(out_path.get_basename() + "_events.csv", event_lines)
	_write(out_path.get_basename() + "_empires.csv", empire_lines)
	print("runs=%d turns=%d map_source=%s (%.1fs)" % [runs, turns,
		MapSource.kind_name(map_kind), (Time.get_ticks_msec() - t0) / 1000.0])
	quit(0)


func _dump(lines: PackedStringArray, events: PackedStringArray, world: WorldState) -> void:
	var annexed := {}
	var ceded := {}
	var lost := {}
	for e in world.events:
		match e["kind"]:
			"province_ceded":
				annexed[e["nation"]] = int(annexed.get(e["nation"], 0)) + 1
				ceded[e["loser"]] = int(ceded.get(e["loser"], 0)) + 1
			"rebellion":
				lost[e["nation"]] = int(lost.get(e["nation"], 0)) + 1
			"war_declared", "war_ended", "alliance_formed", "peace_signed", "vassalized", \
			"vassal_released", "independence_war", "imperial_authority_changed", \
			"army_destroyed", "military_collapse":
				var reason := str(e.get("reason", ""))
				if e["kind"] == "war_declared":
					reason = War.goal_name(int(e.get("goal", War.Goal.CONQUEST)))
				events.append(",".join(PackedStringArray([str(world.world_seed),
					str(e["turn"]), e["kind"], str(e["nation"]),
					str(e.get("defender", e.get("ally", e.get("loser", e.get("vassal", -1))))),
					reason, "%.3f" % float(e.get("warscore", 0.0)),
					str(e.get("turns", 0)), str(e.get("lost", 0)),
					"%.5f" % float(e.get("readiness", 1.0)),
					"%.5f" % float(e.get("consumed_attackers", -1.0)),
					"%.5f" % float(e.get("consumed_defenders", -1.0))])))

	var world_gdp := maxf(world.world_gdp(), 1.0)
	for i in range(world.nations.size()):
		var n: Nation = world.nations[i]
		lines.append(",".join(PackedStringArray([
			str(world.world_seed), str(n.id), Culture.NAMES[n.culture],
			str(int(n.is_alive)), str(n.provinces.size()), str(_fragments(world, n)),
			str(_exclaves(world, n)), "%.1f" % n.gdp,
			str(Military.total_troops(world, n)), str(Naval.total_ships(world, n)),
			str(n.allies.size()), str(n.vassals.size()), str(n.wars.size()),
				str(lost.get(n.id, 0)), str(annexed.get(n.id, 0)), str(ceded.get(n.id, 0)),
				"%.5f" % (n.gdp / world_gdp),
				"%.5f" % EmpireSystem.realm_share(world, n),
				"%.5f" % n.imperial_authority, "%.3f" % n.admin_load,
				"%.3f" % n.admin_capacity, "%.5f" % n.overextension,
				str(n.overlord), "%.5f" % n.vassal_loyalty,
				"%.5f" % Military.average_quality(world, n),
				"%.5f" % n.military_readiness,
				"%.1f" % Military.strategic_power(world, n),
			])))


func _track_empires(world: WorldState, tracker: Dictionary, lines: PackedStringArray,
		finish: bool) -> void:
	var seen := {}
	for n in world.nations:
		if not n.is_alive or n.is_rebel or n.overlord >= 0:
			continue
		seen[n.id] = true
		var share := EmpireSystem.realm_share(world, n)
		var slot: Dictionary = tracker.get(n.id, {
			"active": false, "candidate": -1, "enter": -1, "peak": 0.0,
		})
		if share >= EmpireSystem.empire_threshold(world) and not n.vassals.is_empty():
			if int(slot["candidate"]) < 0 and not bool(slot["active"]):
				slot["candidate"] = world.turn
				slot["peak"] = share
			if not bool(slot["active"]) \
					and world.turn - int(slot["candidate"]) + 1 >= EMPIRE_CONFIRM_TURNS:
				slot["active"] = true
				slot["enter"] = int(slot["candidate"])
			slot["peak"] = maxf(float(slot["peak"]), share)
		else:
			if bool(slot["active"]):
				_close_empire(lines, world, n.id, slot, "realm_share_below_threshold")
			slot["candidate"] = -1
			if not bool(slot["active"]):
				slot["peak"] = 0.0
		tracker[n.id] = slot
	var tracked_ids: Array = tracker.keys()
	tracked_ids.sort()
	for nation_id in tracked_ids:
		if seen.has(nation_id):
			continue
		var missing: Dictionary = tracker[nation_id]
		if bool(missing["active"]):
			_close_empire(lines, world, int(nation_id), missing, "realm_collapsed")
			tracker[nation_id] = missing
	if not finish:
		return
	var ids: Array = tracker.keys()
	ids.sort()
	for nation_id in ids:
		var slot: Dictionary = tracker[nation_id]
		if bool(slot["active"]):
			_close_empire(lines, world, int(nation_id), slot, "horizon")
			tracker[nation_id] = slot


func _close_empire(lines: PackedStringArray, world: WorldState, nation_id: int,
		slot: Dictionary, reason: String) -> void:
	var enter := int(slot["enter"])
	lines.append(",".join(PackedStringArray([
		str(world.world_seed), str(nation_id), str(enter), str(world.turn),
		str(world.turn - enter), "%.5f" % float(slot["peak"]), reason,
	])))
	slot["active"] = false
	slot["candidate"] = -1
	slot["enter"] = -1
	slot["peak"] = 0.0


## 국가 영토의 연결 덩어리 수. 1 이 아니면 국경이 누더기라는 뜻이다 (M8 완료 기준).
func _fragments(world: WorldState, n: Nation) -> int:
	var seen := {}
	var groups := 0
	for pid in n.provinces:
		if seen.has(pid):
			continue
		groups += 1
		var queue: Array[int] = [pid]
		seen[pid] = true
		var head := 0
		while head < queue.size():
			var cur: int = queue[head]
			head += 1
			for nb: int in world.provinces[cur].land_neighbors:
				if not seen.has(nb) and world.provinces[nb].owner_nation == n.id:
					seen[nb] = true
					queue.append(nb)
	return groups


func _exclaves(world: WorldState, n: Nation) -> int:
	var count := 0
	for pid in n.provinces:
		if world.provinces[pid].is_exclave:
			count += 1
	return count


func _write(path: String, lines: PackedStringArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("CSV 저장 실패: %s" % path)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()
	print("wrote %s" % ProjectSettings.globalize_path(path))


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
