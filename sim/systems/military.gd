class_name Military extends RefCounted

## 전투와 보급 소모는 결정론적이다. 이동·교전 선택은 M8 WarAI가 담당한다.

const BATTLE_ATTRITION := 0.12
const LOW_SUPPLY_THRESHOLD := 0.5
const SUPPLY_ATTRITION_RATE := 0.09
const MORALE_ATTRITION_RATE := 0.06
const MORALE_FLOOR := 0.1
## 전투는 전멸이 아니라 사기 붕괴로 끝난다. 손실 비율에 비례해 사기가 깎인다.
const BATTLE_MORALE_SHOCK := 1.5
## 축소된 군대가 영원히 "패잔병"으로 남지 않도록 최대 병력 기억은 서서히 잊는다.
const PEAK_DECAY := 0.98


static func create_army(world: WorldState, n: Nation, province_id: int,
		troops: int) -> Army:
	var army := Army.new()
	army.id = world.armies.size()
	army.nation_id = n.id
	army.province_id = province_id
	army.troops = maxi(troops, 0)
	army.peak_troops = army.troops
	army.is_alive = army.troops > 0
	world.armies.append(army)
	n.armies.append(army.id)
	world.log_event("army_created", {
		"nation": n.id,
		"army": army.id,
		"province": province_id,
		"troops": army.troops,
	})
	return army


static func assign_general(world: WorldState, army: Army, character_id: int) -> bool:
	if character_id < 0 or character_id >= world.characters.size():
		return false
	var c: Character = world.characters[character_id]
	if not c.is_alive or c.nation_id != army.nation_id \
			or c.role not in [Character.Role.NONE, Character.Role.GENERAL]:
		return false
	for other in world.armies:
		if other.id != army.id and other.general_id == character_id and other.is_alive:
			return false
	_clear_army_general_role(world, army)
	c.role = Character.Role.GENERAL
	army.apply_general(c)
	world.log_event("general_assigned", {
		"nation": army.nation_id,
		"army": army.id,
		"character": c.id,
		"name": c.name,
	})
	return true


static func combat_power(world: WorldState, army: Army) -> float:
	if not army.is_alive or army.troops <= 0:
		return 0.0
	var n: Nation = world.nations[army.nation_id]
	var base := army.troops * army.tech_level
	base *= army.power_mult
	base *= army.morale
	base *= n.military_modifier
	base *= n.army_modifier
	base *= pow(maxf(army.supply_ratio + army.supply_bonus, 0.0), 1.3)
	return base


## mult 는 방어 이점 등 프로빈스 상황 배율이다. 기본값 1.0 이면 순수 란체스터.
static func resolve_battle(world: WorldState, army_a: Army, army_b: Army,
		mult_a: float = 1.0, mult_b: float = 1.0) -> Dictionary:
	var power_a := combat_power(world, army_a) * mult_a
	var power_b := combat_power(world, army_b) * mult_b
	var total_power := power_a + power_b
	if total_power <= 0.0:
		return {"casualties_a": 0, "casualties_b": 0, "power_a": power_a, "power_b": power_b}
	var ratio := power_a / total_power
	var casualties_b := mini(maxi(1, int(army_b.troops * ratio * BATTLE_ATTRITION)), army_b.troops)
	var casualties_a := mini(maxi(1, int(army_a.troops * (1.0 - ratio) * BATTLE_ATTRITION)), army_a.troops)
	_apply_battle_losses(army_a, casualties_a)
	_apply_battle_losses(army_b, casualties_b)
	if not army_a.is_alive:
		_clear_army_general_role(world, army_a)
	if not army_b.is_alive:
		_clear_army_general_role(world, army_b)
	world.log_event("battle_resolved", {
		"nation": army_a.nation_id,
		"army_a": army_a.id,
		"army_b": army_b.id,
		"nation_b": army_b.nation_id,
		"province": army_a.province_id,
		"power_a": power_a,
		"power_b": power_b,
		"casualties_a": casualties_a,
		"casualties_b": casualties_b,
	})
	return {
		"casualties_a": casualties_a,
		"casualties_b": casualties_b,
		"power_a": power_a,
		"power_b": power_b,
	}


## 편성·이동 → 교전 → 공성 → 소모 순서. 전투는 한 턴에 끝나지 않고
## 매 턴 BATTLE_ATTRITION 만큼 깎이다가 사기가 무너진 쪽이 물러난다.
static func tick(world: WorldState) -> void:
	WarAI.plan(world)
	resolve_province_battles(world)
	world.rebuild_army_index()            # 전사한 군대를 색인에서 걷어낸다
	tick_sieges(world)
	tick_army_attrition(world)


static func tick_army_attrition(world: WorldState) -> void:
	for army in world.armies:
		if not army.is_alive:
			continue
		_refresh_general(world, army)
		army.peak_troops = maxi(army.troops, int(army.peak_troops * PEAK_DECAY))
		var n: Nation = world.nations[army.nation_id]
		if army.at_sea_zone >= 0:
			# 승선 중에는 굶기지 않는다. 바다 위의 위험은 격침 하나로 충분하다.
			army.supply_ratio = 1.0
			continue
		if army.province_id >= 0 and army.province_id < n.supply_field.size():
			army.supply_ratio = n.supply_field[army.province_id]
		else:
			army.supply_ratio = Supply.MIN_SUPPLY
		var before := army.troops
		var losses := tick_attrition(army)
		if losses == 0:
			# 보급이 충분하면 사기는 징병 법률이 정한 기준선으로 회복한다.
			army.morale = move_toward(army.morale, base_morale(n), MORALE_RECOVERY)
		if not army.is_alive:
			_clear_army_general_role(world, army)
		if losses > 0:
			world.log_event("army_attrition", {
				"nation": army.nation_id,
				"army": army.id,
				"province": army.province_id,
				"supply": army.supply_ratio,
				"troops_before": before,
				"losses": losses,
			})


static func _apply_battle_losses(army: Army, casualties: int) -> void:
	var before := maxi(army.troops, 1)
	army.troops -= casualties
	army.morale = maxf(MORALE_FLOOR,
		army.morale - float(casualties) / float(before) * BATTLE_MORALE_SHOCK)
	army.is_alive = army.troops > 0


static func tick_attrition(army: Army) -> int:
	if not army.is_alive or army.supply_ratio >= LOW_SUPPLY_THRESHOLD:
		return 0
	var loss_rate := (LOW_SUPPLY_THRESHOLD - army.supply_ratio) * SUPPLY_ATTRITION_RATE
	loss_rate *= 1.0 - clampf(army.attrition_res, 0.0, 1.0)
	var losses := mini(int(army.troops * loss_rate), army.troops)
	army.troops -= losses
	army.morale = maxf(MORALE_FLOOR,
		army.morale - (LOW_SUPPLY_THRESHOLD - army.supply_ratio) * MORALE_ATTRITION_RATE)
	army.is_alive = army.troops > 0
	return losses


## 프로빈스마다 최대 한 번 교전한다. 양측 최대 군대끼리 붙는다.
static func resolve_province_battles(world: WorldState) -> void:
	var by_province := {}
	for army in world.armies:
		if not army.is_alive or army.province_id < 0:
			continue
		if not by_province.has(army.province_id):
			by_province[army.province_id] = ([] as Array[Army])
		by_province[army.province_id].append(army)

	var pids: Array = by_province.keys()
	pids.sort()                                   # 결정론 (§15)
	for pid in pids:
		_battle_in_province(world, world.provinces[pid], by_province[pid])


static func _battle_in_province(world: WorldState, p: Province,
		armies: Array[Army]) -> void:
	if armies.size() < 2:
		return
	armies.sort_custom(func(a: Army, b: Army) -> bool:
		if a.troops == b.troops:
			return a.id < b.id
		return a.troops > b.troops)
	var lead: Army = armies[0]
	var foe: Army = null
	for other in armies:
		if other.nation_id != lead.nation_id \
				and Diplomacy.are_at_war(world, lead.nation_id, other.nation_id):
			foe = other
			break
	if foe == null:
		return

	var holder := p.controller()
	var mult_lead := WarAI.defense_mult(p) if holder == lead.nation_id else 1.0
	var mult_foe := WarAI.defense_mult(p) if holder == foe.nation_id else 1.0
	var result := resolve_battle(world, lead, foe, mult_lead, mult_foe)
	_record_battle(world, lead, foe, result)
	_check_retreat(world, lead, p)
	_check_retreat(world, foe, p)


## 누가 이겼는지는 전쟁 점수(§12.1)의 재료다.
static func _record_battle(world: WorldState, a: Army, b: Army,
		result: Dictionary) -> void:
	var war := Diplomacy.war_between(world, a.nation_id, b.nation_id)
	if war == null:
		return
	var a_won := float(result["power_a"]) >= float(result["power_b"])
	var winner_side := war.side_of(a.nation_id) if a_won else war.side_of(b.nation_id)
	if winner_side > 0:
		war.battles_won += 1
	else:
		war.battles_lost += 1
	war.attacker_losses += float(result["casualties_a" if war.side_of(a.nation_id) > 0 \
		else "casualties_b"])
	war.defender_losses += float(result["casualties_b" if war.side_of(a.nation_id) > 0 \
		else "casualties_a"])


## 전멸이 아니라 붕괴로 전투가 끝난다. 물러난 군대는 다시 싸울 수 있다.
static func _check_retreat(world: WorldState, army: Army, p: Province) -> void:
	if not army.is_alive:
		return
	var broken := army.morale < WarAI.RETREAT_MORALE \
		or army.troops < int(army.peak_troops * WarAI.RETREAT_TROOP_RATIO)
	if not broken:
		return
	var best := -1
	var best_supply := -1.0
	var n: Nation = world.nations[army.nation_id]
	for nb: int in p.land_neighbors:
		var q: Province = world.provinces[nb]
		if q.controller() != army.nation_id:
			continue
		var s: float = n.supply_field[nb] if nb < n.supply_field.size() else 0.0
		if s > best_supply:
			best_supply = s
			best = nb
	if best < 0:
		return
	world.move_army_index(army.id, army.province_id, best)
	army.province_id = best
	army.retreating = true
	world.log_event("army_retreated", {
		"nation": army.nation_id,
		"army": army.id,
		"from": p.id,
		"to": best,
		"troops": army.troops,
		"morale": army.morale,
	})


## 야전군을 몰아낸 뒤에도 프로빈스는 바로 넘어오지 않는다 (§12 점령).
static func tick_sieges(world: WorldState) -> void:
	for army in world.armies:
		if not army.is_alive or army.province_id < 0:
			continue
		var p: Province = world.provinces[army.province_id]
		var holder := p.controller()
		if holder < 0 or holder == army.nation_id:
			continue
		if not Diplomacy.are_at_war(world, army.nation_id, holder):
			continue
		if _has_enemy_army(world, army):
			continue                              # 적 야전군이 남아 있으면 포위 불가
		if p.siege_by_nation != army.nation_id:
			p.siege_by_nation = army.nation_id
			p.siege_progress = 0.0
		p.siege_progress += siege_rate(p, army)
		if p.siege_progress >= 100.0:
			occupy(world, p, world.nations[army.nation_id])


static func siege_rate(p: Province, army: Army) -> float:
	var troop_factor := clampf(
		army.troops / maxf(p.population * WarAI.SIEGE_TROOP_NORM, 1.0), 0.3, 2.0)
	var rate := WarAI.SIEGE_BASE * troop_factor
	rate /= 1.0 + p.infra * WarAI.SIEGE_INFRA_RESIST
	if p.has_city:
		rate /= WarAI.SIEGE_CITY_RESIST
	rate *= 1.0 + p.unrest * WarAI.SIEGE_UNREST_HELP
	return rate


static func occupy(world: WorldState, p: Province, occupier: Nation) -> void:
	var owner: Nation = world.nations[p.owner_nation]
	# 자기 땅을 되찾은 것이면 점령 해제다. 소유국 id 를 점령자로 적으면
	# 그 프로빈스는 영원히 "점령됨" 상태로 남아 세수도 안 걷히고 전선도 안 사라진다.
	p.occupied_by_nation = -1 if occupier.id == p.owner_nation else occupier.id
	p.siege_progress = 0.0
	p.siege_by_nation = -1
	owner.supply_dirty = true
	occupier.supply_dirty = true
	world.log_event("province_liberated" if p.occupied_by_nation < 0 else "province_occupied", {
		"nation": occupier.id,
		"province": p.id,
		"owner": owner.id,
	})
	# 반란은 협상 대상이 아니다. 되찾은 땅은 즉시 회수한다 (§10).
	# 단 이것은 모국의 진압에만 맞다. 제3국이 밟은 땅까지 즉시 회수하면
	# occupied_by_nation 이 비워져 warscore 의 점령항이 영영 0 이 되고,
	# 그 전쟁은 전멸 아니면 백지평화로만 끝난다 — 강국이 파편을 조약으로
	# 흡수할 길이 사라진다. 제3국 전쟁이면 평범한 점령으로 남긴다.
	if owner.is_rebel:
		var rebel_war := Diplomacy.war_between(world, occupier.id, owner.id)
		if rebel_war != null and rebel_war.is_rebel_war:
			Unrest.reclaim_from_rebel(world, p, owner, occupier)


static func _has_enemy_army(world: WorldState, army: Army) -> bool:
	for other_id: int in world.armies_at(army.province_id):
		var other: Army = world.armies[other_id]
		if not other.is_alive:
			continue
		if Diplomacy.are_at_war(world, army.nation_id, other.nation_id):
			return true
	return false


static func release_general(world: WorldState, army: Army) -> void:
	_clear_army_general_role(world, army)


static func _refresh_general(world: WorldState, army: Army) -> void:
	if army.general_id < 0:
		return
	if army.general_id >= world.characters.size() \
			or not world.characters[army.general_id].is_alive:
		army.clear_general()
		return
	army.apply_general(world.characters[army.general_id])


static func _clear_army_general_role(world: WorldState, army: Army) -> void:
	if army.general_id >= 0 and army.general_id < world.characters.size():
		var old: Character = world.characters[army.general_id]
		if old.is_alive and old.role == Character.Role.GENERAL:
			old.role = Character.Role.NONE
	army.clear_general()


# ---------------------------------------------------------------- 상비군 (§9.4)

## 3%% 로 두면 전시 목표 병력(인구의 약 2.1%%)이 지원병제 상한 아래라 징병 법률이
## 아무 일도 하지 않는다. 2.5%% 여야 지원병제가 실제로 전시 동원을 묶는다.
const MANPOWER_RATE := 0.025             # 법률 이전, 인구 중 동원 가능 비율
const TROOP_COST_GDP_PC := 4.0           # 병사 1인 연 유지비 = 1인당 GDP × 이 값
const RECRUIT_COST_MULT := 1.5           # 신병 모집비 = 유지비 × 이 값
const TROOP_CHANGE_RATE := 0.12          # 한 턴 병력 증감 상한
const MORALE_RECOVERY := 0.06
const MORALE_MIN_BASE := 0.3
const MORALE_MAX_BASE := 1.2

## 인력 풀. 설계서에 없지만 없으면 전쟁이 끝나지 않는다 —
## 손실만큼 매 턴 재모병하면 양측이 영원히 서로를 갈기만 한다.
## 병력은 유한한 인력에서 나오고, 인력은 천천히만 회복된다.
## 회복이 빠르면 손실을 매 턴 메워 전투가 영원히 끝나지 않는다.
## 상한의 0.5%/턴 = 병력의 약 1.7%/턴 이라 전투 소모(12%)를 못 따라간다.
const MANPOWER_REGEN := 0.005             # 턴당 상한 대비 회복량


## 병사 단가를 1인당 GDP 에 묶는다. 부유한 나라는 같은 병력에 더 많은 돈을 쓴다.
static func troop_cost(n: Nation) -> float:
	return n.gdp / maxf(n.population, 1.0) * TROOP_COST_GDP_PC


## 징병 법률이 동원 가능 인구를 결정한다 (levy +0.4, volunteer -0.25).
static func manpower_cap(n: Nation) -> float:
	return maxf(n.population * MANPOWER_RATE * (1.0 + n.law_modifier("manpower")), 0.0)


static func target_troops(n: Nation) -> int:
	var cost := troop_cost(n)
	if cost <= 0.0:
		return 0
	var afford := n.gdp * BudgetAI.military_share(n) / cost
	return int(minf(afford, manpower_cap(n)))


## 징병 법률은 사기의 기준선도 정한다. 강제 징집병은 애초에 사기가 낮다.
static func base_morale(n: Nation) -> float:
	return clampf(1.0 + n.law_modifier("army_morale"), MORALE_MIN_BASE, MORALE_MAX_BASE)


## 모병·해산을 처리하고 이번 턴 군사비를 돌려준다. 정산은 credit.tick() 이 한다.
## 파이프라인 7단계(credit) 전에 지출이 확정돼야 하므로 4단계 economy 에서 호출된다.
static func plan_spending(world: WorldState, n: Nation) -> float:
	var cap := manpower_cap(n)
	if n.manpower < 0.0:
		n.manpower = cap
	# 반란은 한 번의 봉기다. 보충 인력이 없어야 진압이 가능해진다.
	if not n.is_rebel:
		n.manpower = minf(n.manpower + cap * MANPOWER_REGEN, cap)

	var current := total_troops(world, n)
	var target := target_troops(n)
	var limit := int(maxf(float(maxi(current, target)) * TROOP_CHANGE_RATE, 1.0))
	var next_total := clampi(target, current - limit, current + limit)
	var recruited := mini(maxi(next_total - current, 0), int(n.manpower))
	if recruited > 0:
		_recruit(world, n, recruited)
		n.manpower -= recruited
	elif next_total < current:
		var released := current - next_total
		_disband(world, n, released)
		n.manpower = minf(n.manpower + released, cap)   # 제대병은 인력으로 돌아온다
	return total_troops(world, n) * troop_cost(n) \
		+ recruited * troop_cost(n) * RECRUIT_COST_MULT


static func total_troops(world: WorldState, n: Nation) -> int:
	var total := 0
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if army.is_alive:
			total += army.troops
	return total


## 신병은 수도 주둔군에 합류한다. 분할·이동은 M8 WarAI 가 맡는다.
static func _recruit(world: WorldState, n: Nation, troops: int) -> void:
	var home := _home_army(world, n)
	if home == null:
		home = create_army(world, n, n.capital, 0)
		home.morale = base_morale(n)
	# 신병은 기존 병력과 사기를 인원 가중 평균한다.
	var total := home.troops + troops
	home.morale = (home.morale * home.troops + base_morale(n) * troops) / maxf(float(total), 1.0)
	home.troops = total
	home.peak_troops = maxi(home.peak_troops, home.troops)
	home.is_alive = home.troops > 0


## 해산은 병력이 많은 군대부터 비례 배분한다.
static func _disband(world: WorldState, n: Nation, troops: int) -> void:
	var remaining := troops
	var order := n.armies.duplicate()
	order.sort_custom(func(a: int, b: int) -> bool:
		var ta: int = world.armies[a].troops
		var tb: int = world.armies[b].troops
		if ta == tb:
			return a < b
		return ta > tb)
	for army_id in order:
		if remaining <= 0:
			break
		var army: Army = world.armies[army_id]
		if not army.is_alive:
			continue
		var cut := mini(army.troops, remaining)
		army.troops -= cut
		remaining -= cut
		army.is_alive = army.troops > 0
		if not army.is_alive:
			_clear_army_general_role(world, army)


## 치안 분견대는 예산으로 크기가 정해진 부대다. 신병을 여기 붙이면
## WarAI 가 다음 턴에 다시 잘라내야 하므로 야전군만 본다.
static func _home_army(world: WorldState, n: Nation) -> Army:
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if army.is_alive and army.province_id == n.capital and army.garrison_province < 0:
			return army
	return null
