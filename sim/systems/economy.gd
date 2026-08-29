class_name Economy extends RefCounted

## GDP / 인프라 / 인구. 인프라가 1인당 GDP의 하드 상한을 정의한다.

const GDP_PC_MAX := 4000.0
const CURVE_K := 0.42
const GDP_PC_FLOOR := 80.0
const GROWTH_RATE := 0.06      # 성장은 느리게 (따라잡기)
const DECLINE_RATE := 0.18     # 하락은 빠르게
const INFRA_MAX := 10.0

const MIGRATION_CAP := 0.06
const MIGRATION_SCALE := 0.5
const UNREST_PULL := 1.5
const DENSITY_PENALTY := 0.8

const CITY_RELATIVE_BONUS := 2.0
const CITY_ABSOLUTE_MIN := 4.0
const CITY_MIN_POP := 5000.0
const CITY_MIN_SPACING := 3
const CITY_ANCHOR_BONUS := 1.2
const CITY_UPKEEP_MULT := 3.0

const DECAY_PER_UNPAID := 0.12
const PILLAGE_DECAY := 0.5

## 문서 §4.4 의 비용 계수는 이 프로젝트의 GDP 규모보다 1000배 이상 작다.
## 건설 속도와 지급능력을 독립적으로 검증할 수 있게 단위 배율을 분리한다.
const BUILD_COST_SCALE := 30000.0
const UPKEEP_COST_SCALE := 1000.0

const BASE_TAX_RATE := 0.12


## 경제 시스템의 심장. 인프라 10에서 4000으로 하드캡된다.
static func gdp_pc_anchor(infra: float) -> float:
	var x := (infra - 5.0) * CURVE_K
	var s := 1.0 / (1.0 + exp(-x * 2.2))
	var s0 := 1.0 / (1.0 + exp(5.0 * CURVE_K * 2.2))
	var s1 := 1.0 / (1.0 + exp(-5.0 * CURVE_K * 2.2))
	return GDP_PC_MAX * (s - s0) / (s1 - s0) + GDP_PC_FLOOR


## 건설 우선순위. 낮은 인프라부터 채우면 전국이 평평해져서 어떤 프로빈스도
## 도시 조건(인구가중 평균 + 2)을 넘지 못한다 — 300턴 최고 인프라 6.3, 도시 2.2개.
## 투자한 1원이 낳는 GDP 증가분으로 줄을 세우면 인구가 많고 지형이 좋은 곳이
## 봉우리로 자라고, 이주가 그리로 몰려 도시가 선다.
static func build_yield(p: Province, n: Nation) -> float:
	var gain := (gdp_pc_anchor(p.infra + 1.0) - gdp_pc_anchor(p.infra)) \
		* maxf(p.population, 1.0) * p.terrain_mult
	return gain / maxf(infra_build_cost(p, n), 1.0)


static func infra_build_cost(p: Province, n: Nation) -> float:
	var c := 120.0 * pow(p.infra + 1.0, 2.1)
	c *= p.terrain_cost_mult
	c *= (1.0 + p.distance_from_capital * 0.015)
	c *= n.infra_cost_mult
	return c * BUILD_COST_SCALE


static func infra_upkeep(p: Province, n: Nation) -> float:
	var u := 9.0 * pow(p.infra, 1.55)
	if p.has_city:
		u *= CITY_UPKEEP_MULT
	return u * p.admin_cost_mult * n.law_modifier("admin_cost") * UPKEEP_COST_SCALE


## §2.3 초기값 시딩. 반드시 앵커 아래에서 시작해야 초반에 모든 국가가 성장한다.
static func seed_province(p: Province, rng: RandomNumberGenerator) -> void:
	var pot := p.terrain_mult * (1.25 if p.is_coastal else 1.0) * (1.15 if p.has_river else 1.0)
	p.infra = clampf(rng.randfn(1.8, 0.9) * pot, 0.0, 5.0)
	p.population = p.tiles.size() * rng.randf_range(180.0, 520.0) * pot
	p.gdp_pc = gdp_pc_anchor(p.infra) * rng.randf_range(0.75, 1.0)
	p.gdp = p.gdp_pc * p.population


# ---------------------------------------------------------------- 틱

static func tick_infra(world: WorldState) -> void:
	aggregate(world)
	for n in world.nations:
		if not n.is_alive:
			continue
		_tick_infra_nation(world, n)
		_found_cities(world, n)


static func _tick_infra_nation(world: WorldState, n: Nation) -> void:
	var upkeep_total := 0.0
	for pid in n.provinces:
		upkeep_total += infra_upkeep(world.provinces[pid], n)

	# 국고는 건드리지 않는다. 수입/지출만 기록하고 정산은 7단계 credit.tick() 이 한다 (§1.4).
	var tax_rate := maxf(BASE_TAX_RATE + n.law_modifier("tax_rate"), 0.01)
	# 점령당한 땅에서는 세금이 걷히지 않는다. 전쟁이 재정을 직접 때린다.
	n.income = n.controlled_gdp * tax_rate * n.tax_efficiency

	# 군사비는 파이프라인 7단계(credit) 전에 확정돼야 하므로 여기서 정산한다 (§9.4).
	var military_cost := Military.plan_spending(world, n) + Naval.plan_spending(world, n)

	# 인쇄한 돈으로 메운 유지비는 실질 유지가 안 된 것으로 본다 (§0.3 "화폐 발행 → 인프라 감쇠").
	# 군대는 인프라보다 먼저 먹는다 — 군비 확장이 인프라를 갉아먹어야 붕괴 나선이 성립한다.
	var real_funds := n.treasury + n.income + maxf(Credit.credit_limit(n) - n.debt, 0.0)
	n.upkeep_paid_ratio = clampf((real_funds - military_cost) / maxf(upkeep_total, 1.0), 0.0, 1.0)

	var plan := BudgetAI.infra_plan(n, upkeep_total + military_cost)
	var budget: float = plan["budget"]
	var granted := budget

	var order := n.provinces.duplicate()
	var yields := {}
	for pid in order:
		yields[pid] = build_yield(world.provinces[pid], n)
	order.sort_custom(func(a: int, b: int) -> bool:
		var ya: float = yields[a]
		var yb: float = yields[b]
		if is_equal_approx(ya, yb):
			return a < b
		return ya > yb)

	for pid in order:
		if budget <= 0.0:
			break
		var p: Province = world.provinces[pid]
		if p.infra >= INFRA_MAX:
			continue
		var cost := infra_build_cost(p, n)
		var spend := minf(budget, cost)
		p.infra = minf(INFRA_MAX, p.infra + spend / cost)
		if spend > 0.0:
			n.supply_dirty = true
		budget -= spend

	var spent := granted - budget
	n.expenses = upkeep_total + military_cost + spent  # 못 쓴 예산은 지출이 아니다
	var cash_budget: float = granted - float(plan["borrowing"])
	n.planned_borrowing = minf(float(plan["borrowing"]), maxf(spent - cash_budget, 0.0))

	for pid in n.provinces:
		var before := world.provinces[pid].infra
		tick_infra_decay(world.provinces[pid], n)
		if not is_equal_approx(before, world.provinces[pid].infra):
			n.supply_dirty = true


## 인프라가 무너질 수 있다는 것이 제국의 화려한 붕괴를 가능하게 한다.
static func tick_infra_decay(p: Province, n: Nation) -> void:
	if n.upkeep_paid_ratio < 1.0:
		p.infra = maxf(0.0, p.infra - (1.0 - n.upkeep_paid_ratio) * DECAY_PER_UNPAID)
	if p.is_being_pillaged:
		p.infra = maxf(0.0, p.infra - PILLAGE_DECAY)


static func tick_production(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		for pid in n.provinces:
			_tick_production_province(world.provinces[pid], n)
	aggregate(world)


static func _tick_production_province(p: Province, n: Nation) -> void:
	var anchor := gdp_pc_anchor(p.infra)
	anchor *= p.terrain_mult
	anchor *= n.law_modifier("productivity")
	anchor *= (1.0 - p.unrest * 0.6)
	if p.has_city:
		anchor *= CITY_ANCHOR_BONUS

	var gap := anchor - p.gdp_pc
	p.gdp_pc += gap * (GROWTH_RATE if gap > 0.0 else DECLINE_RATE)
	p.gdp = p.gdp_pc * p.population


## 인프라가 직접 인구를 끌어오지 않는다. 인프라 → 소득 → 이주 순서다.
static func tick_migration(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		if n.provinces.is_empty():
			continue
		var mean_pc := n.gdp / maxf(n.population, 1.0)
		var mean_density := n.population / maxf(_national_tiles(world, n), 1.0)

		for pid in n.provinces:
			var p: Province = world.provinces[pid]
			p.pop_density_ratio = (p.population / maxf(p.tiles.size(), 1)) / maxf(mean_density, 0.0001)
			var pull := (p.gdp_pc / maxf(mean_pc, 1.0)) - 1.0
			pull -= p.unrest * UNREST_PULL
			pull -= maxf(p.pop_density_ratio - 1.0, 0.0) * DENSITY_PENALTY
			p.pending_migration = p.population * clampf(pull, -MIGRATION_CAP, MIGRATION_CAP) * MIGRATION_SCALE
		_rebalance(world, n)


## 유출 총량 = 유입 총량. 없으면 인구가 무에서 생성되어 GDP 가 결국 폭주한다.
static func _rebalance(world: WorldState, n: Nation) -> void:
	var inflow := 0.0
	var outflow := 0.0
	for pid in n.provinces:
		var m: float = world.provinces[pid].pending_migration
		if m > 0.0:
			inflow += m
		else:
			outflow -= m

	var common := minf(inflow, outflow)
	var in_scale := common / inflow if inflow > 0.0 else 0.0
	var out_scale := common / outflow if outflow > 0.0 else 0.0

	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		var m := p.pending_migration
		p.population = maxf(0.0, p.population + (m * in_scale if m > 0.0 else m * out_scale))
		p.pending_migration = 0.0
		p.gdp = p.gdp_pc * p.population


static func _national_tiles(world: WorldState, n: Nation) -> float:
	var t := 0.0
	for pid in n.provinces:
		t += world.provinces[pid].tiles.size()
	return t


# ---------------------------------------------------------------- 도시

static func _found_cities(world: WorldState, n: Nation) -> void:
	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		if can_found_city(world, p, n):
			p.has_city = true
			n.supply_dirty = true
			world.log_event("city_founded", {"nation": n.id, "province": p.id})


static func can_found_city(world: WorldState, p: Province, n: Nation) -> bool:
	return not p.has_city \
		and p.infra >= n.infra_mean + CITY_RELATIVE_BONUS \
		and p.infra >= CITY_ABSOLUTE_MIN \
		and p.population >= CITY_MIN_POP \
		and nearest_city_distance(world, p, n) >= CITY_MIN_SPACING


## 프로빈스 인접 홉 수. CITY_MIN_SPACING 밖은 더 볼 필요가 없어 거기서 끊는다.
static func nearest_city_distance(world: WorldState, p: Province, n: Nation) -> int:
	var seen: Dictionary = {p.id: true}
	var queue: Array[int] = [p.id]
	var depth: Array[int] = [0]
	var head := 0
	while head < queue.size():
		var cur: int = queue[head]
		var d: int = depth[head]
		head += 1
		if world.provinces[cur].has_city:
			return d
		if d >= CITY_MIN_SPACING:
			continue
		for nb: int in world.provinces[cur].land_neighbors:
			if seen.has(nb) or world.provinces[nb].owner_nation != n.id:
				continue
			seen[nb] = true
			queue.append(nb)
			depth.append(d + 1)
	return CITY_MIN_SPACING


# ---------------------------------------------------------------- 집계

## 평균 인프라는 반드시 인구 가중 평균 (§4.7 정복 익스플로잇 방지).
static func aggregate(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		var pop := 0.0
		var gdp := 0.0
		var controlled := 0.0
		var infra_weighted := 0.0
		var unrest_weighted := 0.0
		var weight := 0.0
		for pid in n.provinces:
			var p: Province = world.provinces[pid]
			pop += p.population
			gdp += p.gdp
			if p.occupied_by_nation < 0:
				controlled += p.gdp
			var w := maxf(p.population, 1.0)
			infra_weighted += p.infra * w
			unrest_weighted += p.unrest * w
			weight += w
		n.population = pop
		n.gdp = gdp
		n.nominal_gdp = gdp
		n.controlled_gdp = controlled
		n.infra_mean = infra_weighted / maxf(weight, 1.0)
		n.avg_unrest = unrest_weighted / maxf(weight, 1.0)
