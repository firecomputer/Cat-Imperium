class_name EmpireSystem extends RefCounted

## 직할령 통합, 행정 한계, 제국 권위와 속국 충성도를 한 수명 주기로 묶는다.
## 확장 자체는 가능하게 두되, 과잉확장 상태에서 패전·파산이 나면 변경과 속국이
## 함께 흔들리도록 하는 것이 목적이다.

const TRIBUTE_SHARE := 0.10
## 공납이 정액이면 속국은 행정부하만큼의 값을 못 한다. 충성도에 걸어 두면
## 권위를 지킨 종주국일수록 다음 원정을 스스로 벌 수 있다 (§P3).
const TRIBUTE_LOYALTY_SPAN := 0.6          # 실효 공납 = 소득 × 0.10 × (0.4 ~ 1.0)
const VASSAL_ADMIN_SHARE := 0.25
const VASSAL_START_LOYALTY := 0.62         # 형성기에는 첫 후속 원정을 도울 수 있다
const OFFENSIVE_JOIN_LOYALTY := 0.60
const SECESSION_LOYALTY := 0.20
## 속국 수용력 (§P2). 예전에는 "셋째 속국부터" 라는 상수였고, 그래서 세 번째
## 속국은 통치와 무관하게 이탈 타이머였다 (0.62 → 0.20 까지 약 52턴).
## 실측 admin_load/capacity 중앙값이 0.40 이라 행정 여유는 아무 데도 안 쓰이고
## 놀고 있었다 — 그 여유와 권위가 속국 정원을 벌게 한다.
const VASSAL_CAPACITY_BASE := 1.0
const VASSAL_CAPACITY_AUTHORITY := 3.0
const VASSAL_CAPACITY_HEADROOM := 3.0
const VASSAL_COHESION_COST := 0.010        # 정원을 넘긴 속국 하나당 충성도 감쇠
const AUTHORITY_CRISIS := 0.30
const AUTHORITY_STRONG := 0.65

const INTEGRATION_RATE := 0.020
## 점령법이 통합 속도를 정한다. 이 연결이 없으면 severity 는 불만만 올리는
## 순손실이라 온건 통치에 아무 보상이 없고, 가혹한 통치에도 대가가 없다.
## 약탈(0.9)은 통합을 사실상 멈추고 자치(-0.6)·동화(0.1)는 앞당긴다 —
## 약탈로 번 돈의 값은 그 땅이 영영 본토가 되지 못한다는 것이다.
const OCCUPATION_INTEGRATION_W := 0.95
const OCCUPATION_INTEGRATION_MIN := 0.15
const OCCUPATION_INTEGRATION_MAX := 1.60
## 불만이 통합을 늦춘다. M10 까지는 0.70 에서 통째로 멈췄는데, 갓 정복한 땅은
## 그 선을 십수 턴 만에 넘고 drift 가 양수라 통합이 영영 재개되지 않았다 —
## 한 방향 래칫이라 새 정복지는 통치와 무관하게 자동으로 반란으로 끝났다
## (실측 할양지의 35%, 평균 21턴). 연속 감속으로 바꿔 주둔과 온건한 점령법이
## 이 구간을 되살릴 수 있게 한다. 0 으로 떨어뜨리지 않는 것이 핵심이다.
const UNREST_INTEGRATION_FLOOR := 0.20
## 분리주의가 1.0 이어도 통합이 완전히 멈추지는 않는다. 0 이면 한 번 크게 진압당한
## 땅은 영원히 편입되지 않아 붕괴가 확정 경로가 된다 (M14 §1).
const SEPARATISM_INTEGRATION_FLOOR := 0.15
const OVEREXTENSION_UNREST_MAX := 0.018
const CAPACITY_PER_CORE := 0.45            # 통합 완료 프로빈스가 돌려주는 행정 여력 (§P3)
## p.culture 는 어디서도 바뀌지 않았다. 그래서 통합이 끝난 정복지도
## culture_distance 가 남아 Unrest 의 완화(0.80)를 뚫고 잔여 압력이 계속 쌓였고,
## 대제국은 결국 문화 경계에서 갈라졌다. 통합 완료 뒤 다시 100턴을 조용히
## 지나면 동화한다. 난수를 쓰지 않는다 (§15).
const ASSIMILATION_RATE := 0.010
const ASSIMILATION_MAX_UNREST := 0.35
## 문화의 동화 성향이 이문화 프로빈스 행정 부하를 깎는 폭 (M13.7-a).
## 대가는 Economy.infra_upkeep 의 동화 행정비다 — 순수 이득 방향은 없다 (§5.5).
const ASSIMILATION_ADMIN_RELIEF := 0.40

const AUTHORITY_CONQUEST_WIN := 0.08
const AUTHORITY_SUBJUGATION_WIN := 0.15
const AUTHORITY_WAR_LOSS := -0.10
const AUTHORITY_DEFAULT := -0.25


static func initialize(world: WorldState) -> void:
	for n in world.nations:
		if n.is_alive:
			_recompute_administration(world, n)


## 세수 산정 뒤, 신용 정산 전에 공납을 양쪽 income 에 반영한다.
static func collect_tribute(world: WorldState) -> void:
	for v in world.nations:
		if not v.is_alive or v.overlord < 0 or v.overlord >= world.nations.size():
			continue
		var overlord: Nation = world.nations[v.overlord]
		if not overlord.is_alive:
			continue
		# 재정이 무너진 속국은 공납을 면제받는다 — 공납이 파산을 앞당기면
		# 종주국은 다음 원정을 벌 재원 대신 이탈할 잔해를 얻는다.
		if v.bankruptcy_timer > 0 or v.income - v.expenses < 0.0:
			continue
		var amount := maxf(v.income, 0.0) * TRIBUTE_SHARE \
			* (0.4 + v.vassal_loyalty * TRIBUTE_LOYALTY_SPAN)
		v.income -= amount
		overlord.income += amount
		if amount > 0.0 and world.turn % 12 == v.id % 12:
			world.log_event("tribute_paid", {
				"nation": overlord.id,
				"vassal": v.id,
				"amount": amount,
			})


static func tick(world: WorldState) -> void:
	_tick_integration(world)
	for n in world.nations:
		if n.is_alive:
			_recompute_administration(world, n)
	for n in world.nations:
		if n.is_alive and n.overlord < 0:
			_tick_authority(world, n)

	var secessions: Array[int] = []
	for v in world.nations:
		if not v.is_alive or v.overlord < 0:
			continue
		_tick_loyalty(world, v)
		if v.vassal_loyalty < SECESSION_LOYALTY and not v.at_war:
			var overlord: Nation = world.nations[v.overlord]
			if overlord.is_alive and not overlord.at_war:
				secessions.append(v.id)
	for vassal_id in secessions:
		_start_independence_war(world, world.nations[vassal_id])


static func _tick_integration(world: WorldState) -> void:
	for p in world.provinces:
		if p.owner_nation < 0:
			continue
		var n: Nation = world.nations[p.owner_nation]
		if not n.is_alive or p.controller() != n.id:
			continue
		if p.integration < 1.0:
			var culture_factor := maxf(0.25, 1.0 - p.culture_distance(n.culture) * 0.60)
			var supply_factor := 0.5 + p.supply * 0.5
			# 주둔은 이제 통합 속도를 최대 두 배로 만든다. 병력을 눌러 앉히는 것이
			# 불만을 깎는 임시방편(-0.04/턴)에 그치지 않고 통합 자체를 앞당겨야
			# 세 레버(점령법·통합·주둔)가 한 경주 위에서 맞물린다.
			var garrison_factor := 1.0 + p.garrison_ratio
			var unrest_factor := maxf(UNREST_INTEGRATION_FLOOR, 1.0 - p.unrest)
			# 군대로 눌린 기억이 남아 있는 동안은 행정이 앞으로 나가지 않는다.
			var separatism_factor := maxf(1.0 - p.separatism, SEPARATISM_INTEGRATION_FLOOR)
			p.integration = minf(1.0, p.integration + INTEGRATION_RATE
				* culture_factor * supply_factor * garrison_factor * unrest_factor
				* separatism_factor * occupation_integration_factor(n))
			continue
		_tick_assimilation(world, p, n)


## 통합이 끝난 뒤에도 조용한 상태가 이어져야 문화가 바뀐다. 전시 점령이나
## 불만 급등은 진행을 되돌린다 — 한 번 시작하면 끝나는 타이머가 아니다.
static func _tick_assimilation(world: WorldState, p: Province, n: Nation) -> void:
	if p.culture == n.culture:
		p.assimilation = 0.0
		return
	if p.unrest >= ASSIMILATION_MAX_UNREST:
		p.assimilation = maxf(0.0, p.assimilation - ASSIMILATION_RATE)
		return
	p.assimilation += ASSIMILATION_RATE
	if p.assimilation < 1.0:
		return
	var former := p.culture
	p.culture = n.culture
	p.assimilation = 0.0
	world.log_event("province_assimilated", {
		"nation": n.id,
		"province": p.id,
		"from_culture": former,
		"culture": n.culture,
	})


## severity 를 통합 속도 배율로 옮긴다. 관대할수록 빠르다.
static func occupation_integration_factor(n: Nation) -> float:
	return clampf(1.0 - n.occupation_law_severity() * OCCUPATION_INTEGRATION_W,
		OCCUPATION_INTEGRATION_MIN, OCCUPATION_INTEGRATION_MAX)


static func _recompute_administration(world: WorldState, n: Nation) -> void:
	var load := 0.0
	var foreign := 0
	var core := 0
	var culture_load := 0.50 * (1.0 - n.culture_bias("assimilation") * ASSIMILATION_ADMIN_RELIEF)
	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		if p.culture_distance(n.culture) > 0.0:
			foreign += 1
		if p.integration >= 1.0:
			core += 1
		load += 1.0
		load += minf(p.distance_from_capital, 10.0) * 0.06
		load += p.culture_distance(n.culture) * culture_load
		load += (1.0 - p.integration) * 0.75
		if p.is_exclave:
			load += 0.75
	for vassal_id in n.vassals:
		if vassal_id < 0 or vassal_id >= world.nations.size():
			continue
		var v: Nation = world.nations[vassal_id]
		if v.is_alive and v.overlord == n.id:
			load += v.provinces.size() * VASSAL_ADMIN_SHARE

	var capital_infra := 0.0
	if n.capital >= 0 and n.capital < world.provinces.size():
		capital_infra = world.provinces[n.capital].infra
	var political := clampf(n.unrest_suppression / 0.35, 0.0, 1.0)
	var law_factor := clampf(1.0 / maxf(n.law_modifier("admin_cost"), 0.2), 0.75, 1.25)
	var authority_factor := 0.75 + n.imperial_authority * 0.50
	# 통합이 끝난 본토는 부하이면서 동시에 통치 기반이다 (§P3). 이 항이 없으면
	# 프로빈스 하나를 먹을 때마다 load 만 늘고 capacity 는 그대로라 확장의
	# 한계수익이 0 근처에 붙는다. 프로빈스당 부하(약 1.3)보다 작게 돌려준다 —
	# 확장은 여전히 체감하지만 천장이 상수는 아니게 된다.
	var capacity := (6.0 + capital_infra * 1.5 + political * 4.0 + core * CAPACITY_PER_CORE) \
		* law_factor * authority_factor
	n.foreign_exposure = float(foreign) / maxf(float(n.provinces.size()), 1.0)
	n.admin_load = load
	n.admin_capacity = maxf(capacity, 1.0)
	n.overextension = maxf(load / n.admin_capacity - 1.0, 0.0)


static func _tick_authority(world: WorldState, n: Nation) -> void:
	var balance := n.income - n.expenses - n.interest_expense
	var delta := 0.0
	if balance > 0.0 and n.avg_unrest < 0.25:
		delta += 0.002
	elif balance < 0.0:
		delta -= 0.0015
	delta -= minf(n.overextension, 2.0) * 0.006
	delta -= maxf(n.avg_unrest - 0.35, 0.0) * 0.010
	if n.vassals.is_empty() and n.overextension <= 0.0:
		var recovered := move_toward(n.imperial_authority, 0.5, 0.002)
		delta += recovered - n.imperial_authority
	_adjust_authority(world, n, delta, "realm_drift", false)


## 속국을 몇이나 붙들 수 있는가. 권위와 행정 여유가 정원을 번다 (§P2).
static func vassal_capacity(n: Nation) -> float:
	var headroom := clampf(1.0 - n.admin_load / maxf(n.admin_capacity, 1.0), 0.0, 1.0)
	return VASSAL_CAPACITY_BASE + n.imperial_authority * VASSAL_CAPACITY_AUTHORITY \
		+ headroom * VASSAL_CAPACITY_HEADROOM


static func _tick_loyalty(world: WorldState, v: Nation) -> void:
	if v.overlord < 0 or v.overlord >= world.nations.size():
		return
	var overlord: Nation = world.nations[v.overlord]
	if not overlord.is_alive:
		release_vassal(world, v, "overlord_dead")
		return
	var ratio := Diplomacy.power(world, overlord) / maxf(Diplomacy.power(world, v), 1.0)
	var delta := (overlord.imperial_authority - 0.5) * 0.010
	delta += clampf((ratio - 1.0) * 0.0015, -0.003, 0.003)
	delta -= Culture.distance(v.culture, overlord.culture) * 0.002
	delta -= overlord.overextension * 0.003
	delta -= maxf(float(overlord.vassals.size()) - vassal_capacity(overlord), 0.0) \
		* VASSAL_COHESION_COST
	if overlord.bankruptcy_timer > 0:
		delta -= 0.020
	v.vassal_loyalty = clampf(v.vassal_loyalty + delta, 0.0, 1.0)
	if v.vassal_loyalty < 0.30 and world.turn % 12 == v.id % 12:
		world.log_event("vassal_loyalty_crisis", {
			"nation": overlord.id,
			"vassal": v.id,
			"loyalty": v.vassal_loyalty,
		})


static func unrest_pressure(p: Province, n: Nation) -> float:
	if n.overextension <= 0.0:
		return 0.0
	var periphery := 0.35 + (1.0 - p.integration) * 0.65
	if p.is_exclave:
		periphery += 0.25
	return minf(OVEREXTENSION_UNREST_MAX,
		n.overextension * 0.010 * periphery)


static func vassalize(world: WorldState, overlord: Nation, vassal: Nation,
		reward_authority: bool = true) -> bool:
	if not overlord.is_alive or not vassal.is_alive or overlord.id == vassal.id:
		return false
	if overlord.overlord >= 0:
		return false
	# 종주국을 복속하면 그 속국들은 새 승자의 직속으로 승계한다. 중첩 속국은 없다.
	for inherited_id in vassal.vassals.duplicate():
		if inherited_id < 0 or inherited_id >= world.nations.size():
			continue
		var inherited: Nation = world.nations[inherited_id]
		release_vassal(world, inherited, "realm_transfer")
		if inherited.is_alive:
			vassalize(world, overlord, inherited, false)
	if vassal.overlord >= 0:
		release_vassal(world, vassal, "new_overlord")
	for ally_id in vassal.allies.duplicate():
		if ally_id >= 0 and ally_id < world.nations.size():
			world.nations[ally_id].allies.erase(vassal.id)
			world.nations[ally_id].alliance_expiry.erase(vassal.id)
	vassal.allies.clear()
	vassal.alliance_expiry.clear()
	vassal.overlord = overlord.id
	vassal.vassal_loyalty = VASSAL_START_LOYALTY
	vassal.vassal_since_turn = world.turn
	if not overlord.vassals.has(vassal.id):
		overlord.vassals.append(vassal.id)
		overlord.vassals.sort()
	if reward_authority:
		_adjust_authority(world, overlord, AUTHORITY_SUBJUGATION_WIN, "subjugation", true)
	world.log_event("vassalized", {
		"nation": overlord.id,
		"vassal": vassal.id,
		"loyalty": vassal.vassal_loyalty,
	})
	return true


static func release_vassal(world: WorldState, vassal: Nation, reason: String) -> void:
	if vassal.overlord < 0:
		return
	var former := vassal.overlord
	if former < world.nations.size():
		world.nations[former].vassals.erase(vassal.id)
	vassal.overlord = -1
	vassal.vassal_since_turn = -1
	vassal.vassal_loyalty = 0.45
	world.log_event("vassal_released", {
		"nation": former,
		"vassal": vassal.id,
		"reason": reason,
	})


static func _start_independence_war(world: WorldState, vassal: Nation) -> void:
	var overlord_id := vassal.overlord
	if overlord_id < 0 or overlord_id >= world.nations.size():
		return
	var overlord: Nation = world.nations[overlord_id]
	release_vassal(world, vassal, "independence_war")
	var war := Diplomacy.declare_war(world, vassal, overlord, "independence",
		War.Goal.INDEPENDENCE)
	war.goal_score = Peace.ACCEPT_SCORE
	call_vassals_to_war(world, war, overlord, -1, false, vassal.id)
	world.log_event("independence_war", {
		"nation": vassal.id,
		"overlord": overlord.id,
		"war": war.id,
	})


static func call_vassals_to_war(world: WorldState, war: War, overlord: Nation,
		side: int, offensive: bool, exclude: int = -1) -> void:
	for vassal_id in overlord.vassals:
		if vassal_id == exclude or vassal_id < 0 or vassal_id >= world.nations.size():
			continue
		var v: Nation = world.nations[vassal_id]
		if not v.is_alive or v.overlord != overlord.id or war.side_of(v.id) != 0:
			continue
		if offensive and v.vassal_loyalty < OFFENSIVE_JOIN_LOYALTY:
			_adjust_authority(world, overlord, -0.01, "vassal_refused", false)
			continue
		Diplomacy.join_war(world, war, v, side,
			"offensive_vassal" if offensive else "defensive_vassal")


## 승전 시 전쟁 지지도. 반란 진압 승리는 여기를 지나지 않는다 — 진압이 전쟁 수행
## 능력을 되돌려주면 제국이 무너지는 경로가 다시 막힌다 (M14 §4).
const WAR_SUPPORT_VICTORY := 0.10


static func on_peace(world: WorldState, winner: Nation, loser: Nation, goal: int) -> void:
	winner.war_support = minf(winner.war_support + WAR_SUPPORT_VICTORY, 1.0)
	if goal == War.Goal.SUBJUGATION:
		# vassalize()가 승자 권위를 이미 올린다.
		_adjust_authority(world, loser, AUTHORITY_WAR_LOSS, "war_lost", true)
		return
	if goal == War.Goal.INDEPENDENCE:
		_adjust_authority(world, winner, AUTHORITY_CONQUEST_WIN, "independence_won", true)
		_adjust_authority(world, loser, AUTHORITY_WAR_LOSS, "war_lost", true)
		return
	_adjust_authority(world, winner, AUTHORITY_CONQUEST_WIN, "war_won", true)
	_adjust_authority(world, loser, AUTHORITY_WAR_LOSS, "war_lost", true)


static func on_default(world: WorldState, n: Nation) -> void:
	_adjust_authority(world, n, AUTHORITY_DEFAULT, "default", true)


static func on_nation_death(world: WorldState, n: Nation) -> void:
	if n.overlord >= 0:
		release_vassal(world, n, "vassal_dead")
	for vassal_id in n.vassals.duplicate():
		if vassal_id >= 0 and vassal_id < world.nations.size():
			release_vassal(world, world.nations[vassal_id], "overlord_dead")
	n.vassals.clear()


static func _adjust_authority(world: WorldState, n: Nation, delta: float,
		reason: String, force_log: bool) -> void:
	if not n.is_alive or delta == 0.0:
		return
	var before := n.imperial_authority
	n.imperial_authority = clampf(before + delta, 0.0, 1.0)
	var band := 0 if n.imperial_authority < AUTHORITY_CRISIS \
		else (2 if n.imperial_authority >= AUTHORITY_STRONG else 1)
	if force_log or band != n.authority_band:
		world.log_event("imperial_authority_changed", {
			"nation": n.id,
			"before": before,
			"authority": n.imperial_authority,
			"reason": reason,
		})
	n.authority_band = band


static func realm_root(world: WorldState, nation_id: int) -> int:
	if nation_id < 0 or nation_id >= world.nations.size():
		return nation_id
	var n: Nation = world.nations[nation_id]
	if n.overlord >= 0 and n.overlord < world.nations.size() \
			and world.nations[n.overlord].is_alive:
		return n.overlord
	return nation_id


static func realm_value(world: WorldState, n: Nation) -> float:
	var root_id := realm_root(world, n.id)
	var total := 0.0
	for member in world.nations:
		if not member.is_alive or realm_root(world, member.id) != root_id:
			continue
		for pid in member.provinces:
			var p: Province = world.provinces[pid]
			total += p.gdp * (2.0 if p.has_city else 1.0)
	return total


static func realm_province_count(world: WorldState, n: Nation) -> int:
	var root_id := realm_root(world, n.id)
	var total := 0
	for member in world.nations:
		if member.is_alive and realm_root(world, member.id) == root_id:
			total += member.provinces.size()
	return total


## 제국 판정 문턱 (배치 계측용). 0.12 는 40국 세계에서 "평균국의 4.8배" 라는 뜻이었다.
## 국가 수가 지도 크기를 따라가므로(NationPlacer.nation_count) 그 배율을 보존한다 —
## 절대값으로 두면 큰 지도일수록 제국 정의만 저절로 가혹해진다 (지구 115국에서 13.8배).
const EMPIRE_THRESHOLD_BASE := 0.12
const EMPIRE_THRESHOLD_BASE_NATIONS := 40.0


static func empire_threshold(world: WorldState) -> float:
	return EMPIRE_THRESHOLD_BASE * EMPIRE_THRESHOLD_BASE_NATIONS \
		/ maxf(float(world.initial_nation_count), 1.0)


static func realm_share(world: WorldState, n: Nation) -> float:
	var world_value := 0.0
	for p in world.provinces:
		world_value += p.gdp * (2.0 if p.has_city else 1.0)
	return realm_value(world, n) / maxf(world_value, 1.0)
