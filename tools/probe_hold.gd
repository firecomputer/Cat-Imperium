extends SceneTree

## 점령한 땅을 지키는가. 점령 → 귀환 → 재탈환의 왕복을 센다.
##   godot4 --headless --path . --script res://tools/probe_hold.gd -- --runs 4 --turns 300

func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 4))
	var turns := int(args.get("turns", 300))
	var map_kind := MapSource.parse_kind(args.get("map-source", "noise"))

	var occupied_turns := 0
	var held_by_army := 0
	var front_from_occupied := 0      # 점령지 옆 적지가 전선 목록에 있는가
	var front_missing := 0
	var idle_to_capital := 0          # 전선이 비어 수도로 돌아가는 야전군-턴
	var army_turns := 0
	var hold_lengths := PackedInt32Array()
	var flips := {}                   # "seed:pid" -> 점령 횟수
	var occupies := 0
	var liberations := 0

	for i in range(runs):
		var world := WorldState.create(1 + i, map_kind)
		var holding := {}             # pid -> 점령 시작 턴
		for t in range(turns):
			SimClock.tick(world)
			for p in world.provinces:
				if p.occupied_by_nation < 0:
					if holding.has(p.id):
						hold_lengths.append(world.turn - int(holding[p.id]))
						holding.erase(p.id)
					continue
				occupied_turns += 1
				if not holding.has(p.id):
					holding[p.id] = world.turn
				if _army_of(world, p.id, p.occupied_by_nation):
					held_by_army += 1
				# 점령지에서 전선이 뻗어 나가는가
				var occupier: Nation = world.nations[p.occupied_by_nation]
				var fronts := WarAI._fronts(world, occupier)
				for nb: int in p.land_neighbors:
					var q: Province = world.provinces[nb]
					var holder := q.controller()
					if holder < 0 or holder == occupier.id:
						continue
					if not Diplomacy.are_at_war(world, occupier.id, holder):
						continue
					if nb in fronts:
						front_from_occupied += 1
					else:
						front_missing += 1
			for n in world.nations:
				if not n.is_alive or not n.at_war:
					continue
				var fronts := WarAI._fronts(world, n)
				for army_id in n.armies:
					var a: Army = world.armies[army_id]
					if not a.is_alive or a.garrison_province >= 0:
						continue
					army_turns += 1
					if fronts.is_empty():
						idle_to_capital += 1
		for e in world.events:
			match e["kind"]:
				"province_occupied":
					occupies += 1
					var key := "%d:%d" % [i, int(e["province"])]
					flips[key] = int(flips.get(key, 0)) + 1
				"province_liberated":
					liberations += 1

	print("runs=%d turns=%d" % [runs, turns])
	print("점령 %d, 해방(되찾김) %d" % [occupies, liberations])
	var repeat := 0
	var worst := 0
	for k: String in flips:
		if int(flips[k]) > 1:
			repeat += 1
		worst = maxi(worst, int(flips[k]))
	print("  두 번 이상 손바뀜한 프로빈스 %d / %d (최다 %d회)" \
		% [repeat, flips.size(), worst])
	print("  점령 유지 기간 " + _fq(hold_lengths))
	var ot := maxi(occupied_turns, 1)
	print("점령지-턴 %d, 그중 점령국 군대가 실제로 서 있는 비율 %5.1f%%" \
		% [ot, 100.0 * held_by_army / ot])
	var ft := maxi(front_from_occupied + front_missing, 1)
	print("점령지에 인접한 적지 %d 건 중 전선으로 안 잡힘 %5.1f%%" \
		% [ft, 100.0 * front_missing / ft])
	print("전시 야전군-턴 %d, 그중 전선이 비어 수도로 돌아감 %5.1f%%" \
		% [maxi(army_turns, 1), 100.0 * idle_to_capital / maxi(army_turns, 1)])
	quit(0)


func _army_of(world: WorldState, pid: int, nation_id: int) -> bool:
	for army_id: int in world.armies_at(pid):
		var a: Army = world.armies[army_id]
		if a.is_alive and a.nation_id == nation_id:
			return true
	return false


func _fq(v: PackedInt32Array) -> String:
	if v.is_empty():
		return "(없음)"
	var arr := Array(v)
	arr.sort()
	var n := arr.size()
	var mean := 0.0
	for x: int in arr:
		mean += x
	return "n=%d p10=%d p50=%d p90=%d 평균=%.1f" % [n, arr[n / 10], arr[n / 2],
		arr[mini(n * 9 / 10, n - 1)], mean / n]


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
