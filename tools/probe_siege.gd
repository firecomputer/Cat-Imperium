extends SceneTree

## 공성이 왜 점령으로 안 끝나는지 본다. 압도적 우세국의 공성만 따로 센다.
##   godot4 --headless --path . --script res://tools/probe_siege.gd -- --runs 4 --turns 300
##
## 공성 에피소드 = siege_by_nation 이 붙은 시점부터 풀리는 시점까지.
## 끝난 이유: occupied / dropped(진행도만 리셋) / cleared(교전권 소멸·종전).

## 이 이상 강하면 "압도적" 으로 본다 (strategic_power 비).
const DOMINANT_RATIO := 2.0


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 4))
	var turns := int(args.get("turns", 300))
	var map_kind := MapSource.parse_kind(args.get("map-source", "noise"))

	var episodes: Array = []
	var rates := PackedFloat32Array()
	var dom_rates := PackedFloat32Array()
	var progress_at_end := PackedFloat32Array()
	var occupies := 0

	for i in range(runs):
		var world := WorldState.create(1 + i, map_kind)
		var live := {}                          # pid -> {nation, start, peak, ticks, dominant}
		for t in range(turns):
			SimClock.tick(world)
			_scan(world, live, episodes, rates, dom_rates, progress_at_end)
		for pid: int in live:
			var e: Dictionary = live[pid]
			e["end"] = "unfinished"
			episodes.append(e)
		for e in world.events:
			if e["kind"] == "province_occupied":
				occupies += 1

	print("runs=%d turns=%d" % [runs, turns])
	print("공성 에피소드 %d, province_occupied %d" % [episodes.size(), occupies])
	var by_end := {}
	var dom: Array = []
	for e: Dictionary in episodes:
		by_end[e["end"]] = int(by_end.get(e["end"], 0)) + 1
		if e["dominant"]:
			dom.append(e)
	for k: String in by_end:
		print("  %-12s %5d (%5.1f%%)" % [k, by_end[k],
			100.0 * by_end[k] / maxf(episodes.size(), 1)])
	print("  지속 턴 " + _fq(_field(episodes, "ticks")))
	print("  최고 진행도 " + _fq(_field(episodes, "peak")))
	print("공성 속도(턴당 진행도) " + _fq(rates))
	print("  100 도달까지 필요한 턴 중앙값 %.1f" % [100.0 / maxf(_median(rates), 0.01)])

	print("압도적 우세국(전력비 >= %.1f)의 공성 %d 건" % [DOMINANT_RATIO, dom.size()])
	var dom_end := {}
	for e: Dictionary in dom:
		dom_end[e["end"]] = int(dom_end.get(e["end"], 0)) + 1
	for k: String in dom_end:
		print("  %-12s %5d (%5.1f%%)" % [k, dom_end[k],
			100.0 * dom_end[k] / maxf(dom.size(), 1)])
	print("  지속 턴 " + _fq(_field(dom, "ticks")))
	print("  최고 진행도 " + _fq(_field(dom, "peak")))
	print("  공성 속도 " + _fq(dom_rates))
	print("중단된 공성의 잔여 진행도 " + _fq(progress_at_end))
	print("진행도 리셋 %d 건: 공성측 국가 2 이상 %d, 단일 국가 %d, 적 부대 동석 %d" \
		% [reset_multi_nation + reset_single, reset_multi_nation, reset_single,
		reset_contested])
	quit(0)


func _scan(world: WorldState, live: Dictionary, episodes: Array,
		rates: PackedFloat32Array, dom_rates: PackedFloat32Array,
		progress_at_end: PackedFloat32Array) -> void:
	# 1. 지금 걸려 있는 공성
	var seen := {}
	for p in world.provinces:
		if p.siege_by_nation < 0:
			continue
		seen[p.id] = true
		var prev: Dictionary = live.get(p.id, {})
		if prev.is_empty() or int(prev["nation"]) != p.siege_by_nation:
			if not prev.is_empty():
				prev["end"] = "handover"
				prev["last"] = p.siege_progress
				episodes.append(prev)
			live[p.id] = {"nation": p.siege_by_nation, "start": world.turn,
				"peak": p.siege_progress, "ticks": 0, "last": p.siege_progress,
				"dominant": _dominant(world, p)}
			continue
		var e: Dictionary = live[p.id]
		var delta: float = p.siege_progress - float(e["last"])
		if delta > 0.0:
			rates.append(delta)
			if e["dominant"]:
				dom_rates.append(delta)
		elif delta < 0.0:
			_reset_causes(world, p, e)
			# 진행도가 리셋됐다 — 같은 나라의 다른 부대가 새로 건 경우다.
			progress_at_end.append(float(e["last"]))
			e["end"] = "reset"
			episodes.append(e.duplicate())
			e["start"] = world.turn
			e["ticks"] = 0
			e["peak"] = p.siege_progress
		e["ticks"] = int(e["ticks"]) + 1
		e["peak"] = maxf(float(e["peak"]), p.siege_progress)
		e["last"] = p.siege_progress
		e["dominant"] = bool(e["dominant"]) or _dominant(world, p)

	# 2. 사라진 공성 — 점령으로 끝났는지, 그냥 풀렸는지
	for pid: int in live.keys():
		if seen.has(pid):
			continue
		var e: Dictionary = live[pid]
		var p: Province = world.provinces[pid]
		e["end"] = "occupied" if p.controller() == int(e["nation"]) else "dropped"
		if e["end"] == "dropped":
			progress_at_end.append(float(e["last"]))
		episodes.append(e)
		live.erase(pid)


## 리셋 순간의 그림. 같은 칸에 공성측 국가가 둘 이상이면 tick_sieges 의
## siege_by_nation 갈아치우기가 매 턴 진행도를 0 으로 되돌린다.
var reset_multi_nation := 0
var reset_single := 0
var reset_contested := 0


func _reset_causes(world: WorldState, p: Province, e: Dictionary) -> void:
	var sieger := int(e["nation"])
	var friendly := {}
	var hostile := 0
	for army_id: int in world.armies_at(p.id):
		var a: Army = world.armies[army_id]
		if not a.is_alive:
			continue
		if a.nation_id == p.controller() or Diplomacy.are_at_war(world, sieger, a.nation_id):
			hostile += 1
			continue
		friendly[a.nation_id] = true
	if hostile > 0:
		reset_contested += 1
	if friendly.size() > 1:
		reset_multi_nation += 1
	else:
		reset_single += 1


## 이 프로빈스를 공성 중인 나라가 소유국을 압도하는가.
func _dominant(world: WorldState, p: Province) -> bool:
	if p.siege_by_nation < 0 or p.owner_nation < 0:
		return false
	var attacker: Nation = world.nations[p.siege_by_nation]
	var owner: Nation = world.nations[p.owner_nation]
	return Military.strategic_power(world, attacker) \
		>= Military.strategic_power(world, owner) * DOMINANT_RATIO


func _field(rows: Array, key: String) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for r: Dictionary in rows:
		out.append(float(r[key]))
	return out


func _median(v: PackedFloat32Array) -> float:
	if v.is_empty():
		return 0.0
	var arr := Array(v)
	arr.sort()
	return float(arr[arr.size() / 2])


func _fq(v: PackedFloat32Array) -> String:
	if v.is_empty():
		return "(없음)"
	var arr := Array(v)
	arr.sort()
	var n := arr.size()
	var mean := 0.0
	for x: float in arr:
		mean += x
	return "n=%d p10=%.1f p50=%.1f p90=%.1f 평균=%.1f" % [n, arr[n / 10], arr[n / 2],
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
