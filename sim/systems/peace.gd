class_name Peace extends RefCounted

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## 전쟁 점수와 강화 (§12). 전쟁은 전멸이 아니라 협상으로 끝난다.
## 조항의 총 비용이 warscore 를 넘을 수 없다 — 이긴 만큼만 뜯는다.

const MIN_WAR_TURNS := 12
## 패자가 강화를 제안할 의사가 생기는 선. 이것은 승자가 전쟁 목표를 달성해
## 제안을 받아들이는 선과 다르다. 예전에는 둘이 모두 35라서 압승용 70점 로직에
## 도달하기 전에 전쟁이 자동 종료됐다.
const ACCEPT_SCORE := 35.0
const CONQUEST_SETTLE_SCORE := 70.0       # 정복 승자가 만족하는 조약 예산
## 45를 90으로 늘리거나 우세전만 90까지 늘린 A/B 모두 70점 종전과 병합을 줄였다.
## 따라서 전쟁 회전수를 지키는 안전판은 45턴으로 유지한다. 낮은 점수의 즉시 종전은
## ACCEPT_SCORE와 승자 목표 점수의 분리가 막고, 45턴 뒤에는 재정 무한전을 닫는다.
const EXHAUSTION_TURNS := 45
const SUBJUGATION_SCORE := 55.0           # 전 국토 병합보다 낮지만 35점 즉시 복속은 금지
const INDEPENDENCE_SCORE := 55.0
const SUBJUGATION_EXHAUSTION_TURNS := 45
const PARTIAL_PEACE_SCORE := 20.0
## 야전 전투·공성 진행·점령이 이만큼 없으면 유령전쟁이다. 전선이 닿지 않는
## 참전국(먼 동맹의 방어 소집)이나 상호 진입 문턱 교착은 점수도 소모율도 밀지
## 못해 아래 SETTLE_CONSUMED_RATIO 게이트에 영원히 닿지 않는다. 시간만 흐르는
## 전쟁은 종전 자격을 기다리지 않고 여기서 끊는다. MIN_WAR_TURNS 보다 커야
## 개전 직후 행군 턴이 유령으로 잡히지 않는다.
const GHOST_WAR_TURNS := 15
## 종전 자격. 지는 진영이 참전 시 프로빈스의 이 비율 이상을 실제로 잃기 전에는
## 어떤 강화 경로도 열리지 않는다 — 점수만 채운 조기 종전과 45턴 소진 백지평화를
## 함께 막는다. 잃었다는 것은 소유권이 넘어갔거나 지금 적에게 점령당한 상태다.
const SETTLE_CONSUMED_RATIO := 0.60

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
## 다만 origin 이 1 프로빈스인 반란(가장 흔하다)에서 ratio 는 1.0 아니면 0.0 이고
## 0.0 은 위에서 annihilated 로 끝나므로, 이 두 항은 반란전-턴의 3.5% 에서만
## 발동했다. 실제 제동은 아래 압박항이 건다.
const RECOGNITION_LOSING_RATIO := 0.30
const RECOGNITION_LOSING_PENALTY := 1.25
const RECOGNITION_COLLAPSE_RATIO := 0.05
const RECOGNITION_COLLAPSE_PENALTY := 2.0
## 모국이 원영토를 물리적으로 누르는 만큼 인정도 증가를 깎는다. controller() 플립만
## 세면 포위도 주둔도 0 점이라 독립이 "65턴 버티기" 시계가 된다 (실측: 반란전-턴의
## 96.5% 에서 인정도가 단조 증가했다).
const RECOGNITION_PRESSURE_GAIN := 1.8
## 포위까지 못 걸고 야전군만 올라와 있을 때의 압박. 포위 진행도와 같은 척도다.
const PRESENCE_PRESSURE := 0.5
## 인정도 증가에 얹는 결정론 난수. 평균이 1 미만이라 같은 압박에서도 독립이
## 평균적으로 늦어진다 — 모국이 진압할 시간을 번다. 감점에는 곱하지 않는다.
const RECOGNITION_LUCK_MEAN := 0.85
const RECOGNITION_LUCK_SIGMA := 0.25
const RECOGNITION_LUCK_FLOOR := 0.20
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
## 조약 전리품을 서명 순간의 점령 스냅샷에서 떼어낸다 (§P1). 실측 강화조약
## 148건 중 79건(53%)이 할양 0 이었다 — warscore 중앙값은 42 인데 그 점수는
## 전투·전쟁피로에서 나오고 전선은 시소를 타서, 서명하는 턴에는 대개 아무 땅도
## 손에 없었다. 점수와 전리품이 분리돼 있던 것을 잇는다.
const WAR_CLAIM_COST_MULT := 1.35         # 한 번 점령했던 땅
const WAR_CLAIM_SCORE_SHARE := 0.90       # 지금 쥔 땅보다는 뒤로 밀린다
const CRUSHING_CLAIM_SCORE := 70.0        # 이 점수를 넘으면 못 밟은 인접지도 요구한다
## 2.0 에서는 압승 조약의 97% 가 "살 땅은 눈앞에 있는데 점수가 모자라서" 멈췄다
## (98건 실측: 패자 4.42칸 중 2.44칸만 먹고 평균 15.1점 부족, 예산은 19.4점 남음).
## warscore 천장이 점령 70 + 전투 20 - 전쟁피로라 전 국토를 밟아도 소국 하나를
## 다 못 삼켰다. 1.5 는 40시드 짝지은 비교에서 최대국 realm_share 를 +0.0105
## 올렸다 (t=2.72). 1.2 까지 내리면 모두가 똑같이 뜯어가 다시 대칭이 되어
## 유의하지 않았다 (t=1.21).
const CRUSHING_CLAIM_COST_MULT := 1.5
const CRUSHING_CLAIM_SCORE_SHARE := 0.70
const DEBT_TRANSFER_MAX := 0.50           # 프로빈스 하나가 가져갈 수 있는 부채 비율 상한
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


## 참전 시점 영토 중 지금 손을 떠난 비율 (0~1). 소유권이 넘어갔거나 적에게
## 점령당한 칸을 함께 센다 — 전쟁이 실제로 국토를 갈아 먹었는지의 척도다.
static func consumed_ratio(world: WorldState, war: War, ids: Array[int]) -> float:
	var total := 0
	var lost := 0
	for nid in ids:
		var snapshot: PackedInt32Array = war.start_provinces.get(nid, PackedInt32Array())
		total += snapshot.size()
		for pid: int in snapshot:
			if world.provinces[pid].controller() != nid:
				lost += 1
	if total <= 0:
		return 1.0
	return float(lost) / float(total)


## 종전 자격. 지는 쪽 국토가 대부분 갈려 나가야 협상 테이블이 열린다.
static func _can_settle(world: WorldState, war: War, attacker_won: bool) -> bool:
	var loser_ids := war.defenders if attacker_won else war.attackers
	return consumed_ratio(world, war, loser_ids) >= SETTLE_CONSUMED_RATIO


static func _weariness(world: WorldState, ids: Array[int]) -> float:
	var total := 0.0
	for nid in ids:
		total += 1.0 - world.nations[nid].war_support
	return total / maxf(ids.size(), 1)


# ---------------------------------------------------------------- 강화

static func _consider_peace(world: WorldState, war: War) -> void:
	var length := world.turn - war.start_turn
	if war.is_rebel_war:
		_tick_rebel_war(world, war, length)
		return
	if length < MIN_WAR_TURNS:
		return

	# 아무 일도 일어나지 않는 전쟁은 종전 자격(_can_settle)을 기다리지 않는다.
	# 소진 백지평화까지 그 게이트 뒤에 있어서, 서로 밀지 못하는 전쟁에는
	# 탈출구가 하나도 없었다.
	if world.turn - war.last_progress_turn >= GHOST_WAR_TURNS:
		if absf(war.warscore) >= PARTIAL_PEACE_SCORE:
			_settle(world, war, war.warscore > 0.0)
			return
		Diplomacy.end_war(world, war, "stalemate")
		_truce_all(world, war)
		return

	# 35점은 패자가 협상에 응하는 시점일 뿐 승자가 만족하는 시점은 아니다.
	# 공격자는 자기 전쟁 목표를, 방어 측 승자는 정복전과 같은 결정적 우세를 요구한다.
	# 이 분리가 없으면 CRUSHING_CLAIM_SCORE/ANNEX_OVER_VASSAL_SCORE(70)는 한 틱에
	# 점수가 크게 뛰는 예외 외에는 자연스럽게 도달할 수 없다.
	var attacker_won := war.warscore > 0.0
	# 점수가 아무리 나도 상대 국토를 대부분 먹기 전에는 전쟁이 끝나지 않는다.
	# 이 게이트는 아래 세 경로(목표 달성·부분 강화·소진 백지평화) 전부에 걸린다.
	if not _can_settle(world, war, attacker_won):
		return
	var winner_target := war.goal_score if attacker_won else CONQUEST_SETTLE_SCORE
	if absf(war.warscore) >= winner_target:
		_settle(world, war, attacker_won)
		return
	var exhaustion := SUBJUGATION_EXHAUSTION_TURNS \
		if war.goal == War.Goal.SUBJUGATION else EXHAUSTION_TURNS
	if length >= exhaustion:
		if absf(war.warscore) >= PARTIAL_PEACE_SCORE:
			_settle(world, war, attacker_won)
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
		return
	# 4. 유령 반란전. 교전도 인정도 진행도 멈춘 반란전은 어느 시계로도 끝나지
	#    않는다 — 서로 닿지 못한 채 1068턴을 흘려보낸 판이 실측으로 나왔다.
	#    누가 원영토를 쥐고 있느냐로 결착한다 (일반전이 warscore 부호로 가르는 것과 같다).
	if world.turn - war.last_progress_turn >= GHOST_WAR_TURNS:
		if rebel_warscore(world, war) >= 0.0:
			_resolve_rebel_defeat(world, war, "stalemate_suppressed")
		else:
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
	# 언제 독립이 서는지는 모국이 알 수 없어야 한다. 고정 증가율은 관전자에게
	# 남은 턴 수를 그대로 보여 주는 시계였다.
	if gain > 0.0:
		gain *= maxf(world.rng_pool.get_rng("recognition").randfn(
			RECOGNITION_LUCK_MEAN, RECOGNITION_LUCK_SIGMA), RECOGNITION_LUCK_FLOOR)
	gain -= maxf(_parent_pressure(world, war),
		_rebel_attrition_pressure(war)) * RECOGNITION_PRESSURE_GAIN
	if ratio < RECOGNITION_LOSING_RATIO:
		gain -= RECOGNITION_LOSING_PENALTY
	if ratio <= RECOGNITION_COLLAPSE_RATIO:
		gain -= RECOGNITION_COLLAPSE_PENALTY
	# 인정도가 오르고 있다면 그 전쟁은 유령이 아니다. 반란전에는 교전 말고도
	# 결말로 가는 시계가 하나 더 있고, 그것이 도는 한 끊을 이유가 없다.
	if gain > 0.0:
		war.last_progress_turn = world.turn
	war.recognition = clampf(war.recognition + gain, 0.0, REBEL_RECOGNITION_TARGET)


## 야전 소모도 압박이다. 모국 군대가 원영토까지 못 올라가도 반란군만 갈려
## 나가고 있다면 독립이 다가올 이유가 없다. 반란전에서 모국은 공격 진영이므로
## defender_losses 가 곧 반란군 손실이다.
static func _rebel_attrition_pressure(war: War) -> float:
	var losses := war.attacker_losses + war.defender_losses
	if losses <= 0.0:
		return 0.0
	return clampf((war.defender_losses / losses - 0.5) * 2.0, 0.0, 1.0)


## 모국이 반란국 원영토에 가하는 물리적 압박 (0~1). 반란국이 아직 쥔 칸에 대해
## 포위 진행도와 야전군 주둔 중 큰 값을 쓰고, 그 칸들에 대해 평균한다.
## 땅을 뺏기 직전까지 간 포위가 인정도에 한 푼도 반영되지 않던 것을 고친다.
static func _parent_pressure(world: WorldState, war: War) -> float:
	var held := 0
	var total := 0.0
	for pid: int in war.rebel_origin_provinces:
		if not _controls(world, pid, war.rebel_nation_id):
			continue
		held += 1
		var p: Province = world.provinces[pid]
		var press := 0.0
		if p.siege_by_nation == war.parent_nation_id:
			press = clampf(p.siege_progress / 100.0, 0.0, 1.0)
		for army_id: int in world.armies_at(pid):
			var a: Army = world.armies[army_id]
			if a.is_alive and a.nation_id == war.parent_nation_id:
				press = maxf(press, PRESENCE_PRESSURE)
				break
		total += press
	if held <= 0:
		return 1.0
	return total / float(held)


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
	var rebel: Nation = world.nations[war.rebel_nation_id]
	rebel.is_rebel = false
	# 독립이 인정된 순간부터는 봉기군이 아니라 나라다. 어간은 그대로 두어 같은
	# 세력임이 읽히게 하고 칭호만 규모에 맞춰 바꾼다 — 예전에는 300턴 뒤에도
	# "봉기군" 이 제국 크기로 앉아 있었다.
	NationPlacer.retitle(world, rebel)
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
		pending: Array[int], war: War = null) -> Array:
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

	# 점령 스냅샷 밖의 청구권 (§P1). 난수를 쓰지 않는 육상 연결 후보만 더한다 —
	# 위 반복문의 randf() 호출 순서를 건드리지 않아야 같은 시드가 같은 세계를 만든다.
	_append_war_claims(world, winner, loser, pending, war, reachable, out)

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


## 전쟁 청구권. 지금 점령 중이 아니어도 (1) 이 전쟁에서 한 번 점령했던 땅,
## (2) 압승이면 국경을 맞댄 땅까지 요구할 수 있다. 둘 다 육상으로 이어져야 하고
## 값이 더 비싸다 — warscore 는 전투에서도 나오는데 전리품만 점령에 묶여 있어
## 이긴 전쟁의 절반이 빈손으로 끝나던 것을 푼다.
static func _append_war_claims(world: WorldState, winner: Nation, loser: Nation,
		pending: Array[int], war: War, reachable: Dictionary, out: Array) -> void:
	if war == null:
		return
	var crushing := absf(war.warscore) >= CRUSHING_CLAIM_SCORE
	var listed := {}
	for entry: Dictionary in out:
		listed[int(entry["province"])] = true
	var candidates: Array[int] = []
	for pid in loser.provinces:
		if listed.has(pid) or pid in pending or not reachable.has(pid):
			continue
		if world.provinces[pid].occupied_by_nation >= 0:
			continue                              # 제3국이 밟고 있는 땅은 못 판다
		candidates.append(pid)
	candidates.sort()
	for pid in candidates:
		var p: Province = world.provinces[pid]
		var occupied_before := int(war.occupied_ever.get(pid, -1)) == winner.id
		if not occupied_before and not crushing:
			continue
		var mult := WAR_CLAIM_COST_MULT if occupied_before else CRUSHING_CLAIM_COST_MULT
		var share := WAR_CLAIM_SCORE_SHARE if occupied_before else CRUSHING_CLAIM_SCORE_SHARE
		out.append({
			"province": pid,
			"score": province_value(p) * 2.2 * share,
			"cost": _province_cost(p, loser) * 0.85 * mult,
		})


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
		var ranked := rank_demands(world, winner, loser, pending, war)
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

## 할양지가 지고 있던 몫의 부채는 함께 넘어간다. 이 항이 없으면 전리품이 커질수록
## 패자는 줄어든 세수로 그대로인 부채를 갚아야 해 조약이 곧 파산 선고가 되고
## (§P1 이후 2프로빈스 이상 국가의 파산이 급증했다), 승자에게 정복은 공짜가 된다.
static func _transfer_debt(world: WorldState, p: Province, loser: Nation,
		winner: Nation) -> void:
	if loser.debt <= 0.0:
		return
	var realm := 0.0
	for pid in loser.provinces:
		realm += world.provinces[pid].gdp
	if realm <= 0.0:
		return
	var share := clampf(p.gdp / realm, 0.0, DEBT_TRANSFER_MAX)
	var moved := loser.debt * share
	loser.debt -= moved
	winner.debt += moved


## §12.4 월경지의 대가. 여기서 모든 시스템이 맞물린다.
static func annex(world: WorldState, p: Province, loser: Nation, winner: Nation,
		pending: Array[int]) -> void:
	_transfer_debt(world, p, loser, winner)
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
