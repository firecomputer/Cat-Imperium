class_name Diplomacy extends RefCounted

const EmpireSystem = preload("res://sim/systems/empire_system.gd")

## 3축 관계와 선전포고 (§11). 이 단계에서는 전쟁의 생성·종료·조회만 정의한다.
## opinion/threat/interest 갱신과 AI 개전 판정은 아래 tick() 에 이어 붙는다.


## 전체 전쟁 목록이 아니라 해당 국가의 전쟁만 훑는다. 이 함수는 전투·이동·보급
## 안쪽 루프에서 계속 불리므로 O(전쟁 수) 로 두면 시뮬이 못 돌아간다.
static func war_between(world: WorldState, a: int, b: int) -> War:
	if a < 0 or b < 0 or a >= world.nations.size() or b >= world.nations.size():
		return null
	for war_id in world.nations[a].wars:
		var war: War = world.wars[war_id]
		if war.is_active and war.is_enemy(a, b):
			return war
	return null


static func are_at_war(world: WorldState, a: int, b: int) -> bool:
	return war_between(world, a, b) != null


## 진영은 배열이다. 이미 전쟁 중이면 새로 만들지 않는다.
static func declare_war(world: WorldState, attacker: Nation, defender: Nation,
		reason: String, goal: int = War.Goal.CONQUEST) -> War:
	var existing := war_between(world, attacker.id, defender.id)
	if existing != null:
		return existing

	var war := War.new()
	war.id = world.wars.size()
	war.start_turn = world.turn
	war.primary_attacker = attacker.id
	war.primary_defender = defender.id
	war.goal = goal
	match goal:
		War.Goal.SUBJUGATION:
			war.goal_score = Peace.SUBJUGATION_SCORE
		War.Goal.INDEPENDENCE:
			war.goal_score = Peace.INDEPENDENCE_SCORE
		_:
			war.goal_score = Peace.CONQUEST_SETTLE_SCORE
	war.attackers = [attacker.id]
	war.defenders = [defender.id]
	war.start_provinces[attacker.id] = PackedInt32Array(attacker.provinces)
	war.start_provinces[defender.id] = PackedInt32Array(defender.provinces)
	world.wars.append(war)
	attacker.wars.append(war.id)
	defender.wars.append(war.id)
	attacker.at_war = true
	defender.at_war = true
	attacker.supply_dirty = true
	defender.supply_dirty = true
	world.log_event("war_declared", {
		"nation": attacker.id,
		"war": war.id,
		"defender": defender.id,
		"reason": reason,
		"goal": war.goal,
	})
	return war


static func join_war(world: WorldState, war: War, n: Nation, side: int,
		reason: String) -> void:
	if war.side_of(n.id) != 0 or not war.is_active:
		return
	if side > 0:
		war.attackers.append(n.id)
	else:
		war.defenders.append(n.id)
	war.start_provinces[n.id] = PackedInt32Array(n.provinces)
	n.wars.append(war.id)
	n.at_war = true
	n.supply_dirty = true
	world.log_event("war_joined", {
		"nation": n.id,
		"war": war.id,
		"side": side,
		"reason": reason,
	})


## restore=true 면 백지평화처럼 점령을 전부 되돌린다.
## peace.gd 가 영토를 할양받은 경우에만 false 로 부른다.
static func end_war(world: WorldState, war: War, reason: String,
		restore: bool = true) -> void:
	if not war.is_active:
		return
	war.is_active = false
	if restore:
		_release_occupations(world, war)
	for nid in war.participants():
		var n: Nation = world.nations[nid]
		n.wars.erase(war.id)
		n.at_war = _has_active_war(world, n)
		n.supply_dirty = true
	world.log_event("war_ended", {
		"nation": war.primary_attacker,
		"war": war.id,
		"defender": war.primary_defender,
		"warscore": war.warscore,
		"turns": world.turn - war.start_turn,
		"reason": reason,
	})


## 전쟁이 끝나면 점령은 유지되지 않는다 — 유지하려면 조약으로 못박아야 한다.
static func _release_occupations(world: WorldState, war: War) -> void:
	for p in world.provinces:
		if p.occupied_by_nation < 0:
			continue
		if war.side_of(p.occupied_by_nation) == 0 or war.side_of(p.owner_nation) == 0:
			continue
		if not war.is_enemy(p.occupied_by_nation, p.owner_nation):
			continue
		p.occupied_by_nation = -1
		p.siege_progress = 0.0
		p.siege_by_nation = -1
		world.nations[p.owner_nation].supply_dirty = true


## 반란 진압은 경찰 작전이지 총력전이 아니다. 예산 편성이 이 둘을 구분해야
## 반란 하나에 60턴 전시예산을 쓰다 파산하는 일이 없어진다.
static func has_foreign_war(world: WorldState, n: Nation) -> bool:
	for war_id in n.wars:
		var war: War = world.wars[war_id]
		if not war.is_active:
			continue
		for enemy in war.enemies_of(n.id):
			if not world.nations[enemy].is_rebel:
				return true
	return false


static func _has_active_war(world: WorldState, n: Nation) -> bool:
	for war_id in n.wars:
		if world.wars[war_id].is_active:
			return true
	return false


# ---------------------------------------------------------------- 3축 관계 (§11.1)

const OPINION_MIN := -100.0
const OPINION_MAX := 100.0
const OPINION_DECAY := 0.6                # 턴당 0 으로 돌아가는 양
const OPINION_WAR_DECLARED := -55.0
const OPINION_DEFAULT := -8.0             # 파산은 전 세계 신뢰를 깎는다 (§7.4)
const OPINION_SHARED_ENEMY := 0.8
const OPINION_ALLY := 1.2

const THREAT_SMOOTH := 0.25
const EXPANSION_SMOOTH := 0.3
const EXPANSION_WEIGHT := 1.5

# ---------------------------------------------------------------- 전쟁 지지도 (M14 §4)
## 평시 회복. 3턴에 1%p — 0 에서 개전 가능선(0.40)까지 120턴이다. 전쟁을 크게
## 말아먹은 나라는 한 세대 동안 다시 나서지 못한다.
const WAR_SUPPORT_PEACE_GAIN := 1.0 / 300.0
## 이 아래로 떨어지면 선전포고 자체가 불가능하다.
const WAR_SUPPORT_FLOOR := 0.40
## 지지도가 만점인 채로 이만큼 평화가 이어지면 개전 문턱을 무시한다.
const WAR_SUPPORT_CRUSADE_TURNS := 15

## 동맹은 호감이 아니라 공포로 맺어진다 (§11.2 밸런스 오브 파워).
## opinion 은 동맹 체결 여부를 조절하는 다이얼이 못 된다 — 이력 없는 쌍의
## opinion 은 정확히 0.0 이고 공유 적은 드물어서, 임계 0 이면 접경국 전부가
## 동맹(20런 984건)이고 3 만 넘겨도 전멸(25건)한다. 그래서 0 으로 두고
## 실제 조절은 아래 threat 임계로 한다.
const ALLY_MIN_OPINION := 0.0
## 0.45 는 접경국이면 거의 항상 넘는 값이라 세계가 통째로 한 동맹망이 됐고,
## 동맹은 개전 후보에서 빠지므로 정복이 사라졌다 (게이트 t_ally 88631 로 최대 병목).
## 진짜 위협에만 뭉치게 올린다.
const ALLY_MIN_THREAT := 0.70
## 동맹에는 해지가 없다 (설계서 §11 에 규격 없음). 그래서 진입 임계는 다이얼이
## 못 된다 — 300턴 중 한 번만 넘으면 영구 동맹이라, 임계를 올려도 체결 시점만
## 늦춰지고 최종 동맹 수는 그대로다. 실제 다이얼은 국가당 동맹 상한이다.
const ALLY_MAX := 1
## 동맹에 만료가 없으면 300턴 중 한 번만 임계를 넘은 쌍이 영구 동맹이 되고,
## 동맹국은 개전 후보에서 빠지므로 그 이웃은 영영 공격 불가가 된다.
## 실측(6런 × 300턴): 동맹이 지운 표적 49187 vs 살아남은 표적 3455 — 14배다.
## 만료는 해지가 아니라 재심사다. 공동 위협이 남아 있으면 갱신한다 (§11.4).
## 임기는 전쟁과 파산을 맞바꾼다. 40 은 개전을 86% 늘리지만 첫 파산이 77.9턴으로
## 앞당겨진다. 80 은 개전 +54% 에 첫 파산 104턴 — 대역 안에 드는 유일한 값이다.
const ALLIANCE_TERM := 80
const TRUCE_TURNS := 20

## 개전 판정에 쓰는 문화 보정. 호전적일수록 같은 위협도 기회로 읽는다.
const AGGRESSION_SPAN := 0.55
const OPPORTUNITY_WEIGHT := 0.75           # 약한 이웃은 위협이 낮아도 정복 기회다
## edge 는 0.75 에서 포화하므로 1프로빈스 파편과 어중간한 약소국이 똑같이 보인다.
## WAR_THRESHOLD 를 내리면 TUNING_M8 이 기록한 대로 파산이 악화되므로
## (0.12 에서 100턴 이전 첫 파산 시드 7/18 -> 14/20), 가산은 파편에만 붙인다.
const FRAGMENT_MAX_SIZE := 2
const FRAGMENT_APPETITE := 0.30
const IMPERIAL_MOMENTUM_WEIGHT := 0.80     # 승전 권위가 다음 확장의 짧은 창을 만든다
const VASSAL_MOMENTUM := 0.08              # 첫 속국 이후 확장이 승전국에 집중되게 한다
const WAR_COOLDOWN := 8                   # 한 나라가 연달아 선전포고하지 못하게
## 문턱이 0 이면 국경만 맞대면 계속 전쟁이 난다 — 전시 군사비(×2)가 상시화되어
## 모든 나라가 40턴 만에 파산했다. 전력 조건과 별개로 확실한 동기는 유지한다.
## 단일 문턱 0.25 에서는 자격 있는 국가-턴의 거의 전부가 표적 0 이 됐다. 전역
## 문턱을 0.12 로 내린 옛 실험은 모두가 함께 싸워 파산만 늘렸다. 따라서 신중국은
## 오히려 0.30 을 요구하고, 호전적 문화·매파 내각·연승국만 0.05 쪽으로 내려간다.
const WAR_THRESHOLD_CAUTIOUS := 0.30
const WAR_THRESHOLD_BOLD := 0.05
## 전투 전에 이미 15% 우세해야 한다는 예전 단일 조건은 비슷한 국가가 많은
## 세계에서 전쟁 자체를 막았다. 반대로 모두에게 넓은 열세 허용폭을 주자 600턴 전쟁은
## 81→104건으로 늘었지만 병합은 32→28건으로 줄었다. 전 세계가 똑같이 소모하면
## 승자가 생기지 않는다. 모든 국가는 동급국까지는 후보로 삼되, 호전적 문화와
## 매파 내각만 20% 안팎의 열세까지 감수하게 해 전쟁량을 일부 국가에 모은다.
const WAR_POWER_FLOOR_CAUTIOUS := 0.95
const WAR_POWER_FLOOR_BOLD := 0.80
const WAR_RISK_AGGRESSION_WEIGHT := 0.65
const WAR_RISK_HAWK_WEIGHT := 0.35
const WAR_VICTORY_MOMENTUM_AUTHORITY := 0.30
const WAR_DISADVANTAGE_PENALTY_CAUTIOUS := 1.25
const WAR_DISADVANTAGE_PENALTY_BOLD := 0.45
## 매파 내각의 값 (§인재 편차). 개전 의욕뿐 아니라 감수할 수 있는 전력비도 정한다.
const WAR_HAWK_APPETITE := 0.30
## 개전 판정의 흔들림. 중간 성향 문턱 대비 약 1/3 이라 명백한 전쟁은 그대로
## 나고 아슬아슬한 판만 뒤집힌다. 같은 세계를 두 번 돌리면 같은 전쟁이 난다.
const WAR_APPETITE_SIGMA := 0.06
const IMPERIAL_WAR_POWER_FLOOR := 0.65     # 연승국도 절반 가까이 강한 적에게는 덤비지 않는다
const IMPERIAL_EXPANSION_AUTHORITY := 0.50
const SUBJUGATION_POWER_EDGE := 1.30      # 우세가 분명하면 영토보다 종속을 노린다
## 프로빈스 1~2개짜리 파편을 속국으로 두면 행정부하(VASSAL_ADMIN_SHARE)만 늘고
## 제국은 안 큰다. 속국으로 삼을 값어치가 있는 크기부터 SUBJUGATION 을 고른다.
const SUBJUGATION_MIN_TARGET := 3
## 0.5 는 BudgetAI.infra_credit_target(0.82~0.98)과 정면충돌했다 — 설계대로
## 투자하는 나라는 영구히 개전 불가가 되어 개전 시도의 27% 가 여기서 잘렸다.
## 한도를 거의 다 쓴 나라만 막는다.
const WAR_DEBT_CEILING := 0.9             # 신용한도를 이만큼 넘게 쓴 나라는 개전 불가
const WAR_AUTHORITY_FLOOR := 0.25          # 권위가 무너진 국가는 새 원정을 벌이지 못한다
## 건국 직후에는 상비군도 인프라도 세수 기반도 없다. 이 시기의 전쟁은
## 승패와 무관하게 양쪽을 파산시키기만 해서 M5 기준을 깨뜨렸다.
const WAR_MIN_TURN := 55


static func tick(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		_update_self(world, n)
	for n in world.nations:
		if not n.is_alive:
			continue
		_update_relations(world, n)
	_expire_alliances(world)
	for n in world.nations:
		if not n.is_alive or n.is_rebel or n.overlord >= 0:
			continue
		_consider_alliance(world, n)
	for n in world.nations:
		if not n.is_alive or n.is_rebel or n.overlord >= 0:
			continue
		_consider_war(world, n)


static func _update_self(world: WorldState, n: Nation) -> void:
	n.at_foreign_war = has_foreign_war(world, n)
	var size := n.provinces.size()
	var growth := float(size - n.prev_province_count) / maxf(n.prev_province_count, 1.0)
	n.expansion_rate = lerpf(n.expansion_rate, growth, EXPANSION_SMOOTH)
	n.prev_province_count = size
	# 지지도는 전시에 사상자로만 깎인다 (Military._register_force_loss). 여기서는
	# 평시 회복과 "만족한 평화가 얼마나 오래 이어졌는가"만 센다.
	if n.at_war:
		n.peace_streak_turns = 0
	else:
		n.war_support = minf(n.war_support + WAR_SUPPORT_PEACE_GAIN, 1.0)
		n.peace_streak_turns = n.peace_streak_turns + 1 \
			if n.war_support >= 1.0 else 0
	for other_id in n.truces.keys():
		if int(n.truces[other_id]) <= world.turn:
			n.truces.erase(other_id)


## 전력. 육군이 주력이고 해군은 투사력으로만 절반 친다.
static func power(world: WorldState, n: Nation) -> float:
	var land := Military.strategic_power(world, n)
	var sea := Naval.total_ships(world, n) * n.navy_modifier * 0.5
	return land + sea


## 개전 판단용 제국권 전력. 실제 전투에는 참전한 속국 병력만 들어간다.
static func realm_power(world: WorldState, n: Nation, offensive: bool = false) -> float:
	var total := power(world, n)
	for vassal_id in n.vassals:
		if vassal_id < 0 or vassal_id >= world.nations.size():
			continue
		var v: Nation = world.nations[vassal_id]
		if not v.is_alive or v.overlord != n.id:
			continue
		if offensive and v.vassal_loyalty < EmpireSystem.OFFENSIVE_JOIN_LOYALTY:
			continue
		total += power(world, v) * 0.5
	return total


static func _update_relations(world: WorldState, n: Nation) -> void:
	var contact := _border_contact(world, n)
	var my_power := maxf(power(world, n), 1.0)
	for other_id in contact:
		var m: Nation = world.nations[other_id]
		if not m.is_alive:
			continue
		var touch: float = clampf(float(contact[other_id]) / maxf(n.provinces.size(), 1),
			0.0, 1.0)
		var ratio := power(world, m) / my_power
		var raw := clampf(ratio * (0.30 + 0.70 * touch), 0.0, 1.0)
		raw = clampf(raw + maxf(m.expansion_rate, 0.0) * EXPANSION_WEIGHT, 0.0, 1.0)
		n.threat[other_id] = lerpf(float(n.threat.get(other_id, 0.0)), raw, THREAT_SMOOTH)
		n.interest[other_id] = clampf(touch * 0.5 + _shared_enemies(world, n, m) * 0.25,
			0.0, 1.0)

		var op := float(n.opinion.get(other_id, 0.0))
		op = move_toward(op, 0.0, OPINION_DECAY)
		if other_id in n.allies:
			op += OPINION_ALLY
		op += _shared_enemies(world, n, m) * OPINION_SHARED_ENEMY
		n.opinion[other_id] = clampf(op, OPINION_MIN, OPINION_MAX)


## 국경을 맞댄 프로빈스 수. 안 닿는 나라는 위협도 아니고 관심사도 아니다.
static func _border_contact(world: WorldState, n: Nation) -> Dictionary:
	var out := {}
	var members: Array[int] = [n.id]
	if n.overlord < 0:
		for vassal_id in n.vassals:
			if vassal_id >= 0 and vassal_id < world.nations.size() \
					and world.nations[vassal_id].is_alive:
				members.append(vassal_id)
	for member_id in members:
		var member: Nation = world.nations[member_id]
		for pid in member.provinces:
			var p: Province = world.provinces[pid]
			if p.controller() != member.id:
				continue
			for nb: int in p.land_neighbors:
				var holder := world.provinces[nb].controller()
				if holder < 0:
					continue
				var root := EmpireSystem.realm_root(world, holder)
				if root == n.id:
					continue
				out[root] = int(out.get(root, 0)) + 1
	return out


static func _shared_enemies(world: WorldState, a: Nation, b: Nation) -> float:
	var shared := 0
	for war_id in a.wars:
		var war: War = world.wars[war_id]
		if not war.is_active:
			continue
		for enemy in war.enemies_of(a.id):
			if are_at_war(world, b.id, enemy):
				shared += 1
	return minf(float(shared), 2.0)


# ---------------------------------------------------------------- 개전 (§11.2)

## threat > opinion + 전쟁피로 + 방어동맹 억지력.
## 1등이 커지면 나머지가 알아서 뭉치므로 밸런스 오브 파워가 자동 발생한다.
static func war_appetite(world: WorldState, n: Nation, target_id: int) -> float:
	var target: Nation = world.nations[target_id]
	var threat := float(n.threat.get(target_id, 0.0))
	var restraint := float(n.opinion.get(target_id, 0.0)) / 100.0
	restraint += 1.0 - n.war_support
	restraint += deterrence(world, n, target)
	restraint += float(n.interest.get(target_id, 0.0)) * 0.3
	restraint -= (n.culture_bias("aggression") - 0.5) * AGGRESSION_SPAN
	var mine := maxf(realm_power(world, n, true), 1.0)
	var defended := _defended_power(world, target)
	var edge := clampf(1.0 - defended / mine, 0.0, 0.75)
	var opportunity := edge * (0.40 + n.culture_bias("aggression") * 0.60) \
		* OPPORTUNITY_WEIGHT * (0.35 + n.imperial_authority)
	if EmpireSystem.realm_province_count(world, target) <= FRAGMENT_MAX_SIZE:
		opportunity += FRAGMENT_APPETITE * (0.4 + n.culture_bias("aggression") * 0.6)
	var momentum := maxf(n.imperial_authority - 0.5, 0.0) * IMPERIAL_MOMENTUM_WEIGHT
	momentum += minf(n.vassals.size() * VASSAL_MOMENTUM, 0.24)
	momentum += (n.war_hawk - 0.5) * WAR_HAWK_APPETITE
	# 전력 열세는 금지 사유가 아니라 정치적 부담이다. 동급(비율 1)은 페널티가
	# 없고, 열세가 커질수록 신중국이 훨씬 빨리 물러난다. 방어동맹 억지력은 위의
	# deterrence 항에도 따로 잡히므로 연합을 가볍게 공격하지는 않는다.
	var disadvantage := maxf(defended / mine - 1.0, 0.0)
	var disadvantage_weight := lerpf(WAR_DISADVANTAGE_PENALTY_CAUTIOUS,
		WAR_DISADVANTAGE_PENALTY_BOLD, war_risk(n))
	restraint += disadvantage * disadvantage_weight
	return threat + opportunity + momentum - restraint


## 상대의 방어동맹이 나보다 강할수록 손대기 어렵다.
static func deterrence(world: WorldState, attacker: Nation, target: Nation) -> float:
	var mine := maxf(realm_power(world, attacker, true), 1.0)
	var theirs := 0.0
	for ally_id in target.allies:
		var ally: Nation = world.nations[ally_id]
		if ally.is_alive:
			theirs += power(world, ally)
	return clampf(theirs / mine, 0.0, 1.5)


## 튜닝용 게이트 통과 카운터. probe_tune.gd 만 읽는다.
static var debug_gates := {}


static func _gate(key: String) -> void:
	debug_gates[key] = int(debug_gates.get(key, 0)) + 1


static func _consider_war(world: WorldState, n: Nation) -> void:
	_gate("total")
	var war_cap := 2 if not n.vassals.is_empty() \
		and n.imperial_authority >= EmpireSystem.AUTHORITY_STRONG else 1
	if _foreign_war_count(world, n) >= war_cap or _has_rebel_war(world, n) \
			or n.bankruptcy_timer > 0 \
			or n.capital < 0 or n.overlord >= 0:
		_gate("blocked_at_war")
		return
	if world.turn < WAR_MIN_TURN:
		return
	# 전쟁은 돈이 든다. 국고가 비었거나 한도를 절반 넘게 쓴 나라는 시작하지 않는다.
	# 이 조건이 없으면 이미 적자인 나라가 2턴째부터 개전해 20턴 만에 파산한다.
	if n.treasury <= 0.0 or n.debt > Credit.credit_limit(n) * WAR_DEBT_CEILING:
		_gate("blocked_money")
		return
	if n.imperial_authority < WAR_AUTHORITY_FLOOR:
		_gate("blocked_authority")
		return
	if world.turn - n.last_war_turn < WAR_COOLDOWN:
		_gate("blocked_cooldown")
		return
	if n.war_support < WAR_SUPPORT_FLOOR:
		_gate("blocked_support")
		return
	# 만점 지지도가 오래 놀고 있으면 전쟁은 선택이 아니라 귀결이다. 문턱만 지우고
	# 휴전·동맹·자금·권위·쿨다운·전력비 안전장치는 그대로 둔다 — 자살적 개전까지
	# 열어 주면 소국이 먼저 사라져 제국이 오히려 편해진다.
	var crusade := n.peace_streak_turns >= WAR_SUPPORT_CRUSADE_TURNS
	var best := -1
	var best_score := -INF if crusade else war_threshold(n)
	var contact := _border_contact(world, n)
	var my_power := realm_power(world, n, true)
	_gate("eligible")
	for target_id in contact:
		var m: Nation = world.nations[target_id]
		if not m.is_alive or m.id == n.id or m.overlord >= 0 or n.truces.has(target_id) \
				or are_at_war(world, n.id, target_id):
			_gate("t_truce")
			continue
		if target_id in n.allies:
			_gate("t_ally")
			continue
		var power_floor := IMPERIAL_WAR_POWER_FLOOR if not n.vassals.is_empty() \
			and n.imperial_authority >= IMPERIAL_EXPANSION_AUTHORITY else war_power_floor(n)
		if my_power < _defended_power(world, m) * power_floor:
			_gate("t_power")
			continue                      # 이길 자신이 없으면 시작하지 않는다
		_gate("t_candidate")
		var score := war_appetite(world, n, target_id) \
			+ world.rng_pool.get_rng("war_appetite").randfn(0.0, WAR_APPETITE_SIGMA)
		if score > best_score:
			best_score = score
			best = target_id
	if best < 0:
		_gate("t_appetite_fail")
	if best < 0:
		return
	n.last_war_turn = world.turn
	if crusade:
		world.log_event("crusade_declared", {
			"nation": n.id,
			"defender": best,
			"peace_turns": n.peace_streak_turns,
		})
	n.peace_streak_turns = 0
	var target: Nation = world.nations[best]
	var goal := _choose_war_goal(world, n, target, my_power)
	var war := declare_war(world, n, target, "threat", goal)
	target.opinion[n.id] = OPINION_MIN
	EmpireSystem.call_vassals_to_war(world, war, n, 1, true)
	_call_allies(world, war, target)


## 전력비 하한은 동급국(1.0)까지는 모두 허용하고, 0이면 35% 열세, 1이면
## 20% 열세까지 위험을 감수한다. 문화만으로 고정하지 않고 내각을 섞어 같은
## 문화 안에서도 정복국과 신중국이 갈리게 한다.
static func war_power_floor(n: Nation) -> float:
	var risk := war_risk(n)
	var floor := lerpf(WAR_POWER_FLOOR_CAUTIOUS, WAR_POWER_FLOOR_BOLD, risk)
	# 정복전 승리마다 권위가 +0.08 오른다. 평화로운 국가는 0.5 부근에 머무르므로
	# 이 보정은 승전국에만 다음 전쟁을 열어 주고, 전쟁량을 세계 전체가 아니라
	# 이미 입증된 승자에게 집중한다. 권위 0.8에서 제국권 안전선에 도달한다.
	var momentum := clampf((n.imperial_authority - 0.5) \
		/ WAR_VICTORY_MOMENTUM_AUTHORITY, 0.0, 1.0)
	return lerpf(floor, IMPERIAL_WAR_POWER_FLOOR, momentum)


static func war_threshold(n: Nation) -> float:
	var threshold := lerpf(WAR_THRESHOLD_CAUTIOUS, WAR_THRESHOLD_BOLD, war_risk(n))
	var momentum := clampf((n.imperial_authority - 0.5) \
		/ WAR_VICTORY_MOMENTUM_AUTHORITY, 0.0, 1.0)
	return lerpf(threshold, WAR_THRESHOLD_BOLD, momentum)


static func war_risk(n: Nation) -> float:
	return clampf(n.culture_bias("aggression") * WAR_RISK_AGGRESSION_WEIGHT \
		+ n.war_hawk * WAR_RISK_HAWK_WEIGHT, 0.0, 1.0)


static func _foreign_war_count(world: WorldState, n: Nation) -> int:
	var count := 0
	for war_id in n.wars:
		var war: War = world.wars[war_id]
		if war.is_active and not war.is_rebel_war:
			count += 1
	return count


static func _has_rebel_war(world: WorldState, n: Nation) -> bool:
	for war_id in n.wars:
		var war: War = world.wars[war_id]
		if war.is_active and war.is_rebel_war:
			return true
	return false


static func _choose_war_goal(world: WorldState, attacker: Nation, target: Nation,
		attacker_power: float) -> int:
	if target.overlord >= 0:
		return War.Goal.CONQUEST
	var defended := _defended_power(world, target)
	var target_size := EmpireSystem.realm_province_count(world, target)
	if target_size < SUBJUGATION_MIN_TARGET:
		return War.Goal.CONQUEST
	var small_enough := target_size <= maxi(2,
		EmpireSystem.realm_province_count(world, attacker))
	if small_enough and attacker_power >= defended * SUBJUGATION_POWER_EDGE:
		return War.Goal.SUBJUGATION
	return War.Goal.CONQUEST


## 목표의 실제 방어력 = 본인 + 참전할 동맹.
static func _defended_power(world: WorldState, target: Nation) -> float:
	var total := realm_power(world, target, false)
	for ally_id in target.allies:
		var ally: Nation = world.nations[ally_id]
		if ally.is_alive:
			total += power(world, ally)
	return total


## 방어동맹은 방어 측으로만 참전한다. 이것이 대제국 견제 장치다.
static func _call_allies(world: WorldState, war: War, defender: Nation) -> void:
	EmpireSystem.call_vassals_to_war(world, war, defender, -1, false)
	for ally_id in defender.allies:
		var ally: Nation = world.nations[ally_id]
		if ally.is_alive and not ally.is_rebel and war.side_of(ally.id) == 0:
			join_war(world, war, ally, -1, "defensive_alliance")


## 임기가 끝난 동맹을 재심사한다. 쌍마다 한 번만 보도록 낮은 id 쪽에서 처리한다 (§15).
static func _expire_alliances(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		for ally_id in n.allies.duplicate():
			if ally_id < 0 or ally_id >= world.nations.size():
				continue
			var m: Nation = world.nations[ally_id]
			# 죽은 동맹은 id 순서와 무관하게 즉시 정리한다.
			if not m.is_alive:
				break_alliance(world, n, m, "ally_dead")
				continue
			if ally_id <= n.id:
				continue
			if world.turn < int(n.alliance_expiry.get(ally_id, 0)):
				continue
			# 전시에는 동맹을 끊지 않는다. 참전 중 이탈은 배신이고 §11 에 규격이 없다.
			if are_at_war(world, n.id, ally_id) or n.at_war or m.at_war:
				n.alliance_expiry[ally_id] = world.turn + ALLIANCE_TERM
				m.alliance_expiry[n.id] = world.turn + ALLIANCE_TERM
				continue
			if _shared_threat(world, n, m):
				n.alliance_expiry[ally_id] = world.turn + ALLIANCE_TERM
				m.alliance_expiry[n.id] = world.turn + ALLIANCE_TERM
				world.log_event("alliance_renewed", {"nation": n.id, "ally": ally_id})
			else:
				break_alliance(world, n, m, "term_expired")


## 형성 조건과 같은 질문이다: 둘 다 똑같이 두려워하는 제3국이 아직 있는가.
static func _shared_threat(world: WorldState, a: Nation, b: Nation) -> bool:
	for other_id in a.threat:
		var oid := int(other_id)
		if oid == a.id or oid == b.id or oid >= world.nations.size():
			continue
		if not world.nations[oid].is_alive:
			continue
		if float(a.threat[other_id]) < ALLY_MIN_THREAT:
			continue
		if float(b.threat.get(oid, 0.0)) >= ALLY_MIN_THREAT:
			return true
	return false


static func break_alliance(world: WorldState, a: Nation, b: Nation, reason: String) -> void:
	a.allies.erase(b.id)
	b.allies.erase(a.id)
	a.alliance_expiry.erase(b.id)
	b.alliance_expiry.erase(a.id)
	world.log_event("alliance_ended", {
		"nation": a.id,
		"ally": b.id,
		"reason": reason,
	})


static func _consider_alliance(world: WorldState, n: Nation) -> void:
	if n.at_war or n.overlord >= 0 or n.allies.size() >= ALLY_MAX:
		return
	var top_threat := -1
	var top := 0.0
	for other_id in n.threat:
		var t := float(n.threat[other_id])
		if t > top:
			top = t
			top_threat = int(other_id)
	if top < ALLY_MIN_THREAT:
		return
	for other_id in n.opinion:
		var m: Nation = world.nations[int(other_id)]
		if not m.is_alive or m.is_rebel or int(other_id) == top_threat:
			continue
		if int(other_id) in n.allies or are_at_war(world, n.id, int(other_id)):
			continue
		if float(n.opinion[other_id]) < ALLY_MIN_OPINION:
			continue
		if float(m.threat.get(top_threat, 0.0)) < ALLY_MIN_THREAT:
			continue
		n.allies.append(int(other_id))
		m.allies.append(n.id)
		n.alliance_expiry[int(other_id)] = world.turn + ALLIANCE_TERM
		m.alliance_expiry[n.id] = world.turn + ALLIANCE_TERM
		world.log_event("alliance_formed", {
			"nation": n.id,
			"ally": int(other_id),
			"against": top_threat,
		})
		return


## 강화 뒤에는 휴전 기간을 둔다. 없으면 같은 상대에게 매 턴 다시 선전포고한다.
static func set_truce(world: WorldState, a: Nation, b: Nation) -> void:
	a.truces[b.id] = world.turn + TRUCE_TURNS
	b.truces[a.id] = world.turn + TRUCE_TURNS
