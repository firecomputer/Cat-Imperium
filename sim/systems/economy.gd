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

const CITY_ABSOLUTE_MIN := 4.0
## 봉우리 조건 위에 얹는 얇은 가산점. 예전 +2.0 은 인프라가 성숙하면 평균이 함께
## 올라와 영영 못 넘는 바가 됐지만, 지리 상한이 생긴 뒤로는 큰 나라의 최고점과
## 인구가중 평균의 간격이 1.8~2.4 로 안정되므로 이 폭은 계속 넘을 수 있다.
const CITY_RELATIVE_BONUS := 1.0
const CITY_MIN_POP := 5000.0
const CITY_MIN_SPACING := 3
const CITY_ANCHOR_BONUS := 1.2
const CITY_UPKEEP_MULT := 3.0

## 지리가 준 상한(Province.infra_cap) 위로도 지을 수는 있다. 다만 1 넘길 때마다
## 건설비가 이만큼 곱해진다 — 하드캡이면 상한이 낮은 지역이 영구 후진하므로
## 역전 경로를 남긴다 (PHASE2 §M13.9).
const OVER_CAP_COST_BASE := 12.0
## 상한을 넘긴 인프라는 같은 양의 생산성을 내지 못한다. 비용만 비싸고 앵커는
## 예전과 똑같이 오르면 GDP 상승이 다음 건설비를 다시 대는 양의 피드백이 남는다.
const OVER_CAP_PRODUCTIVITY := 0.20

## 건설·유지 비용의 실물 규모. 기존 식은 1타일과 52타일 프로빈스가 같은 돈으로
## 인프라 한 단계를 올렸고, GDP가 커져도 비용은 명목 고정이라 장기적으로 전부
## INFRA_MAX에 붙었다. 면적과 생산비 수준을 비용에 반영해 상대 비용을 유지한다.
const INFRA_REFERENCE_TILES := 18.5
const CONSTRUCTION_GDP_PC_REFERENCE := 600.0
const CONSTRUCTION_PRICE_ELASTICITY := 0.50
const CONSTRUCTION_PRICE_MIN := 0.75
const CONSTRUCTION_PRICE_MAX := 3.0
## 한계 GDP 증가분 / 건설비. 이보다 낮으면 예산이 남아도 짓지 않는다.
## 단순 순위만 매기고 모든 예산을 소진하면 비용을 올려도 포화 시점만 늦어진다.
const MIN_BUILD_RETURN := 0.003

const DECAY_PER_UNPAID := 0.12
const PILLAGE_DECAY := 0.5

## 문서 §4.4 의 비용 계수는 이 프로젝트의 GDP 규모보다 1000배 이상 작다.
## 건설 속도와 지급능력을 독립적으로 검증할 수 있게 단위 배율을 분리한다.
const BUILD_COST_SCALE := 30000.0
const UPKEEP_COST_SCALE := 1000.0

const BASE_TAX_RATE := 0.12
## 교역법(trade_free +0.35 ~ trade_embargo -0.45)의 앵커 배율. 해안 기준 ±0.10~0.14 로
## 생산성 법률(±0.12)과 같은 자릿수에 놓는다. 내륙은 그 30% 만 받는다.
const TRADE_W := 0.3
const TRADE_INLAND_SHARE := 0.3
const TRADE_MULT_MIN := 0.5
## 점령 수취. 점령법의 immediate_income 은 지금까지 LawEvaluator 힌트일 뿐 경제에
## 한 번도 닿지 않았다 — 약탈은 불만만 낳고 돈은 한 푼도 못 벌었는데도 AI 가 그
## 없는 수익을 좇아 프로빈스 5개 이상 국가의 91% 가 약탈을 들었다 (M10.1 §6.3).
## 수취는 아직 통합되지 않은 이문화·피점령 땅에서만 걷힌다. 통합이 끝나면 그 땅은
## 본토가 되어 정상 세수로 넘어가므로, 약탈은 구조적으로 "단기" 수익이다.
const OCCUPATION_EXTRACTION := 0.9


## 곡선의 양 끝점. infra 와 무관한 상수인데 호출마다 exp() 두 번으로 다시 구하고
## 있었다 — gdp_pc_anchor 는 프로빈스마다 여러 번 불린다. const 는 exp() 를 못 접어서
## static var 로 둔다 (클래스 로드 때 한 번 계산된다).
static var _ANCHOR_S0 := 1.0 / (1.0 + exp(5.0 * CURVE_K * 2.2))
static var _ANCHOR_S1 := 1.0 / (1.0 + exp(-5.0 * CURVE_K * 2.2))


## 경제 시스템의 심장. 인프라 10에서 4000으로 하드캡된다.
static func gdp_pc_anchor(infra: float) -> float:
	var x := (infra - 5.0) * CURVE_K
	var s := 1.0 / (1.0 + exp(-x * 2.2))
	return GDP_PC_MAX * (s - _ANCHOR_S0) / (_ANCHOR_S1 - _ANCHOR_S0) + GDP_PC_FLOOR


## 지리 상한까지는 인프라가 온전히 생산성으로 이어지고, 초과분은 20%만 반영된다.
## 낮은 상한 지역도 비싼 역전 경로는 갖되 전 세계가 같은 절대 앵커로 수렴하지 않는다.
static func effective_infra(p: Province, infra: float) -> float:
	if infra <= p.infra_cap:
		return infra
	return p.infra_cap + (infra - p.infra_cap) * OVER_CAP_PRODUCTIVITY


static func _province_anchor_at_infra(p: Province, n: Nation, infra: float) -> float:
	var anchor := gdp_pc_anchor(effective_infra(p, infra))
	anchor *= p.terrain_mult
	anchor *= n.law_modifier("productivity")
	anchor *= trade_mult(p, n)
	anchor *= (1.0 - p.unrest * 0.6)
	if p.has_city:
		anchor *= CITY_ANCHOR_BONUS
	return anchor


## 건설 우선순위. 낮은 인프라부터 채우면 전국이 평평해져서 어떤 프로빈스도
## 도시 조건(인구가중 평균 + 2)을 넘지 못한다 — 300턴 최고 인프라 6.3, 도시 2.2개.
## 투자한 1원이 낳는 GDP 증가분으로 줄을 세우면 인구가 많고 지형이 좋은 곳이
## 봉우리로 자라고, 이주가 그리로 몰려 도시가 선다.
static func build_yield(p: Province, n: Nation) -> float:
	var gain := (_province_anchor_at_infra(p, n, p.infra + 1.0) \
		- _province_anchor_at_infra(p, n, p.infra)) * maxf(p.population, 1.0)
	return gain / maxf(infra_build_cost(p, n), 1.0)


static func _infrastructure_scale(p: Province) -> float:
	var area := clampf(float(p.size()) / INFRA_REFERENCE_TILES, 0.25, 4.0)
	# 현재 불황·불만으로 GDP가 떨어졌다고 도로 자체가 갑자기 싸지지는 않는다.
	# 실제 GDP가 아니라 지리와 인프라가 정한 구조적 생산성으로 생산비를 잡는다.
	var structural_pc := gdp_pc_anchor(effective_infra(p, p.infra))
	var prices := pow(maxf(structural_pc / CONSTRUCTION_GDP_PC_REFERENCE, 0.01),
		CONSTRUCTION_PRICE_ELASTICITY)
	prices = clampf(prices, CONSTRUCTION_PRICE_MIN, CONSTRUCTION_PRICE_MAX)
	return area * prices


static func infra_build_cost(p: Province, n: Nation) -> float:
	var c := 120.0 * pow(p.infra + 1.0, 2.1)
	c *= p.terrain_cost_mult
	c *= (1.0 + p.distance_from_capital * 0.015)
	c *= n.infra_cost_mult
	c *= _infrastructure_scale(p)
	if p.infra > p.infra_cap:
		c *= pow(OVER_CAP_COST_BASE, p.infra - p.infra_cap)
	return c * BUILD_COST_SCALE


## 동화 행정비 배율 (M13.7-a). 동화 성향이 높은 문화는 이문화 프로빈스의 불만과
## 행정 부하를 덜 지는 대신, 그 땅의 유지비를 매 턴 더 낸다.
const ASSIMILATION_UPKEEP_W := 0.50


static func infra_upkeep(p: Province, n: Nation) -> float:
	var u := 9.0 * pow(p.infra, 1.55)
	if p.has_city:
		u *= CITY_UPKEEP_MULT
	u *= 1.0 + p.culture_distance(n.culture) * n.culture_bias("assimilation") \
		* ASSIMILATION_UPKEEP_W
	return u * _infrastructure_scale(p) * p.admin_cost_mult \
		* n.law_modifier("admin_cost") * UPKEEP_COST_SCALE


## §2.3 초기값 시딩. 반드시 앵커 아래에서 시작해야 초반에 모든 국가가 성장한다.
static func seed_province(p: Province, rng: RandomNumberGenerator) -> void:
	var pot := p.terrain_mult * (1.25 if p.is_coastal else 1.0) * (1.15 if p.has_river else 1.0)
	p.infra = clampf(rng.randfn(1.8, 0.9) * pot, 0.0, minf(5.0, p.infra_cap))
	p.population = p.tiles.size() * rng.randf_range(180.0, 520.0) * pot
	p.gdp_pc = gdp_pc_anchor(p.infra) * rng.randf_range(0.75, 1.0)
	p.gdp = p.gdp_pc * p.population
	p.anchor_gdp_pc = gdp_pc_anchor(p.infra)


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
	n.income += occupation_extraction(n) * n.tax_efficiency

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
	# is_equal_approx 는 상대 오차라 "a≈b, b≈c, a≉c" 가 성립한다. 비이행적 비교는
	# Godot 의 정렬 검사가 "bad comparison function" 으로 걷어낸다 — 상한 초과 건설비가
	# 수율을 여러 자릿수로 벌려 놓은 뒤 실제로 터졌다. 정확 비교 + id 로 못박는다.
	order.sort_custom(func(a: int, b: int) -> bool:
		var ya: float = yields[a]
		var yb: float = yields[b]
		if ya == yb:
			return a < b
		return ya > yb)

	for pid in order:
		if budget <= 0.0:
			break
		var p: Province = world.provinces[pid]
		if p.infra >= INFRA_MAX:
			continue
		# order는 수익률 내림차순이다. 첫 미달 이후에는 더 볼 필요가 없다.
		if float(yields[pid]) < MIN_BUILD_RETURN:
			break
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


## 점령법이 미통합 정복지에서 추가로 뜯어내는 몫. severity 가 양수면 수취,
## 음수(자치)면 세수를 되돌려주는 비용이다 — 관대함에도 가격이 붙어야 다이얼이
## 아니라 교환이 된다. 밑변은 Unrest 의 점령 항과 정확히 같다 (Province.occupation_base).
static func occupation_extraction(n: Nation) -> float:
	return n.occupation_gdp * n.occupation_law_severity() \
		* OCCUPATION_EXTRACTION * BASE_TAX_RATE


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


## 이 프로빈스의 1인당 GDP 수렴 목표. batch_sim 의 앵커 검증도 이 함수를 쓴다 —
## 식이 두 곳에 복제돼 있으면 어느 쪽이 진짜 상한인지 알 수 없게 된다 (M11 §M3).
static func province_anchor(p: Province, n: Nation) -> float:
	return _province_anchor_at_infra(p, n, p.infra)


## 교역법의 생산성 기여. 교역은 바다로 하므로 해안 프로빈스가 이득의 대부분을
## 가져가고 내륙은 일부만 받는다 — 자유무역이 전역 다이얼이 아니라 지리에 따라
## 다른 값이 되게 하는 곳이다 (§5.1).
static func trade_mult(p: Province, n: Nation) -> float:
	var share := 1.0 if p.is_coastal else TRADE_INLAND_SHARE
	return maxf(1.0 + n.law_modifier("trade") * TRADE_W * share, TRADE_MULT_MIN)


static func _tick_production_province(p: Province, n: Nation) -> void:
	var anchor := province_anchor(p, n)
	p.anchor_gdp_pc = anchor
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
		and p.infra >= CITY_ABSOLUTE_MIN \
		and p.infra >= n.infra_mean + CITY_RELATIVE_BONUS \
		and is_local_peak(world, p, n) \
		and p.population >= CITY_MIN_POP \
		and nearest_city_distance(world, p, n) >= CITY_MIN_SPACING


## 도시는 "전국 평균보다 몇 점 위냐"가 아니라 "주변보다 높은가"로 선다. 고정
## 가산점(평균 +2)은 인프라가 성숙하면 평균이 함께 올라와 영영 못 넘는 바가 됐다 —
## 300턴 917프로빈스 중 837개가 이 조건 하나로 탈락했고 도시 수가 얼어붙었다.
static func is_local_peak(world: WorldState, p: Province, n: Nation) -> bool:
	for nb: int in p.land_neighbors:
		var q: Province = world.provinces[nb]
		if q.owner_nation == n.id and q.infra > p.infra:
			return false
	return true


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
		var occupation_gdp := 0.0
		var infra_weighted := 0.0
		var unrest_weighted := 0.0
		var weight := 0.0
		for pid in n.provinces:
			var p: Province = world.provinces[pid]
			pop += p.population
			gdp += p.gdp
			if p.occupied_by_nation < 0:
				controlled += p.gdp
				occupation_gdp += p.gdp * p.occupation_base(n.culture)
			var w := maxf(p.population, 1.0)
			infra_weighted += p.infra * w
			unrest_weighted += p.unrest * w
			weight += w
		n.population = pop
		n.gdp = gdp
		n.nominal_gdp = gdp
		n.controlled_gdp = controlled
		n.occupation_gdp = occupation_gdp
		n.infra_mean = infra_weighted / maxf(weight, 1.0)
		n.avg_unrest = unrest_weighted / maxf(weight, 1.0)
