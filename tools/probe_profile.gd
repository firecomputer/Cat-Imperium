extends SceneTree

## SimClock 단계별 소요 시간. 배치가 왜 느린지 감이 아니라 숫자로 본다.
##   godot --headless --script res://tools/probe_profile.gd -- --turns 600 --map-source earth

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

const STAGES := ["CharacterSystem", "LawSystem", "AdvisorEffects", "infra", "production",
	"migration", "tribute", "Credit", "Inflation", "Naval", "Supply", "Military",
	"Unrest", "aggregate1", "Diplomacy", "Peace", "aggregate2", "EmpireSystem", "Market"]


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var turns := int(args.get("turns", 600))
	var map_kind := MapSource.parse_kind(args.get("map-source", "earth"))

	var gen0 := Time.get_ticks_usec()
	var world := WorldState.create(1, map_kind)
	var gen_us := Time.get_ticks_usec() - gen0

	var totals := {}
	for s in STAGES:
		totals[s] = 0
	var run0 := Time.get_ticks_usec()
	for t in range(turns):
		_tick_timed(world, totals)
		world.events.clear()
	var run_us := Time.get_ticks_usec() - run0

	var order: Array = STAGES.duplicate()
	order.sort_custom(func(a: String, b: String) -> bool: return int(totals[a]) > int(totals[b]))
	print("맵 생성 %.2fs   %d턴 실행 %.2fs   프로빈스 %d" \
		% [gen_us / 1e6, turns, run_us / 1e6, world.provinces.size()])
	for s: String in order:
		var us: int = totals[s]
		print("  %-16s %7.2fs  %5.1f%%  (턴당 %.2fms)" \
			% [s, us / 1e6, 100.0 * us / maxf(float(run_us), 1.0), us / 1000.0 / turns])
	quit(0)


func _tick_timed(world: WorldState, totals: Dictionary) -> void:
	var t := Time.get_ticks_usec()
	CharacterSystem.tick(world);        t = _mark(totals, "CharacterSystem", t)
	LawSystem.tick(world);              t = _mark(totals, "LawSystem", t)
	AdvisorEffects.apply(world);        t = _mark(totals, "AdvisorEffects", t)
	Economy.tick_infra(world);          t = _mark(totals, "infra", t)
	Economy.tick_production(world);     t = _mark(totals, "production", t)
	Economy.tick_migration(world);      t = _mark(totals, "migration", t)
	EmpireSystem.collect_tribute(world); t = _mark(totals, "tribute", t)
	Credit.tick(world);                 t = _mark(totals, "Credit", t)
	Inflation.tick(world);              t = _mark(totals, "Inflation", t)
	Naval.tick(world);                  t = _mark(totals, "Naval", t)
	Supply.recompute_if_dirty(world);   t = _mark(totals, "Supply", t)
	Military.tick(world);               t = _mark(totals, "Military", t)
	Unrest.tick(world);                 t = _mark(totals, "Unrest", t)
	Economy.aggregate(world);           t = _mark(totals, "aggregate1", t)
	Diplomacy.tick(world);              t = _mark(totals, "Diplomacy", t)
	Peace.tick(world);                  t = _mark(totals, "Peace", t)
	Economy.aggregate(world);           t = _mark(totals, "aggregate2", t)
	EmpireSystem.tick(world);           t = _mark(totals, "EmpireSystem", t)
	Market.tick(world);                 t = _mark(totals, "Market", t)
	world.turn += 1


func _mark(totals: Dictionary, key: String, start: int) -> int:
	var now := Time.get_ticks_usec()
	totals[key] = int(totals[key]) + (now - start)
	return now


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
