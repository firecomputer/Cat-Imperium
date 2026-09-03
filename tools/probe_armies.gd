extends SceneTree

## 군대 교전 성향 진단. 야전군이 적 유닛을 실제로 잡으러 가는지 본다.
##   godot4 --headless --path . --script res://tools/probe_armies.gd -- --runs 8 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 8))
	var turns := int(args.get("turns", 300))
	var map_kind := MapSource.parse_kind(args.get("map-source", "noise"))

	var s := {"army_turns": 0, "engaged": 0, "retreating": 0, "adjacent_idle": 0,
		"besieging": 0, "marching": 0, "intruder_turns": 0, "intruder_contested": 0,
		"siege_ready": 0, "siege_blocked": 0}
	var blocker_sizes := PackedInt32Array()
	var attacker_sizes := PackedInt32Array()
	var battles := 0
	var occupies := 0
	var destroyed := 0
	var war_turns := 0

	for i in range(runs):
		var world := WorldState.create(1 + i, map_kind)
		for t in range(turns):
			SimClock.tick(world)
			_sample(world, s)
			_sample_sieges(world, s, blocker_sizes, attacker_sizes)
			for n in world.nations:
				if n.is_alive and n.at_war:
					war_turns += 1
		for e in world.events:
			match e["kind"]:
				"battle_resolved": battles += 1
				"province_occupied": occupies += 1
				"army_destroyed": destroyed += 1

	var at := maxi(s["army_turns"], 1)
	print("runs=%d turns=%d" % [runs, turns])
	print("야전군-턴 %d  (전쟁중 국가-턴 %d)" % [at, war_turns])
	print("  교전중        %6.2f%%" % [100.0 * s["engaged"] / at])
	print("  공성중        %6.2f%%" % [100.0 * s["besieging"] / at])
	print("  퇴각/재편     %6.2f%%" % [100.0 * s["retreating"] / at])
	print("  적군 옆인데 안 붙음 %6.2f%%" % [100.0 * s["adjacent_idle"] / at])
	print("  그냥 행군     %6.2f%%" % [100.0 * s["marching"] / at])
	var it := maxi(s["intruder_turns"], 1)
	print("내 땅 침입 적군-턴 %d, 그중 아군 접촉 %6.2f%%" \
		% [it, 100.0 * s["intruder_contested"] / it])
	var sr := maxi(s["siege_ready"] + s["siege_blocked"], 1)
	print("공성 시도 군대-턴 %d, 그중 적 유닛에 막힘 %6.2f%%" \
		% [sr, 100.0 * s["siege_blocked"] / sr])
	print("  막은 부대 병력 " + _quantiles(blocker_sizes))
	print("  막힌 공성군 병력 " + _quantiles(attacker_sizes))
	print("battles=%d occupies=%d armies_destroyed=%d  battles/occupy=%.2f" \
		% [battles, occupies, destroyed, float(battles) / maxf(occupies, 1.0)])
	quit(0)


## 적지에 선 야전군이 공성을 걸 수 있었는지. 막혔다면 막은 부대 크기를 기록한다.
func _sample_sieges(world: WorldState, s: Dictionary, blockers: PackedInt32Array,
		attackers: PackedInt32Array) -> void:
	for a in world.armies:
		if not a.is_alive or a.province_id < 0:
			continue
		var p: Province = world.provinces[a.province_id]
		var holder := p.controller()
		if holder < 0 or holder == a.nation_id:
			continue
		if not Diplomacy.are_at_war(world, a.nation_id, holder):
			continue
		var biggest := 0
		for other_id: int in world.armies_at(a.province_id):
			var o: Army = world.armies[other_id]
			if o.is_alive and Diplomacy.are_at_war(world, a.nation_id, o.nation_id):
				biggest = maxi(biggest, o.troops)
		if biggest > 0:
			s["siege_blocked"] += 1
			blockers.append(biggest)
			attackers.append(a.troops)
		else:
			s["siege_ready"] += 1


func _quantiles(v: PackedInt32Array) -> String:
	if v.is_empty():
		return "(없음)"
	var arr := Array(v)
	arr.sort()
	var n := arr.size()
	return "p10=%d p50=%d p90=%d 평균=%.0f" % [arr[n / 10], arr[n / 2],
		arr[mini(n * 9 / 10, n - 1)], Array(v).reduce(func(x, y): return x + y, 0) / float(n)]


func _sample(world: WorldState, s: Dictionary) -> void:
	for a in world.armies:
		if not a.is_alive or a.province_id < 0 or a.garrison_province >= 0:
			continue
		var n: Nation = world.nations[a.nation_id]
		if not n.at_war:
			continue
		s["army_turns"] += 1
		if _hostile_at(world, a.nation_id, a.province_id):
			s["engaged"] += 1
			continue
		if a.retreating:
			s["retreating"] += 1
			continue
		var p: Province = world.provinces[a.province_id]
		var holder := p.controller()
		if holder >= 0 and holder != a.nation_id \
				and Diplomacy.are_at_war(world, a.nation_id, holder):
			s["besieging"] += 1
			continue
		var near := false
		for nb: int in p.land_neighbors:
			if _hostile_at(world, a.nation_id, nb):
				near = true
				break
		if near:
			s["adjacent_idle"] += 1
		else:
			s["marching"] += 1

	# 내 땅에 들어와 앉은 적 야전군이 방치되는가
	for a in world.armies:
		if not a.is_alive or a.province_id < 0:
			continue
		var p: Province = world.provinces[a.province_id]
		var holder := p.controller()
		if holder < 0 or holder == a.nation_id:
			continue
		if not Diplomacy.are_at_war(world, a.nation_id, holder):
			continue
		s["intruder_turns"] += 1
		if _hostile_at(world, a.nation_id, a.province_id):
			s["intruder_contested"] += 1


func _hostile_at(world: WorldState, nation_id: int, pid: int) -> bool:
	for other_id: int in world.armies_at(pid):
		var o: Army = world.armies[other_id]
		if o.is_alive and Diplomacy.are_at_war(world, nation_id, o.nation_id):
			return true
	return false


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
