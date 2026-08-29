extends SceneTree

## 헤드리스 배치 실행. 감(感)으로는 이 정도로 얽힌 시스템을 밸런싱할 수 없다.
##
##   godot --headless --script res://tools/batch_sim.gd -- --runs 100 --turns 300 --out res://out/runs.csv
##   python tools/analyze.py out/runs.csv
##
## 옵션: --runs N, --turns N, --seed0 N, --sample N (샘플 간격 턴), --out PATH

const EPS := 1.0
const FIRST_DEFAULT_MIN := 100
const FIRST_DEFAULT_MAX := 250
const CREDIT_EVENT_KINDS := ["credit_started", "money_printing_started", "national_default"]


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 100))
	var turns := int(args.get("turns", 300))
	var seed0 := int(args.get("seed0", 1))
	var sample := int(args.get("sample", 10))
	var out_path: String = args.get("out", "res://out/runs.csv")

	var lines := PackedStringArray(["seed,turn,nations,provinces,population,pop_error_pct,gdp,"
		+ "max_gdp_pc,hard_anchor_violations,soft_anchor_violations,mean_infra,max_infra,"
		+ "cities,max_soft_overshoot,mean_inflation,min_inflation,max_inflation,"
		+ "mean_debt_ratio,max_debt_ratio,mean_credit_rating,mean_interest,"
		+ "mean_primary_balance_ratio,mean_interest_burden,printing,bankrupt,defaults_cum,rebels"])
	var default_lines := PackedStringArray(["seed,turn,nation,culture,count,gdp,debt,inflation,"
		+ "provinces,printing_streak,income,expenses,interest"])
	var event_lines := PackedStringArray(["seed,turn,kind,nation,culture,gdp,debt,inflation,"
		+ "borrowing,shortfall,count,printing_streak,income,expenses,interest,provinces"])
	var first_defaults: Array[int] = []

	var t0 := Time.get_ticks_msec()
	for i in range(runs):
		var s := seed0 + i
		var world := WorldState.create(s)
		var pop0 := world.world_population()
		lines.append(_sample_row(world, pop0))
		for t in range(turns):
			SimClock.tick(world)
			if world.turn % sample == 0 or t == turns - 1:
				lines.append(_sample_row(world, pop0))
		var first_default := -1
		for e in world.events:
			if e["kind"] not in CREDIT_EVENT_KINDS:
				continue
			var nation_id := int(e["nation"])
			# 반란 독립국은 1프로빈스 파산 상태로 태어난다. M5 지표(첫 파산 100~250턴)는
			# 건국국가의 붕괴를 재는 것이므로 반란국의 재정 이벤트는 제외한다.
			if world.nations[nation_id].is_rebel:
				continue
			var culture_name: String = Culture.NAMES[world.nations[nation_id].culture]
			event_lines.append(_event_row(s, e, culture_name))
			if e["kind"] == "national_default":
				default_lines.append(_default_row(s, e, culture_name))
				if first_default < 0:
					first_default = int(e["turn"])
		if first_default >= 0:
			first_defaults.append(first_default)

	var f := FileAccess.open(out_path, FileAccess.WRITE)
	if f == null:
		push_error("CSV 저장 실패: %s" % out_path)
		quit(1)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()

	print("runs=%d turns=%d  (%.1fs)" % [runs, turns, (Time.get_ticks_msec() - t0) / 1000.0])
	var default_path: String = args.get("defaults", out_path.get_basename() + "_defaults.csv")
	var df := FileAccess.open(default_path, FileAccess.WRITE)
	if df != null:
		df.store_string("\n".join(default_lines) + "\n")
		df.close()
	var event_path: String = args.get("events", out_path.get_basename() + "_credit_events.csv")
	var ef := FileAccess.open(event_path, FileAccess.WRITE)
	if ef != null:
		ef.store_string("\n".join(event_lines) + "\n")
		ef.close()

	print("wrote %s" % ProjectSettings.globalize_path(out_path))
	print("wrote %s  (파산 %d건)" % [ProjectSettings.globalize_path(default_path), default_lines.size() - 1])
	print("wrote %s" % ProjectSettings.globalize_path(event_path))
	_print_default_summary(first_defaults, runs)
	quit(0)


func _sample_row(world: WorldState, pop0: float) -> String:
	var pop := world.world_population()
	var gdp := 0.0
	var max_pc := 0.0
	var hard := 0
	var soft := 0
	var infra_sum := 0.0
	var max_infra := 0.0
	var cities := 0
	var overshoot := 1.0
	# 구조적 상한 = 앵커 4080 × 도시 1.2 × 법률 생산성 (§4.3 이 곱하는 항 전부)
	var base_cap := (Economy.GDP_PC_MAX + Economy.GDP_PC_FLOOR) * Economy.CITY_ANCHOR_BONUS

	for p in world.provinces:
		gdp += p.gdp
		max_pc = maxf(max_pc, p.gdp_pc)
		infra_sum += p.infra
		max_infra = maxf(max_infra, p.infra)
		if p.has_city:
			cities += 1
		var n: Nation = world.nations[p.owner_nation]
		if p.gdp_pc > base_cap * n.law_modifier("productivity") + EPS:
			hard += 1
		var anchor := Economy.gdp_pc_anchor(p.infra) * p.terrain_mult \
			* n.law_modifier("productivity") * (1.0 - p.unrest * 0.6)
		if p.has_city:
			anchor *= Economy.CITY_ANCHOR_BONUS
		if p.gdp_pc > anchor + EPS:
			soft += 1
			overshoot = maxf(overshoot, p.gdp_pc / maxf(anchor, 1.0))

	var infl_sum := 0.0
	var infl_min := INF
	var infl_max := -INF
	var debt_ratio := 0.0
	var max_debt_ratio := 0.0
	var rating := 0.0
	var interest := 0.0
	var primary_balance := 0.0
	var interest_burden := 0.0
	var printing := 0
	var bankrupt := 0
	var defaults_cum := 0
	var counted := 0
	var rebels := 0
	for n in world.nations:
		if n.is_rebel:
			rebels += 1
		if n.is_rebel or not n.is_alive:
			continue                      # 집계는 살아있는 건국국가 기준
		counted += 1
		infl_sum += n.inflation
		infl_min = minf(infl_min, n.inflation)
		infl_max = maxf(infl_max, n.inflation)
		var dr := n.debt / maxf(n.gdp, 1.0)
		debt_ratio += dr
		max_debt_ratio = maxf(max_debt_ratio, dr)
		rating += n.credit_rating
		interest += Credit.interest_rate(n)
		primary_balance += (n.income - n.expenses) / maxf(n.gdp, 1.0)
		interest_burden += n.interest_expense / maxf(n.gdp, 1.0)
		if n.printing_streak > 0:
			printing += 1
		if n.bankruptcy_timer > 0:
			bankrupt += 1
		defaults_cum += n.default_history
	var nc := maxf(counted, 1)

	return ",".join(PackedStringArray([str(world.world_seed), str(world.turn),
		str(counted), str(world.provinces.size()), "%.1f" % pop,
		"%.6f" % ((pop - pop0) / maxf(pop0, 1.0) * 100.0), "%.1f" % gdp, "%.1f" % max_pc,
		str(hard), str(soft), "%.3f" % (infra_sum / maxf(world.provinces.size(), 1)),
		"%.3f" % max_infra, str(cities), "%.4f" % overshoot, "%.4f" % (infl_sum / nc),
		"%.4f" % infl_min, "%.4f" % infl_max, "%.4f" % (debt_ratio / nc),
		"%.4f" % max_debt_ratio, "%.4f" % (rating / nc), "%.4f" % (interest / nc),
		"%.4f" % (primary_balance / nc), "%.4f" % (interest_burden / nc),
		str(printing), str(bankrupt), str(defaults_cum), str(rebels)]))


func _default_row(seed: int, e: Dictionary, culture_name: String) -> String:
	return ",".join(PackedStringArray([str(seed), str(e["turn"]), str(e["nation"]), culture_name,
		str(e["count"]), "%.1f" % e["gdp"], "%.1f" % e["debt"], "%.4f" % e["inflation"],
		str(e["provinces"]), str(e["printing_streak"]), "%.1f" % e["income"],
		"%.1f" % e["expenses"], "%.1f" % e["interest"]]))


func _event_row(seed: int, e: Dictionary, culture_name: String) -> String:
	return ",".join(PackedStringArray([str(seed), str(e["turn"]), str(e["kind"]),
		str(e["nation"]), culture_name, "%.1f" % e.get("gdp", 0.0), "%.1f" % e.get("debt", 0.0),
		"%.4f" % e.get("inflation", 0.0), "%.1f" % e.get("borrowing", 0.0),
		"%.1f" % e.get("shortfall", 0.0), str(e.get("count", 0)),
		str(e.get("printing_streak", 0)), "%.1f" % e.get("income", 0.0),
		"%.1f" % e.get("expenses", 0.0), "%.1f" % e.get("interest", 0.0),
		str(e.get("provinces", 0))]))


func _print_default_summary(first_defaults: Array[int], runs: int) -> void:
	if first_defaults.is_empty():
		print("first_default: 없음 (0/%d runs)  FAIL" % runs)
		return
	var total := 0.0
	var earliest := first_defaults[0]
	var latest := first_defaults[0]
	var too_early := 0
	for turn in first_defaults:
		total += turn
		earliest = mini(earliest, turn)
		latest = maxi(latest, turn)
		if turn < 50:
			too_early += 1
	var mean := total / first_defaults.size()
	var ok := mean >= FIRST_DEFAULT_MIN and mean <= FIRST_DEFAULT_MAX
	print("first_default: mean=%.1f range=%d..%d defaults=%d/%d runs under_50=%d  %s" % [
		mean, earliest, latest, first_defaults.size(), runs, too_early, "PASS" if ok else "FAIL"])


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
				out[key] = true
		i += 1
	return out
