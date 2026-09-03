extends SceneTree

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## 헤드리스 배치 실행. 감(感)으로는 이 정도로 얽힌 시스템을 밸런싱할 수 없다.
##
##   godot --headless --script res://tools/batch_sim.gd -- --runs 100 --turns 300 --out res://out/runs.csv
##   python tools/analyze.py out/runs.csv
##
## 옵션: --runs N, --turns N, --seed0 N, --sample N, --map-source earth|noise, --out PATH

const EPS := 1.0
const FIRST_DEFAULT_MIN := 80
const FIRST_DEFAULT_MAX := 250
const CREDIT_EVENT_KINDS := ["credit_started", "money_printing_started", "national_default"]
## 제국 판정 문턱은 EmpireSystem.empire_threshold() 가 세계 국가 수로 환산한다.
## 유지 턴 24 인 M12 정의는 산출된 에피소드를 duration 으로 거르면 얻어지므로,
## 여기서는 후보 진입 턴을 그대로 남긴다.
const EMPIRE_CONFIRM_TURNS := 12
## M12 정의. 에피소드 로그는 12턴(느슨한 쪽)으로 남겨야 duration 으로 24턴을
## 재도출할 수 있다 — 24로 기록하면 12턴 정의와의 대조가 불가능해진다.
## 스냅샷의 empires_active_24 만 이 값을 쓴다.
const EMPIRE_CONFIRM_TURNS_M12 := 24
## 실효 국가 = 프로빈스 3개 이상. 잔존국이 지표를 인질로 잡지 못하게 한다 (2차 §0.1).
const EFFECTIVE_MIN_PROVINCES := 3
## §6.2 의 부채 상한. 초과 자체가 아니라 *얼마나 오래* 초과하는지를 센다 —
## 영토를 잃어 분모가 사라진 나라는 파산·탕감으로 3턴이면 3.5 아래로 돌아온다.
const DEBT_RATIO_LIMIT := 10.0


func _initialize() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var runs := int(args.get("runs", 100))
	var turns := int(args.get("turns", 300))
	var seed0 := int(args.get("seed0", 1))
	var sample := int(args.get("sample", 10))
	var out_path: String = args.get("out", "res://out/runs.csv")
	var map_kind := MapSource.parse_kind(args.get("map-source", "earth"))
	if map_kind < 0:
		quit(2)
		return

	var lines := PackedStringArray(["seed,turn,nations,provinces,population,pop_error_pct,gdp,"
		+ "max_gdp_pc,hard_anchor_violations,soft_anchor_violations,mean_infra,max_infra,"
		+ "cities,max_soft_overshoot,mean_inflation,min_inflation,max_inflation,"
		+ "mean_debt_ratio,max_debt_ratio,mean_credit_rating,mean_interest,"
		+ "mean_primary_balance_ratio,mean_interest_burden,printing,bankrupt,defaults_cum,rebels,"
		+ "anchor_over_turns_max,gini_between,gini_within,war_supply_mean,war_armies,"
		+ "effective_nations,max_realm_share,max_realm_provinces,empires_active,"
		+ "agg_debt_ratio,median_debt_ratio,debt_over_turns_max,"
		# 실효 국가(프로빈스 >= 3) 한정 재산출. 잔존국이 대역을 인질로 잡는지 본다 (M12).
		+ "gini_between_eff,gini_within_eff,war_supply_mean_eff,war_armies_eff,"
		+ "mean_debt_ratio_eff,max_debt_ratio_eff,agg_debt_ratio_eff,"
		+ "median_debt_ratio_eff,debt_over_turns_max_eff,empires_active_24"])
	var default_lines := PackedStringArray(["seed,turn,nation,culture,count,gdp,debt,inflation,"
		+ "provinces,printing_streak,income,expenses,interest"])
	var event_lines := PackedStringArray(["seed,turn,kind,nation,culture,gdp,debt,inflation,"
		+ "borrowing,shortfall,count,printing_streak,income,expenses,interest,provinces"])
	var nation_lines := PackedStringArray(["seed,nation,culture,start_region,is_rebel,birth_turn,death_turn,"
		+ "ever_exclave,peak_provinces,final_provinces"])
	var empire_lines := PackedStringArray([
		"seed,nation,start_region,enter_turn,exit_turn,duration,peak_realm_share,reason"])
	var first_defaults: Array[int] = []

	var t0 := Time.get_ticks_msec()
	for i in range(runs):
		var s := seed0 + i
		var world := WorldState.create(s, map_kind)
		var pop0 := world.world_population()
		var prev_pc := PackedFloat32Array()
		prev_pc.resize(world.provinces.size())
		var over_turns := PackedInt32Array()
		over_turns.resize(world.provinces.size())
		for p in world.provinces:
			prev_pc[p.id] = p.gdp_pc
		var hard := 0
		var over_max := 0
		var debt_over := {}      # nation id -> 연속 초과 턴
		var debt_over_max := 0
		var debt_over_eff := {}  # 실효 국가만 (M12)
		var debt_over_max_eff := 0
		var empires24 := 0
		var life := {}          # nation id -> 생애 기록
		var empires := {}       # nation id -> 제국 에피소드 추적
		_track_nations(world, life)
		lines.append(_sample_row(world, pop0, hard, over_max, debt_over_max,
			debt_over_max_eff, empires24))
		for t in range(turns):
			SimClock.tick(world)
			_track_nations(world, life)
			empires24 = _track_empires(world, empires, empire_lines, s, false)
			for p in world.provinces:
				# 생산 틱이 실제로 쓴 앵커로 잰다. 여기서 다시 계산하면 같은 턴의
				# 불만·법률·소유국 변경이 섞여 정상 수렴이 위반으로 잡힌다.
				var anchor := p.anchor_gdp_pc
				if p.gdp_pc <= anchor + EPS:
					over_turns[p.id] = 0
				else:
					# 앵커가 내려가서 생긴 과도 상태는 위반이 아니라 감쇠다. 진짜 위반은
					# 앵커 위에 있으면서 gdp_pc 가 *올라간* 경우뿐이다 (M11 §M3).
					if p.gdp_pc > prev_pc[p.id] + EPS:
						hard += 1
					over_turns[p.id] += 1
					over_max = maxi(over_max, over_turns[p.id])
				prev_pc[p.id] = p.gdp_pc
			for n in world.nations:
				if n.is_rebel or not n.is_alive \
						or n.debt / maxf(n.gdp, 1.0) <= DEBT_RATIO_LIMIT:
					debt_over[n.id] = 0
					debt_over_eff[n.id] = 0
					continue
				debt_over[n.id] = int(debt_over.get(n.id, 0)) + 1
				debt_over_max = maxi(debt_over_max, int(debt_over[n.id]))
				if n.provinces.size() < EFFECTIVE_MIN_PROVINCES:
					debt_over_eff[n.id] = 0
					continue
				debt_over_eff[n.id] = int(debt_over_eff.get(n.id, 0)) + 1
				debt_over_max_eff = maxi(debt_over_max_eff, int(debt_over_eff[n.id]))
			if world.turn % sample == 0 or t == turns - 1:
				lines.append(_sample_row(world, pop0, hard, over_max, debt_over_max,
					debt_over_max_eff, empires24))
		_track_empires(world, empires, empire_lines, s, true)
		for e in world.events:
			if e["kind"] == "nation_died":
				var dead: Dictionary = life.get(int(e["nation"]), {})
				if not dead.is_empty() and int(dead["death"]) < 0:
					dead["death"] = int(e["turn"])
		var life_ids: Array = life.keys()
		life_ids.sort()
		for nid in life_ids:
			nation_lines.append(_nation_row(s, world.nations[nid], life[nid]))

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

	print("runs=%d turns=%d map_source=%s  (%.1fs)" % [runs, turns,
		MapSource.kind_name(map_kind), (Time.get_ticks_msec() - t0) / 1000.0])
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
	var nation_path: String = args.get("nations", out_path.get_basename() + "_nations.csv")
	_write(nation_path, nation_lines)
	var empire_path: String = args.get("empires", out_path.get_basename() + "_empires.csv")
	_write(empire_path, empire_lines)
	print("wrote %s  (국가 %d개)" % [ProjectSettings.globalize_path(nation_path),
		nation_lines.size() - 1])
	print("wrote %s  (제국 에피소드 %d건)" % [ProjectSettings.globalize_path(empire_path),
		empire_lines.size() - 1])
	_print_default_summary(first_defaults, runs)
	quit(0)


func _sample_row(world: WorldState, pop0: float, hard: int, over_turns_max: int,
		debt_over_turns_max: int, debt_over_turns_max_eff: int, empires24: int) -> String:
	var pop := world.world_population()
	var gdp := 0.0
	var max_pc := 0.0
	var soft := 0
	var infra_sum := 0.0
	var max_infra := 0.0
	var cities := 0
	var overshoot := 1.0

	for p in world.provinces:
		gdp += p.gdp
		max_pc = maxf(max_pc, p.gdp_pc)
		infra_sum += p.infra
		max_infra = maxf(max_infra, p.infra)
		if p.has_city:
			cities += 1
		if p.gdp_pc > p.anchor_gdp_pc + EPS:
			soft += 1
			overshoot = maxf(overshoot, p.gdp_pc / maxf(p.anchor_gdp_pc, 1.0))

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
	var effective := 0
	var debt_ratios: Array[float] = []
	var debt_sum := 0.0
	var gdp_sum := 0.0
	var debt_ratio_eff := 0.0
	var max_debt_ratio_eff := 0.0
	var debt_ratios_eff: Array[float] = []
	var debt_sum_eff := 0.0
	var gdp_sum_eff := 0.0
	for n in world.nations:
		if n.is_rebel and n.is_alive:
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
		debt_ratios.append(dr)
		debt_sum += n.debt
		gdp_sum += n.gdp
		rating += n.credit_rating
		interest += Credit.interest_rate(n)
		primary_balance += (n.income - n.expenses) / maxf(n.gdp, 1.0)
		interest_burden += n.interest_expense / maxf(n.gdp, 1.0)
		if n.provinces.size() >= EFFECTIVE_MIN_PROVINCES:
			effective += 1
			debt_ratio_eff += dr
			max_debt_ratio_eff = maxf(max_debt_ratio_eff, dr)
			debt_ratios_eff.append(dr)
			debt_sum_eff += n.debt
			gdp_sum_eff += n.gdp
		if n.printing_streak > 0:
			printing += 1
		if n.bankruptcy_timer > 0:
			bankrupt += 1
		defaults_cum += n.default_history
	var nc := maxf(counted, 1)

	var realms := _realm_values(world)
	var world_value: float = realms["world"]
	var max_share := 0.0
	var max_realm_provs := 0
	var empires_active := 0
	for n in world.nations:
		if not n.is_alive or n.is_rebel or n.overlord >= 0:
			continue
		var share: float = float(realms["value"].get(n.id, 0.0)) / world_value
		max_share = maxf(max_share, share)
		max_realm_provs = maxi(max_realm_provs, int(realms["provinces"].get(n.id, 0)))
		if share >= EmpireSystem.empire_threshold(world) and not n.vassals.is_empty():
			empires_active += 1
	var supply := _war_supply(world, false)
	var supply_eff := _war_supply(world, true)
	debt_ratios.sort()
	var median_debt := 0.0 if debt_ratios.is_empty() \
		else debt_ratios[debt_ratios.size() / 2]
	debt_ratios_eff.sort()
	var median_debt_eff := 0.0 if debt_ratios_eff.is_empty() \
		else debt_ratios_eff[debt_ratios_eff.size() / 2]
	var ne := maxf(effective, 1)

	return ",".join(PackedStringArray([str(world.world_seed), str(world.turn),
		str(counted), str(world.provinces.size()), "%.1f" % pop,
		"%.6f" % ((pop - pop0) / maxf(pop0, 1.0) * 100.0), "%.1f" % gdp, "%.1f" % max_pc,
		str(hard), str(soft), "%.3f" % (infra_sum / maxf(world.provinces.size(), 1)),
		"%.3f" % max_infra, str(cities), "%.4f" % overshoot, "%.4f" % (infl_sum / nc),
		"%.4f" % infl_min, "%.4f" % infl_max, "%.4f" % (debt_ratio / nc),
		"%.4f" % max_debt_ratio, "%.4f" % (rating / nc), "%.4f" % (interest / nc),
		"%.4f" % (primary_balance / nc), "%.4f" % (interest_burden / nc),
		str(printing), str(bankrupt), str(defaults_cum), str(rebels),
		str(over_turns_max), "%.4f" % _gini_between(world, false),
		"%.4f" % _gini_within(world, false),
		"%.4f" % supply.x, str(int(supply.y)), str(effective),
		"%.5f" % max_share, str(max_realm_provs), str(empires_active),
		"%.4f" % (debt_sum / maxf(gdp_sum, 1.0)), "%.4f" % median_debt,
		str(debt_over_turns_max),
		"%.4f" % _gini_between(world, true), "%.4f" % _gini_within(world, true),
		"%.4f" % supply_eff.x, str(int(supply_eff.y)),
		"%.4f" % (debt_ratio_eff / ne), "%.4f" % max_debt_ratio_eff,
		"%.4f" % (debt_sum_eff / maxf(gdp_sum_eff, 1.0)), "%.4f" % median_debt_eff,
		str(debt_over_turns_max_eff), str(empires24)]))


func _write(path: String, lines: PackedStringArray) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("CSV 저장 실패: %s" % path)
		return
	f.store_string("\n".join(lines) + "\n")
	f.close()


# ------------------------------------------------------- 국가 생애 (M11.1 월경지 수명)

## 국가의 출생·사망·월경지 보유 이력. 반란 독립국은 세계 생성 뒤에 태어나므로
## 배열 인덱스가 아니라 "처음 살아 있는 것을 본 턴" 을 출생으로 잡는다.
func _track_nations(world: WorldState, life: Dictionary) -> void:
	for n in world.nations:
		var rec: Dictionary = life.get(n.id, {})
		if rec.is_empty():
			if not n.is_alive:
				continue
			rec = {"birth": world.turn, "death": -1, "exclave": false, "peak": 0}
			life[n.id] = rec
		if not n.is_alive:
			continue
		rec["peak"] = maxi(int(rec["peak"]), n.provinces.size())
		if bool(rec["exclave"]):
			continue
		for pid in n.provinces:
			if world.provinces[pid].is_exclave:
				rec["exclave"] = true
				break


func _nation_row(seed: int, n: Nation, rec: Dictionary) -> String:
	return ",".join(PackedStringArray([str(seed), str(n.id), Culture.NAMES[n.culture],
		MapSource.region_name(n.start_region), "1" if n.is_rebel else "0",
		str(rec["birth"]), str(rec["death"]),
		"1" if bool(rec["exclave"]) else "0", str(rec["peak"]), str(n.provinces.size())]))


# ------------------------------------------------------- 제국 생애사 (M11.2)

## EmpireSystem.realm_share 를 국가마다 부르면 프로빈스를 국가 수만큼 다시 훑는다.
## 600턴 × 20런에서는 그 비용이 시뮬 자체보다 커지므로 프로빈스 1회 순회로 모은다.
func _realm_values(world: WorldState) -> Dictionary:
	var world_value := 0.0
	var by_root := {}
	var provs := {}
	for p in world.provinces:
		var v := p.gdp * (2.0 if p.has_city else 1.0)
		world_value += v
		var owner: Nation = world.nations[p.owner_nation]
		if not owner.is_alive:
			continue
		var root := EmpireSystem.realm_root(world, owner.id)
		by_root[root] = float(by_root.get(root, 0.0)) + v
		provs[root] = int(provs.get(root, 0)) + 1
	return {"world": maxf(world_value, 1.0), "value": by_root, "provinces": provs}


## 반환값: M12 정의(유지 24턴)로 현재 성립해 있는 제국 수. 에피소드 로그 자체는
## 12턴 기준으로 남는다.
func _track_empires(world: WorldState, tracker: Dictionary, lines: PackedStringArray,
		seed: int, finish: bool) -> int:
	var realms := _realm_values(world)
	var world_value: float = realms["world"]
	var by_root: Dictionary = realms["value"]
	var seen := {}
	for n in world.nations:
		if not n.is_alive or n.is_rebel or n.overlord >= 0:
			continue
		seen[n.id] = true
		var share := float(by_root.get(n.id, 0.0)) / world_value
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
				_close_empire(lines, world, seed, n.id, slot, "realm_share_below_threshold")
			slot["candidate"] = -1
			if not bool(slot["active"]):
				slot["peak"] = 0.0
		tracker[n.id] = slot
	var ids: Array = tracker.keys()
	ids.sort()
	var active24 := 0
	for nation_id in ids:
		var slot: Dictionary = tracker[nation_id]
		if not bool(slot["active"]):
			continue
		if not seen.has(nation_id):
			_close_empire(lines, world, seed, int(nation_id), slot, "realm_collapsed")
		elif finish:
			_close_empire(lines, world, seed, int(nation_id), slot, "horizon")
		elif world.turn - int(slot["enter"]) + 1 >= EMPIRE_CONFIRM_TURNS_M12:
			active24 += 1
		tracker[nation_id] = slot
	return active24


func _close_empire(lines: PackedStringArray, world: WorldState, seed: int, nation_id: int,
		slot: Dictionary, reason: String) -> void:
	var enter := int(slot["enter"])
	var region := world.nations[nation_id].start_region
	lines.append(",".join(PackedStringArray([str(seed), str(nation_id), MapSource.region_name(region),
		str(enter),
		str(world.turn), str(world.turn - enter), "%.5f" % float(slot["peak"]), reason])))
	slot["active"] = false
	slot["candidate"] = -1
	slot["enter"] = -1
	slot["peak"] = 0.0


# ------------------------------------------------------- 지니계수 (M11.1)

## 인구 가중 지니. 오름차순 정렬 후 G = Σ w·x·(2C − w − W) / (W²·mean).
func _gini(pairs: Array) -> float:
	if pairs.size() < 2:
		return 0.0
	pairs.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var total_w := 0.0
	var total_wx := 0.0
	for v: Vector2 in pairs:
		total_w += v.y
		total_wx += v.y * v.x
	if total_w <= 0.0 or total_wx <= 0.0:
		return 0.0
	var mean := total_wx / total_w
	var cum := 0.0
	var acc := 0.0
	for v: Vector2 in pairs:
		cum += v.y
		acc += v.y * v.x * (2.0 * cum - v.y - total_w)
	return clampf(acc / (total_w * total_w * mean), 0.0, 1.0)


## 국가 간: 국가별 1인당 GDP 를 인구로 가중한다. 국채(§14)가 먹는 축이다.
## eff_only 면 실효 국가(프로빈스 >= 3)만 센다 (M12 이중 산출).
func _gini_between(world: WorldState, eff_only: bool) -> float:
	var pairs: Array = []
	for n in world.nations:
		if not n.is_alive or n.population <= 0.0:
			continue
		if eff_only and n.provinces.size() < EFFECTIVE_MIN_PROVINCES:
			continue
		pairs.append(Vector2(n.gdp / n.population, n.population))
	return _gini(pairs)


## 국가 내: 국가마다 프로빈스 지니를 낸 뒤 인구로 가중 평균한다.
## 프로빈스 지분 상품이 먹는 축이므로 국가 간과 합산하지 않는다.
func _gini_within(world: WorldState, eff_only: bool) -> float:
	var acc := 0.0
	var total_pop := 0.0
	var floor_provs := EFFECTIVE_MIN_PROVINCES if eff_only else 2
	for n in world.nations:
		if not n.is_alive or n.provinces.size() < floor_provs or n.population <= 0.0:
			continue
		var pairs: Array = []
		for pid in n.provinces:
			var p: Province = world.provinces[pid]
			if p.population <= 0.0:
				continue
			pairs.append(Vector2(p.gdp_pc, p.population))
		acc += _gini(pairs) * n.population
		total_pop += n.population
	return acc / maxf(total_pop, 1.0)


# ------------------------------------------------------- 전쟁 보급 (M11.1)

## 교전국의 야전군 보급률. 주둔 분견대는 전선에 없으므로 제외한다.
func _war_supply(world: WorldState, eff_only: bool) -> Vector2:
	var total := 0.0
	var count := 0
	for army in world.armies:
		if not army.is_alive or army.garrison_province >= 0:
			continue
		var n: Nation = world.nations[army.nation_id]
		if not n.is_alive or not n.at_war:
			continue
		if eff_only and n.provinces.size() < EFFECTIVE_MIN_PROVINCES:
			continue
		total += army.supply_ratio
		count += 1
	return Vector2(total / maxf(count, 1), count)


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
