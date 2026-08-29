class_name EmpireSystem extends RefCounted

## 직할령 통합, 행정 한계, 제국 권위와 속국 충성도를 한 수명 주기로 묶는다.
## 확장 자체는 가능하게 두되, 과잉확장 상태에서 패전·파산이 나면 변경과 속국이
## 함께 흔들리도록 하는 것이 목적이다.

const TRIBUTE_SHARE := 0.10
const VASSAL_ADMIN_SHARE := 0.25
const VASSAL_START_LOYALTY := 0.62         # 형성기에는 첫 후속 원정을 도울 수 있다
const OFFENSIVE_JOIN_LOYALTY := 0.60
const SECESSION_LOYALTY := 0.20
const VASSAL_COHESION_COST := 0.004        # 셋째 속국부터 제국권 결속이 빠르게 어려워진다
const AUTHORITY_CRISIS := 0.30
const AUTHORITY_STRONG := 0.65

const INTEGRATION_RATE := 0.020
const OVEREXTENSION_UNREST_MAX := 0.018
## p.culture 는 어디서도 바뀌지 않았다. 그래서 통합이 끝난 정복지도
## culture_distance 가 남아 Unrest 의 완화(0.80)를 뚫고 잔여 압력이 계속 쌓였고,
## 대제국은 결국 문화 경계에서 갈라졌다. 통합 완료 뒤 다시 100턴을 조용히
## 지나면 동화한다. 난수를 쓰지 않는다 (§15).
const ASSIMILATION_RATE := 0.010
const ASSIMILATION_MAX_UNREST := 0.35

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
		var amount := maxf(v.income, 0.0) * TRIBUTE_SHARE
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
		if not n.is_alive or p.controller() != n.id or p.unrest >= 0.70:
			continue
		if p.integration < 1.0:
			var culture_factor := maxf(0.25, 1.0 - p.culture_distance(n.culture) * 0.60)
			var supply_factor := 0.5 + p.supply * 0.5
			var garrison_factor := 1.0 + p.garrison_ratio * 0.5
			p.integration = minf(1.0, p.integration
				+ INTEGRATION_RATE * culture_factor * supply_factor * garrison_factor)
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


static func _recompute_administration(world: WorldState, n: Nation) -> void:
	var load := 0.0
	var foreign := 0
	for pid in n.provinces:
		var p: Province = world.provinces[pid]
		if p.culture_distance(n.culture) > 0.0:
			foreign += 1
		load += 1.0
		load += minf(p.distance_from_capital, 10.0) * 0.06
		load += p.culture_distance(n.culture) * 0.50
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
	var capacity := (6.0 + capital_infra * 1.5 + political * 4.0) \
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
	delta -= maxf(overlord.vassals.size() - 1, 0) * VASSAL_COHESION_COST
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


static func on_peace(world: WorldState, winner: Nation, loser: Nation, goal: int) -> void:
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


static func realm_share(world: WorldState, n: Nation) -> float:
	var world_value := 0.0
	for p in world.provinces:
		world_value += p.gdp * (2.0 if p.has_city else 1.0)
	return realm_value(world, n) / maxf(world_value, 1.0)
