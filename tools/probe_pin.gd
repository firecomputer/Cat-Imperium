extends SceneTree

## 약소국이 소부대를 던져 강군을 묶는가. 턴이 이산이라 한 번 붙으면 이동·공성이
## 멈추므로, 압도적 우세군이 소부대에 잡혀 있는 시간을 센다.
##   godot4 --headless --path . --script res://tools/probe_pin.gd -- --runs 4 --turns 300

## 이 배수 이상 차이면 "던진 것" 으로 본다 (combat_power 비).
const HOPELESS_RATIO := 4.0

var blocker_garrison := 0
var blocker_field := 0
var thrown_garrison := 0
var thrown_escapable := 0
var thrown_trapped := 0
var thrown_at_capital := 0
var withdrew := 0


## 물러설 칸이 있는가 — 적 없는 내가 쥔 인접 프로빈스.
func _escape(world: WorldState, army: Army) -> bool:
	for nb: int in world.provinces[army.province_id].land_neighbors:
		if world.provinces[nb].controller() != army.nation_id:
			continue
		var blocked := false
		for other_id: int in world.armies_at(nb):
			var o: Army = world.armies[other_id]
			if o.is_alive and Diplomacy.are_at_war(world, army.nation_id, o.nation_id):
				blocked = true
				break
		if not blocked:
			return true
	return false


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 4))
	var turns := int(args.get("turns", 300))
	var map_kind := MapSource.parse_kind(args.get("map-source", "noise"))

	var engaged := 0
	var owner_ground := 0             # 묶인 칸이 묶은 쪽 땅인가
	var pinned := 0                   # 압도적 우세인데 소부대에 묶인 군대-턴
	var pinned_siege := 0             # 그중 공성이 걸릴 수 있었던 칸
	var thrown := 0                   # 절망적 열세로 붙은 군대-턴
	var thrower_troops := PackedInt32Array()
	var victim_troops := PackedInt32Array()
	var pin_lengths := PackedInt32Array()
	var live := {}                    # army_id -> 연속 묶인 턴

	for i in range(runs):
		var world := WorldState.create(1 + i, map_kind)
		live.clear()
		for t in range(turns):
			SimClock.tick(world)
			var seen := {}
			for a in world.armies:
				if not a.is_alive or a.province_id < 0:
					continue
				var mine := Military.combat_power(world, a)
				var enemy := 0.0
				var enemy_troops := 0
				for other_id: int in world.armies_at(a.province_id):
					var o: Army = world.armies[other_id]
					if not o.is_alive or not Diplomacy.are_at_war(world, a.nation_id, o.nation_id):
						continue
					enemy += Military.combat_power(world, o)
					enemy_troops += o.troops
					blocker_garrison += 1 if o.garrison_province >= 0 else 0
					blocker_field += 1 if o.garrison_province < 0 else 0
				if enemy <= 0.0:
					continue
				engaged += 1
				if mine >= enemy * HOPELESS_RATIO:
					pinned += 1
					if world.provinces[a.province_id].owner_nation != a.nation_id:
						owner_ground += 1
					seen[a.id] = true
					live[a.id] = int(live.get(a.id, 0)) + 1
					thrower_troops.append(enemy_troops)
					victim_troops.append(a.troops)
					var p: Province = world.provinces[a.province_id]
					var holder := p.controller()
					if holder >= 0 and holder != a.nation_id \
							and Diplomacy.are_at_war(world, a.nation_id, holder):
						pinned_siege += 1
				elif enemy >= mine * HOPELESS_RATIO:
					thrown += 1
					if a.garrison_province >= 0:
						thrown_garrison += 1
					elif _escape(world, a):
						thrown_escapable += 1
					else:
						thrown_trapped += 1
					if world.provinces[a.province_id].id == world.nations[a.nation_id].capital:
						thrown_at_capital += 1
			for e in world.events:
				if e["kind"] == "army_withdrew":
					withdrew += 1
			world.events.clear()
			for army_id: int in live.keys():
				if not seen.has(army_id):
					pin_lengths.append(int(live[army_id]))
					live.erase(army_id)

	print("runs=%d turns=%d" % [runs, turns])
	var e := maxi(engaged, 1)
	print("교전 군대-턴 %d" % e)
	print("  압도적 우세인데 묶임 %6.2f%%  (그중 공성이 막힌 칸 %5.1f%%)" \
		% [100.0 * pinned / e, 100.0 * pinned_siege / maxf(pinned, 1)])
	print("  절망적 열세로 붙음   %6.2f%%" % [100.0 * thrown / e])
	print("  묶은 부대 병력 " + _fq(thrower_troops))
	print("  묶인 부대 병력 " + _fq(victim_troops))
	print("  한 번 묶이면 지속 " + _fq(pin_lengths))
	print("  묶인 칸이 적 소유 영토인 비율 %5.1f%%" % [100.0 * owner_ground / maxf(pinned, 1)])
	print("  묶은 부대: 치안분견대 %d, 야전군 %d" % [blocker_garrison, blocker_field])
	print("  열세로 붙은 부대: 치안분견대 %d, 퇴로있음 %d, 퇴로없음 %d, 자국 수도 %d" \
		% [thrown_garrison, thrown_escapable, thrown_trapped, thrown_at_capital])
	print("  army_withdrew 이벤트 %d" % withdrew)
	quit(0)


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
