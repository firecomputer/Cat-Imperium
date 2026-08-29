class_name Peace extends RefCounted

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## 전쟁 점수와 강화 (§12). 전쟁은 전멸이 아니라 협상으로 끝난다.
## 조항의 총 비용이 warscore 를 넘을 수 없다 — 이긴 만큼만 뜯는다.

const MIN_WAR_TURNS := 12
const ACCEPT_SCORE := 35.0                # 이 점수를 넘으면 패자가 협상에 응한다
const EXHAUSTION_TURNS := 45              # 이만큼 끌면 양쪽 다 백지평화로 손 턴다
const SUBJUGATION_SCORE := 35.0
const SUBJUGATION_EXHAUSTION_TURNS := 45
const PARTIAL_PEACE_SCORE := 20.0

## 반란전 전용 (M8.5 §3~§5). 일반전 상수를 쓰지 않는다 — 전쟁 목적이 다르다.
## 정부는 군사적 우세로 빠르게 끝낼 수 있고(warscore), 반란군은 영토를
## 계속 지켜야만 독립한다(recognition). 두 승리 조건의 역할을 분리한다.
## 계획서 초기값은 65 였다. 이 세계의 반란국은 origin 프로빈스가 평균 1.5 개라
## 65 에서는 territory(55×비율) + capital(20) 조합이 거의 만들어지지 않아 §3 경로가
## 한 번도 발동하지 않았다 (전부 전멸 판정). 50 으로 내리면 절반 탈환 + 전투 우위로
## 도달할 수 있어 "전 영토 점령 없이 진압" 이 실제로 일어난다.
const REBEL_PARENT_VICTORY_SCORE := 50.0
const REBEL_TERRITORY_SCORE := 55.0
const REBEL_BATTLE_SCORE := 25.0
const REBEL_CAPITAL_SCORE := 20.0
const REBEL_RECOGNITION_TARGET := 100.0
const RECOGNITION_CONTROL_GAIN := 1.2
const RECOGNITION_CAPITAL_GAIN := 0.35
## 영토를 잃으면 인정도는 정체하거나 줄어든다. 시간만 버텨서는 독립할 수 없다.
const RECOGNITION_LOSING_RATIO := 0.30
const RECOGNITION_LOSING_PENALTY := 1.25
const RECOGNITION_COLLAPSE_RATIO := 0.05
const RECOGNITION_COLLAPSE_PENALTY := 2.0
## 교착 감시용. 강제 종료는 두지 않는다 — 그것은 60턴 타이머를 이름만 바꾼 것이다.
const REBEL_WAR_AGE_MARKS := [100, 150, 200]

const OCCUPATION_WEIGHT := 70.0
const BATTLE_WEIGHT := 1.5
const BATTLE_CAP := 20.0
const WEARINESS_WEIGHT := 15.0
const SUBJUGATION_CAPITAL_SCORE := 15.0   # 수도 장악은 복속 의지를 크게 꺾는다
## SUBJUGATION 전쟁은 35 만 넘으면 땅을 한 뼘도 안 뺏고 속국화로 끝났다 —
## warscore 100 이어도 같았다. 압승은 영토를 먹고, 남은 예산으로 잔존국을
## 속국으로 삼는다 (아래 병합 분기의 rump_vassal).
const ANNEX_OVER_VASSAL_SCORE := 70.0

## 조항 비용 (§12.2). 순수 이득 조항은 없다 — 영토는 행정비를, 배상금은 인플레를 남긴다.
## 설계서 §12.2.1. 조약 수확은 대제국의 다이얼이 아니다 — 측정해서 확인했다.
## 20런 실측 (프로빈스 목록 중복 버그를 고친 뒤): 8/35 병합 190 · 최대 영토 15,
## 2/8 병합 701 · 최대 영토 15. 비용을 1/4 로 내려도 손바뀜만 빨라지고
## 아무도 땅을 쌓지 못한다. §12.2 의 "영토 할양 = 비용 높음" 을 유지한다.
const COST_PROVINCE_BASE := 8.0
const COST_PROVINCE_VALUE := 35.0
const COST_INDEMNITY := 20.0
const COST_RUMP_VASSAL := 12.0            # 영토를 잃고 남은 소국의 종속 비용
const INDEMNITY_GDP_SHARE := 0.35
const INDEMNITY_INFLATION := 0.12         # 패자는 배상 때문에 돈을 찍는다
const CEDED_UNREST := 0.15                # 할양지는 충격 뒤 통합 기간을 거친다
const CEDED_GRACE_TURNS := 12
const EXCLAVE_ADMIN_MULT := 2.4           # §12.4
const EXCLAVE_UNREST := 0.0               # 즉시 충격 대신 지속 불만·행정부하가 담당

## 해상 월경지 요구 확률 (§12.3)
const SEA_CLAIM_BASE := 0.12
const SEA_CLAIM_NAVY := 0.35
const SEA_CLAIM_MARITIME := 0.25


static func tick(world: WorldState) -> void:
	for war in world.wars:
		if not war.is_active:
			continue
		update_warscore(world, war)
		_consider_peace(world, war)


# ---------------------------------------------------------------- 전쟁 점수 (§12.1)

static func province_value(p: Province) -> float:
	return p.gdp * (2.0 if p.has_city else 1.0)


static func side_value(world: WorldState, ids: Array[int]) -> float:
	var total := 0.0
	for nid in ids:
		for pid in world.nations[nid].provinces:
			total += province_value(world.provinces[pid])
	return maxf(total, 1.0)


static func update_warscore(world: WorldState, war: War) -> void:
	var attacker_gain := 0.0
	var defender_gain := 0.0
	for p in world.provinces:
		if p.occupied_by_nation < 0:
			continue
		var occupier := war.side_of(p.occupied_by_nation)
		var owner := war.side_of(p.owner_nation)
		if occupier == 0 or owner == 0 or occupier == owner:
			continue
		if occupier > 0:
			attacker_gain += province_value(p)
		else:
			defender_gain += province_value(p)
	war.occupied_value_attacker = attacker_gain
	war.occupied_value_defender = defender_gain

	var score := attacker_gain / side_value(world, war.defenders) * OCCUPATION_WEIGHT
	score -= defender_gain / side_value(world, war.attackers) * OCCUPATION_WEIGHT
	score += clampf(float(war.battles_won - war.battles_lost) * BATTLE_WEIGHT,
		-BATTLE_CAP, BATTLE_CAP)
	score -= (_weariness(world, war.attackers) - _weariness(world, war.defenders)) \
		* WEARINESS_WEIGHT
	if war.goal == War.Goal.SUBJUGATION and war.primary_defender >= 0:
		var target: Nation = world.nations[war.primary_defender]
		if target.capital >= 0 and war.side_of(world.provinces[target.capital].controller()) > 0:
			score += SUBJUGATION_CAPITAL_SCORE
	war.warscore = clampf(score, -100.0, 100.0)


static func _weariness(world: WorldState, ids: Array[int]) -> float:
	var total := 0.0
	for nid in ids:
		total += world.nations[nid].war_weariness
	return total / maxf(ids.size(), 1)


# ---------------------------------------------------------------- 강화

static func _consider_peace(world: WorldState, war: War) -> void:
	var length := world.turn - war.start_turn
	if war.is_rebel_war:
		_tick_rebel_war(world, war, length)
		return
	if length < MIN_WAR_TURNS:
		return

	var attacker_target := war.goal_score if war.goal != War.Goal.CONQUEST else ACCEPT_SCORE
	if war.warscore >= attacker_target or war.warscore <= -ACCEPT_SCORE:
		_settle(world, war, war.warscore > 0.0)
		return
	var exhaustion := SUBJUGATION_EXHAUSTION_TURNS \
		if war.goal == War.Goal.SUBJUGATION else EXHAUSTION_TURNS
	if length >= exhaustion:
		if absf(war.warscore) >= PARTIAL_PEACE_SCORE:
			_settle(world, war, war.warscore > 0.0)
			return
		Diplomacy.end_war(world, war, "white_peace")
		_truce_all(world, war)


# ---------------------------------------------------------------- 반란전 (M8.5 §3~§6)

## 반란전은 일반 평화협상으로 내려가지 않는다. 정부 승리는 warscore 로,
## 반란 승리는 recognition 으로 판정한다.
static func _tick_rebel_war(world: WorldState, war: War, length: int) -> void:
	if length in REBEL_WAR_AGE_MARKS:
		world.log_event("rebel_war_age_%d" % length, {
			"nation": war.parent_nation_id,
			"rebel": war.rebel_nation_id,
			"war": war.id,
			"recognition": war.recognition,
			"parent_warscore": rebel_warscore(world, war),
		})
	# 1. 전멸 — warscore 우회가 아니라 명백한 판정이다.
	if _rebel_origin_ratio(world, war, war.rebel_nation_id) <= 0.0:
		_resolve_rebel_defeat(world, war, "annihilated")
		return
	# 2. 정부군의 군사적 승리
	if rebel_warscore(world, war) >= REBEL_PARENT_VICTORY_SCORE:
		_resolve_rebel_defeat(world, war, "suppressed")
		return
	# 3. 반란국의 독립 인정도
	_tick_rebel_recognition(world, war)
	if war.recognition >= REBEL_RECOGNITION_TARGET:
		_resolve_rebel_independence(world, war)


## -100 ~ +100. 양수는 모국 우세. 각 항을 독립적으로 clamp 한다 (§3.3).
static func rebel_warscore(world: WorldState, war: War) -> float:
	var territory := _rebel_origin_ratio(world, war, war.parent_nation_id) \
		* REBEL_TERRITORY_SCORE
	# 모국은 반란전의 공격 진영이므로 attacker/defender 손실이 곧 parent/rebel 손실이다.
	var losses := war.attacker_losses + war.defender_losses
	var battle := 0.0
	if losses > 0.0:
		battle = clampf((war.defender_losses / losses - 0.5) * 2.0 * REBEL_BATTLE_SCORE,
			-REBEL_BATTLE_SCORE, REBEL_BATTLE_SCORE)
	var capital := REBEL_CAPITAL_SCORE if _controls(world, war.rebel_capital_province,
		war.parent_nation_id) else 0.0
	return clampf(territory + battle + capital, -100.0, 100.0)


## 반란 시작 당시 스냅샷 중 이 국가가 지금 지배하는 비율. 제3국이 가져간 땅은
## 어느 쪽으로도 세지 않는다 (§4.4).
static func _rebel_origin_ratio(world: WorldState, war: War, nation_id: int) -> float:
	var total := war.rebel_origin_provinces.size()
	if total <= 0:
		return 0.0
	var held := 0
	for pid: int in war.rebel_origin_provinces:
		if _controls(world, pid, nation_id):
			held += 1
	return float(held) / float(total)


static func _controls(world: WorldState, pid: int, nation_id: int) -> bool:
	return pid >= 0 and world.provinces[pid].controller() == nation_id


## 시간 자체에는 점수를 주지 않는다 (§5.4). 시간은 통제율을 여러 턴 유지하는
## 행위를 통해서만 반영된다.
static func _tick_rebel_recognition(world: WorldState, war: War) -> void:
	var ratio := _rebel_origin_ratio(world, war, war.rebel_nation_id)
	var gain := ratio * RECOGNITION_CONTROL_GAIN
	if _controls(world, war.rebel_capital_province, war.rebel_nation_id):
		gain += RECOGNITION_CAPITAL_GAIN
	if ratio < RECOGNITION_LOSING_RATIO:
		gain -= RECOGNITION_LOSING_PENALTY
	if ratio <= RECOGNITION_COLLAPSE_RATIO:
		gain -= RECOGNITION_COLLAPSE_PENALTY
	war.recognition = clampf(war.recognition + gain, 0.0, REBEL_RECOGNITION_TARGET)


## 진압 성공. 반란국이 아직 쥔 원영토는 협상 없이 일괄 반환된다 (§4).
## 일반 강화조약의 ACCEPT_SCORE·프로빈스 비용 경로를 타지 않는다.
static func _resolve_rebel_defeat(world: WorldState, war: War, result: String) -> void:
	log_rebel_war_end(world, war, result)
	# 영토 반환보다 먼저 전쟁을 닫는다. 마지막 프로빈스를 돌려받는 순간
	# 반란국이 소멸하면서 kill_nation 이 이 전쟁을 "annihilated" 로 덮어쓴다.
	Diplomacy.end_war(world, war, "rebellion_suppressed")
	var parent: Nation = world.nations[war.parent_nation_id]
	var rebel: Nation = world.nations[war.rebel_nation_id]
	for pid: int in war.rebel_origin_provinces:
		var p: Province = world.provinces[pid]
		# 제3국이 이미 병합한 땅은 순간이동시키지 않는다.
		if p.owner_nation == rebel.id:
			Unrest.reclaim_from_rebel(world, p, rebel, parent)


## 독립 인정. 이후로는 일반 국가다 — 미승인국 상태를 따로 만들지 않는다 (§5.5).
static func _resolve_rebel_independence(world: WorldState, war: War) -> void:
	log_rebel_war_end(world, war, "independence_recognized")
	world.nations[war.rebel_nation_id].is_rebel = false
	Diplomacy.end_war(world, war, "independence_recognized")
	_truce_all(world, war)


static func log_rebel_war_end(world: WorldState, war: War, result: String) -> void:
	world.log_event("rebel_war_end", {
		"nation": war.parent_nation_id,
		"rebel": war.rebel_nation_id,
		"war": war.id,
		"duration": world.turn - war.start_turn,
		"result": result,
		"recognition": war.recognition,
		"parent_warscore": rebel_warscore(world, war),
		"origin_provinces": war.rebel_origin_provinces.size(),
		"parent_reclaimed_ratio": _rebel_origin_ratio(world, war, war.parent_nation_id),
		"parent_losses": war.attacker_losses,
		"rebel_losses": war.defender_losses,
	})


static func _settle(world: WorldState, war: War, attacker_won: bool) -> void:
	var winner: Nation = world.nations[war.primary_attacker if attacker_won \
		else war.primary_defender]
	var loser: Nation = world.nations[war.primary_defender if attacker_won \
		else war.primary_attacker]
	var budget := absf(war.warscore)
	var terms: Array[String] = []

	var achieved_goal := attacker_won and war.warscore >= war.goal_score
	if war.goal == War.Goal.INDEPENDENCE:
		if not attacker_won:
			EmpireSystem.vassalize(world, winner, loser, false)
			terms.append("vassal_restored")
		else:
			terms.append("independence")
	elif war.goal == War.Goal.SUBJUGATION and achieved_goal \
			and war.warscore < ANNEX_OVER_VASSAL_SCORE \
			and EmpireSystem.vassalize(world, winner, loser):
		terms.append("vassal")
	else:
		budget = _annex_provinces(world, war, winner, loser, budget, terms)
		var can_subordinate_rump := loser.is_alive and loser.overlord < 0 \
			and winner.overlord < 0 \
			and loser.provinces.size() <= maxi(2, int(ceil(winner.provinces.size() * 0.50)))
		if budget >= COST_RUMP_VASSAL and can_subordinate_rump \
				and EmpireSystem.vassalize(world, winner, loser, false):
			budget -= COST_RUMP_VASSAL
			terms.append("rump_vassal")
		elif budget >= COST_INDEMNITY:
			_indemnity(world, winner, loser)
			budget -= COST_INDEMNITY
			terms.append("indemnity")

	world.log_event("peace_signed", {
		"nation": winner.id,
		"loser": loser.id,
		"war": war.id,
		"warscore": war.warscore,
		"goal": war.goal,
		"terms": terms,
		"turns": world.turn - war.start_turn,
	})
	# 조약으로 못박은 영토는 이미 넘겼다. 나머지 점령은 원상복구된다.
	Diplomacy.end_war(world, war, "peace_treaty")
	_truce_all(world, war)
	# on_peace 는 SUBJUGATION 일 때 vassalize() 가 이미 승자 권위를 올렸다고 보고
	# 넘어간다. 압승이 병합으로 끝나면 그 보상이 없으므로 실제로 무슨 일이
	# 일어났는지를 terms 로 판단한다 — rump_vassal 은 보상 없는 종속이라 정복이다.
	var resolved_goal := War.Goal.CONQUEST
	if war.goal == War.Goal.INDEPENDENCE:
		resolved_goal = War.Goal.INDEPENDENCE
	elif "vassal" in terms:
		resolved_goal = War.Goal.SUBJUGATION
	EmpireSystem.on_peace(world, winner, loser, resolved_goal)


static func _truce_all(world: WorldState, war: War) -> void:
	for a in war.attackers:
		for d in war.defenders:
			Diplomacy.set_truce(world, world.nations[a], world.nations[d])


# ---------------------------------------------------------------- 영토 요구 (§12.3)

## 수도와 이어진 땅 우선 → 해상 월경지는 낮은 확률 → 먹을 게 없으면 월경지라도.
static func rank_demands(world: WorldState, winner: Nation, loser: Nation,
		pending: Array[int]) -> Array:
	var occupied: Array[int] = []
	for pid in loser.provinces:
		if world.provinces[pid].occupied_by_nation == winner.id:
			occupied.append(pid)
	occupied.sort()

	var reachable := _land_reachable(world, winner, pending)
	var rng := world.rng_pool.get_rng("peace")
	var out: Array = []
	for pid in occupied:
		if pid in pending:
			continue
		var p: Province = world.provinces[pid]
		var value := province_value(p)
		var score := value
		var cost := _province_cost(p, loser)

		if reachable.has(pid):
			score *= 2.2                              # 육상 연결 최우선
			cost *= 0.85
		elif _shares_controlled_sea(world, winner, p):
			var accept := SEA_CLAIM_BASE + _navy_presence(world, winner, p) * SEA_CLAIM_NAVY
			accept += winner.culture_bias("maritime") * SEA_CLAIM_MARITIME
			if rng.randf() > accept:
				continue                              # 이번엔 포기
			score *= 0.55
			cost *= 1.6
		else:
			continue                                  # 완전 고립 = 요구 불가

		out.append({"province": pid, "score": score, "cost": cost})

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if is_equal_approx(a["score"], b["score"]):
			return int(a["province"]) < int(b["province"])
		return a["score"] > b["score"])

	# "먹을 게 없으면" — 유효 후보 전무 시 월경지 강제 부활
	if out.is_empty() and not occupied.is_empty():
		for pid in occupied:
			out.append({"province": pid, "score": province_value(world.provinces[pid]),
				"cost": _province_cost(world.provinces[pid], loser) * 1.4})
	return out


static func _province_cost(p: Province, loser: Nation) -> float:
	return COST_PROVINCE_BASE \
		+ COST_PROVINCE_VALUE * (province_value(p) / maxf(loser.gdp, 1.0))


static func _annex_provinces(world: WorldState, war: War, winner: Nation,
		loser: Nation, budget: float, terms: Array[String]) -> float:
	var pending: Array[int] = []
	var left := budget
	while true:
		# 한 곳을 확정할 때마다 다시 순위를 매긴다 — 먹은 땅 너머가 새로
		# "연결됨"이 되어 국경이 한 덩어리로 자란다 (§12.3).
		var ranked := rank_demands(world, winner, loser, pending)
		var picked := -1
		for entry: Dictionary in ranked:
			if float(entry["cost"]) <= left:
				picked = int(entry["province"])
				left -= float(entry["cost"])
				break
		if picked < 0:
			break
		pending.append(picked)
	for pid in pending:
		annex(world, world.provinces[pid], loser, winner, pending)
		terms.append("cede:%d" % pid)
	return left


static func _land_reachable(world: WorldState, n: Nation, pending: Array[int]) -> Dictionary:
	var seen := {}
	var queue: Array[int] = []
	for pid in n.provinces:
		seen[pid] = true
		queue.append(pid)
	for pid in pending:
		if not seen.has(pid):
			seen[pid] = true
			queue.append(pid)
	var head := 0
	var out := {}
	while head < queue.size():
		var cur: int = queue[head]
		head += 1
		for nb: int in world.provinces[cur].land_neighbors:
			if seen.has(nb):
				continue
			seen[nb] = true
			out[nb] = true
	return out


static func _shares_controlled_sea(world: WorldState, n: Nation, p: Province) -> bool:
	for zone_id: int in p.sea_zone_ids:
		if n.naval_control_zones.has(zone_id):
			return true
	return false


static func _navy_presence(world: WorldState, n: Nation, p: Province) -> float:
	var ships := 0
	for fid in n.fleets:
		var f: Fleet = world.fleets[fid]
		if f.is_alive and f.zone_id in p.sea_zone_ids:
			ships += f.ships
	return clampf(float(ships) / 40.0, 0.0, 1.0)


# ---------------------------------------------------------------- 조항 효과

## §12.4 월경지의 대가. 여기서 모든 시스템이 맞물린다.
static func annex(world: WorldState, p: Province, loser: Nation, winner: Nation,
		pending: Array[int]) -> void:
	# 같은 프로빈스를 두 번 할양받으면 목록에 중복이 남는다 (§Unrest._transfer_province).
	while loser.provinces.has(p.id):
		loser.provinces.erase(p.id)
	if not winner.provinces.has(p.id):
		winner.provinces.append(p.id)
	p.owner_nation = winner.id
	p.occupied_by_nation = -1
	p.siege_progress = 0.0
	p.siege_by_nation = -1
	p.unrest = clampf(p.unrest + CEDED_UNREST, 0.0, 1.0)
	p.integration = 0.0
	p.assimilation = 0.0
	p.rebellion_grace_turns = maxi(p.rebellion_grace_turns, CEDED_GRACE_TURNS)
	if not loser.claims.has(p.id):
		loser.claims.append(p.id)             # 실지회복 명분
	loser.supply_dirty = true
	winner.supply_dirty = true

	if not _land_reachable(world, winner, pending).has(p.id) \
			and not _is_adjacent_to_owner(world, p, winner):
		p.is_exclave = true
		p.admin_cost_mult = EXCLAVE_ADMIN_MULT
	world.log_event("province_ceded", {
		"nation": winner.id,
		"loser": loser.id,
		"province": p.id,
		"exclave": p.is_exclave,
	})
	if loser.provinces.is_empty():
		Unrest.kill_nation(world, loser)
	else:
		Unrest.recompute_capital(world, loser)
	Unrest.recompute_capital(world, winner)


static func _is_adjacent_to_owner(world: WorldState, p: Province, n: Nation) -> bool:
	for nb: int in p.land_neighbors:
		if world.provinces[nb].owner_nation == n.id:
			return true
	return false


## 배상금은 패자에게 인플레를 남긴다 — 승자도 공짜로 얻지 않는다는 원칙의 반대편.
static func _indemnity(world: WorldState, winner: Nation, loser: Nation) -> void:
	var amount := loser.gdp * INDEMNITY_GDP_SHARE
	loser.money_supply += amount
	loser.inflation += INDEMNITY_INFLATION
	winner.treasury += amount
	world.log_event("indemnity", {
		"nation": winner.id,
		"loser": loser.id,
		"amount": amount,
	})
