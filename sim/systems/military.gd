class_name Military extends RefCounted

## 전투와 보급 소모는 결정론적이다. 이동·교전 선택은 M8 WarAI가 담당한다.

## 한 번의 교전이 병력을 의미 있게 소모해야 한다. 0.12에서는 대등한 전투가
## 사기 퇴각까지 약 40% 손실에 그쳤고, 다음 몇 턴의 재모병으로 거의 복구됐다.
const BATTLE_ATTRITION := 0.18
const LOW_SUPPLY_THRESHOLD := 0.5
const SUPPLY_ATTRITION_RATE := 0.09
const MORALE_ATTRITION_RATE := 0.06
const MORALE_FLOOR := 0.1
## 전투는 전멸이 아니라 사기 붕괴로 끝난다. 손실 비율에 비례해 사기가 깎인다.
const BATTLE_MORALE_SHOCK := 1.7
## 축소된 군대가 영원히 "패잔병"으로 남지 않도록 최대 병력 기억은 서서히 잊는다.
const PEAK_DECAY := 0.98
## 순수 선형비는 전력이 3배여도 손실비가 3배까지만 벌어져 압승이 안 난다.
## 전력에 지수를 물려 제곱 란체스터로 만든다. 대등한 싸움(0.5)의 손실은 그대로다.
const LANCHESTER_EXP := 2.0
## 매 턴 양측 전력에 얹는 운. 결정론 RNG 라 같은 시드는 같은 전황을 다시 만든다.
const LUCK_SIGMA := 0.15
## 운이 음수를 뽑으면 전력이 뒤집힌다. 열세를 뒤집을 여지만 남기고 바닥을 둔다.
const LUCK_FLOOR := 0.35
## 퇴각은 공짜가 아니다. 적이 전장에 남아 있으면 낙오·포로로 이만큼 더 잃는다.
const PURSUIT_LOSS := 0.40
const ROUT_DESTROY_RATIO := 0.20

## 국가 단위 전투준비도. 전멸한 야전군의 병사만 사라지는 것이 아니라 장교단과
## 동원 조직도 함께 손실된다. 평시에는 수십 턴, 전시에는 더 느리게 회복한다.
const READINESS_MIN := 0.15
const READINESS_POWER_MIN := 0.35
const READINESS_LOSS_PER_FORCE := 0.90
const CATASTROPHIC_FORCE_SHARE := 0.18
const CATASTROPHIC_READINESS := 0.30
const READINESS_RECOVERY_PEACE := 0.015
const READINESS_RECOVERY_WAR := 0.004
const RECRUIT_READINESS_FLOOR := 0.20

# ---------------------------------------------------------------- 전쟁 지지도 (M14 §4)
## 사상자가 지지도를 깎는 비율. military_readiness 와 같은 밑변(force_base)을 쓴다 —
## 두 수치가 같은 전투에서 함께 무너져야 "대군을 갈아 넣은 나라"가 하나의 상태가 된다.
const SUPPORT_LOSS_PER_FORCE := 0.60
## 동원 속도. 지지도 0 이면 절반, 1 이면 1.3 배.
const SUPPORT_MOBILIZE_MIN := 0.5
const SUPPORT_MOBILIZE_MAX := 1.3
## 야전군 편성 속도. 지지도 1.0 = 턴당 1개, 0.0 = 5턴당 1개 (M14 §3).
const SPAWN_RATE_MIN := 0.2
const SPAWN_RATE_MAX := 1.0
## 자국 땅에서의 교전이 진압으로 세어지는 최소 불만. 국경 소전투까지 물리면
## 대외전쟁만으로 본토가 갈라진다 — 눌러야 할 땅을 누른 경우만 잡는다.
const SUPPRESSION_UNREST_MIN := 0.30


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
	# 색인은 10단계(Military.tick)의 rebuild_army_index() 에서만 채워졌다. 그래서
	# 11단계(Unrest)에서 태어난 반란군은 그 턴이 끝날 때까지 색인에 없었고,
	# WarAI.plan 안에서 갈라진 야전군·분견대는 같은 패스의 armies_at() 읽기에
	# 보이지 않았다 — AI 가 자기가 방금 만든 군대를 못 보고 판단했다.
	if army.is_alive:
		world.add_army_index(army.id, army.province_id)
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
	base *= readiness_mult(n)
	base *= pow(maxf(army.supply_ratio + army.supply_bonus, 0.0), 1.3)
	return base


static func readiness_mult(n: Nation) -> float:
	return lerpf(READINESS_POWER_MIN, 1.0,
		clampf(n.military_readiness, READINESS_MIN, 1.0))


## 외교·개전 AI가 병력 머릿수만 보고 방금 전멸한 국가를 강군으로 오판하지 않게
## 보급 위치를 제외한 실제 장비·사기·준비도 전력을 합산한다.
static func strategic_power(world: WorldState, n: Nation) -> float:
	var total := 0.0
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if not army.is_alive:
			continue
		total += army.troops * army.tech_level * army.morale * army.power_mult
	return total * n.military_modifier * n.army_modifier * readiness_mult(n)


## 평균 1.0 의 곱셈 운. 전력차가 작은 싸움에서만 결과를 뒤집을 만한 폭이다.
static func _luck(rng: RandomNumberGenerator) -> float:
	return maxf(rng.randfn(1.0, LUCK_SIGMA), LUCK_FLOOR)


## mult 는 방어 이점 등 프로빈스 상황 배율이다. 기본값 1.0 이면 순수 란체스터.
static func resolve_battle(world: WorldState, army_a: Army, army_b: Army,
		mult_a: float = 1.0, mult_b: float = 1.0) -> Dictionary:
	var rng := world.rng_pool.get_rng("battle")
	var power_a := combat_power(world, army_a) * mult_a * _luck(rng)
	var power_b := combat_power(world, army_b) * mult_b * _luck(rng)
	var total_power := power_a + power_b
	if total_power <= 0.0:
		return {"casualties_a": 0, "casualties_b": 0, "power_a": power_a, "power_b": power_b}
	var edge_a := pow(power_a, LANCHESTER_EXP)
	var edge_b := pow(power_b, LANCHESTER_EXP)
	var ratio := edge_a / (edge_a + edge_b)
	var casualties_b := mini(maxi(1, int(army_b.troops * ratio * BATTLE_ATTRITION)), army_b.troops)
	var casualties_a := mini(maxi(1, int(army_a.troops * (1.0 - ratio) * BATTLE_ATTRITION)), army_a.troops)
	_apply_battle_losses(world, army_a, casualties_a)
	_apply_battle_losses(world, army_b, casualties_b)
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


static func _apply_battle_losses(world: WorldState, army: Army, casualties: int) -> void:
	var before := maxi(army.troops, 1)
	army.troops -= casualties
	army.morale = maxf(MORALE_FLOOR,
		army.morale - float(casualties) / float(before) * BATTLE_MORALE_SHOCK)
	army.is_alive = army.troops > 0
	_register_force_loss(world, army, casualties, not army.is_alive)


## 군대를 통째로 잃는 모든 경로가 같은 국가 준비도 충격을 사용한다. 포위 섬멸,
## 수송선 격침, 억류가 서로 다른 우회로가 되면 한 경로만 고쳐도 즉시 재모병한다.
static func destroy_army(world: WorldState, army: Army, reason: String) -> void:
	if not army.is_alive:
		return
	var lost := army.troops
	army.troops = 0
	army.is_alive = false
	_register_force_loss(world, army, lost, true)
	_clear_army_general_role(world, army)
	world.log_event("army_destroyed", {
		"nation": army.nation_id,
		"army": army.id,
		"lost": lost,
		"reason": reason,
		"readiness": world.nations[army.nation_id].military_readiness,
	})


static func _register_force_loss(world: WorldState, army: Army, casualties: int,
		destroyed: bool) -> void:
	if casualties <= 0 or army.nation_id < 0 or army.nation_id >= world.nations.size():
		return
	var n: Nation = world.nations[army.nation_id]
	var force_before := total_troops(world, n) + casualties
	var force_base := maxf(maxf(manpower_cap(n), float(force_before)), 1.0)
	n.military_readiness = maxf(READINESS_MIN,
		n.military_readiness - float(casualties) / force_base * READINESS_LOSS_PER_FORCE)
	n.war_support = maxf(n.war_support
		- float(casualties) / force_base * SUPPORT_LOSS_PER_FORCE, 0.0)
	if destroyed and float(army.peak_troops) / force_base >= CATASTROPHIC_FORCE_SHARE:
		var before := n.military_readiness
		n.military_readiness = minf(n.military_readiness, CATASTROPHIC_READINESS)
		if before > n.military_readiness:
			world.log_event("military_collapse", {
				"nation": n.id,
				"army": army.id,
				"lost": casualties,
				"readiness": n.military_readiness,
			})


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
	_register_domestic_suppression(world, p, lead, foe)
	_check_retreat(world, lead, p, foe)
	_check_retreat(world, foe, p, lead)


## 자국 땅을 군대로 밟은 턴은 기록에 남는다 (M14 §1). 반란 진압전은 어느 칸에서
## 싸우든 진압이고, 대외전쟁은 불만이 끓는 자국 프로빈스에서 싸운 경우만이다.
static func _register_domestic_suppression(world: WorldState, p: Province,
		a: Army, b: Army) -> void:
	var war := Diplomacy.war_between(world, a.nation_id, b.nation_id)
	if war != null and war.is_rebel_war:
		Unrest.register_suppression(world, p, Unrest.SEPARATISM_COMBAT)
		return
	if p.unrest < SUPPRESSION_UNREST_MIN:
		return
	if p.owner_nation == a.nation_id or p.owner_nation == b.nation_id:
		Unrest.register_suppression(world, p, Unrest.SEPARATISM_COMBAT)


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
## 다만 공짜는 아니다 — 추격당한 패잔병은 낙오·포로로 한 번 더 갈린다.
static func _check_retreat(world: WorldState, army: Army, p: Province,
		pursuer: Army = null) -> void:
	if not army.is_alive:
		return
	var broken := army.morale < WarAI.RETREAT_MORALE \
		or army.troops < int(army.peak_troops * WarAI.RETREAT_TROOP_RATIO)
	if not broken:
		return
	var pursued := 0
	if pursuer != null and pursuer.is_alive:
		# 최소 1명은 남긴 뒤 아래 궤멸/퇴각 판정에서 처리한다.
		pursued = mini(int(army.troops * PURSUIT_LOSS), army.troops - 1)
		if pursued > 0:
			_apply_battle_losses(world, army, pursued)
	if not army.is_alive:
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
	# 퇴로가 없거나 최대 편제의 20%도 남지 않은 패잔병은 포로·탈영으로 해체된다.
	# 예전에는 안전한 이웃이 없어도 같은 칸에 남아 다음 턴 다시 싸우는 좀비 군대였다.
	if best < 0:
		destroy_army(world, army, "no_retreat_route")
		return
	if army.troops < int(army.peak_troops * ROUT_DESTROY_RATIO):
		destroy_army(world, army, "routed")
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
		"pursued": pursued,
	})


## 야전군을 몰아낸 뒤에도 프로빈스는 바로 넘어오지 않는다 (§12 점령).
static func tick_sieges(world: WorldState) -> void:
	_clear_illegal_sieges(world)
	for army in world.armies:
		if not army.is_alive or army.province_id < 0:
			continue
		var p: Province = world.provinces[army.province_id]
		var holder := p.controller()
		if holder < 0 or holder == army.nation_id:
			continue
		if not Diplomacy.are_at_war(world, army.nation_id, holder):
			continue
		# 공성의 주인은 나라가 아니라 진영이다. 나라로 잡으면 같은 편 다른 나라의
		# 군대가 같은 칸에 설 때마다 서로 siege_by_nation 을 뺏으며 진행도를 0 으로
		# 되돌려, 두 나라가 겹친 공성은 영원히 한 턴치에서 멈춘다 (실측: 리셋
		# 745건 전부가 이 경우, 전체 공성 에피소드의 61.7%).
		if p.siege_by_nation < 0 \
				or Diplomacy.are_at_war(world, p.siege_by_nation, army.nation_id):
			p.siege_by_nation = army.nation_id
			p.siege_progress = 0.0
		p.siege_progress += siege_rate(p, army)
		# 반란군이 쥔 땅을 포위하는 것도, 빼앗긴 자국 땅을 되찾는 것도 진압이다.
		var war := Diplomacy.war_between(world, army.nation_id, holder)
		if (war != null and war.is_rebel_war) or p.owner_nation == army.nation_id:
			Unrest.register_suppression(world, p, Unrest.SEPARATISM_COMBAT)
		if p.siege_progress >= 100.0:
			occupy(world, p, world.nations[army.nation_id])


## 종전은 진행중인 공성을 정리하지 않았다 — Diplomacy._release_occupations 는
## *이미 점령된* 땅만 훑기 때문이다. 그래서 포위가 100 에 닿기 전에 강화가 서면
## siege_by_nation 이 영영 남아 지도에 유령 공성 마커가 박혔다 (300턴 38개 중 21개).
## 퇴각으로 잠시 비운 포위는 건드리지 않는다 — 여기서 지우는 것은 *교전권이
## 사라진* 공성뿐이다.
static func _clear_illegal_sieges(world: WorldState) -> void:
	for p in world.provinces:
		if p.siege_by_nation < 0:
			continue
		var holder := p.controller()
		if holder >= 0 and holder != p.siege_by_nation \
				and Diplomacy.are_at_war(world, p.siege_by_nation, holder):
			continue
		p.siege_by_nation = -1
		p.siege_progress = 0.0


static func siege_rate(p: Province, army: Army) -> float:
	var norm := maxf(p.population * WarAI.SIEGE_TROOP_NORM, 1.0)
	# 살아 있는 병력은 규모에 비례해 언제나 공성을 진행한다. 최소 투자 병력과
	# 방어군 봉쇄 조건은 전쟁을 영구 정체시키므로 두지 않는다.
	var troop_factor := clampf(army.troops / norm, 0.0, 2.0)
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
	if p.occupied_by_nation >= 0:
		# 조약 때 "한 번이라도 밟은 땅"으로 남는다 (§P1). 반란전은 협상 대상이 아니다.
		var claim_war := Diplomacy.war_between(world, occupier.id, owner.id)
		if claim_war != null and not claim_war.is_rebel_war:
			claim_war.occupied_ever[p.id] = occupier.id
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

## 군사비가 병력 수로만 사라지지 않게 하는 장비·훈련 품질. 군사비/완전동원 비용이
## 높을수록 적은 병력에도 더 좋은 장비를 지급한다. 품질은 즉시 뛰지 않고 누적된다.
const QUALITY_MIN := 0.85
const QUALITY_MAX := 1.55
const QUALITY_BASE := 0.80
const QUALITY_INTENSITY_GAIN := 0.75
const QUALITY_TRAIN_RATE := 0.025
const QUALITY_DECAY_RATE := 0.005
const QUALITY_TRAIN_COST_MULT := 6.0
## 품질 1.55가 병사 단가도 그대로 1.55배로 만들면 지원병제조차 인력 상한에
## 닿지 않아 징병법이 다시 죽은 값이 된다. 장비 품질 상승분 중 25%만 반복 유지비,
## 나머지는 아래 일회성 훈련·장비 투자비로 지불한다.
const QUALITY_UPKEEP_SHARE := 0.25
const RECRUIT_QUALITY := 1.0


## 지지도가 높은 나라는 같은 준비도로 더 빨리 동원한다 (M14 §4).
static func mobilization_mult(n: Nation) -> float:
	return lerpf(SUPPORT_MOBILIZE_MIN, SUPPORT_MOBILIZE_MAX,
		clampf(n.war_support, 0.0, 1.0))


## 턴당 새로 편성할 수 있는 야전군 수. WarAI._organize 가 이 예산 안에서만 쪼갠다.
static func spawn_rate(n: Nation) -> float:
	return lerpf(SPAWN_RATE_MIN, SPAWN_RATE_MAX, clampf(n.war_support, 0.0, 1.0))


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
	# 같은 예산에서 품질을 올리면 머릿수는 줄어든다. 더 많은 투자는 수량과 품질을
	# 함께 올리지만, 품질이 공짜 보너스로 중복 계산되지는 않는다.
	var afford := n.gdp * BudgetAI.military_share(n) \
		/ (cost * quality_upkeep_mult(military_quality_target(n)))
	return int(minf(afford, manpower_cap(n)))


static func military_quality_target(n: Nation) -> float:
	var mobilization_cost_share := MANPOWER_RATE \
		* maxf(1.0 + n.law_modifier("manpower"), 0.1) * TROOP_COST_GDP_PC
	var intensity := BudgetAI.military_share(n) / maxf(mobilization_cost_share, 0.001)
	return clampf(QUALITY_BASE + intensity * QUALITY_INTENSITY_GAIN,
		QUALITY_MIN, QUALITY_MAX)


static func quality_upkeep_mult(quality: float) -> float:
	return 1.0 + (quality - 1.0) * QUALITY_UPKEEP_SHARE


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
	var recovery := READINESS_RECOVERY_WAR if n.at_war else READINESS_RECOVERY_PEACE
	n.military_readiness = minf(n.military_readiness + recovery, 1.0)
	# 편성 예산은 여기서 적립된다 — 파이프라인 4단계라 10단계의 WarAI 보다 먼저 돈다.
	# 상한이 1.0 이라 오래 쉰다고 여러 부대를 한 턴에 뽑지는 못한다.
	n.spawn_credit = minf(n.spawn_credit + spawn_rate(n), 1.0)

	var current := total_troops(world, n)
	var target := target_troops(n)
	var recruit_capacity := lerpf(RECRUIT_READINESS_FLOOR, 1.0, n.military_readiness)
	recruit_capacity *= mobilization_mult(n)
	var limit := int(maxf(float(maxi(current, target)) * TROOP_CHANGE_RATE \
		* recruit_capacity, 1.0))
	var next_total := clampi(target, current - limit, current + limit)
	var recruited := mini(maxi(next_total - current, 0), int(n.manpower))
	if recruited > 0:
		_recruit(world, n, recruited)
		n.manpower -= recruited
	elif next_total < current:
		var released := current - next_total
		_disband(world, n, released)
		n.manpower = minf(n.manpower + released, cap)   # 제대병은 인력으로 돌아온다
	var training_cost := _train_armies(world, n, military_quality_target(n))
	return total_troops(world, n) * troop_cost(n) \
		* quality_upkeep_mult(average_quality(world, n)) \
		+ recruited * troop_cost(n) * RECRUIT_COST_MULT + training_cost


static func average_quality(world: WorldState, n: Nation) -> float:
	var weighted := 0.0
	var troops := 0
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if not army.is_alive:
			continue
		weighted += army.tech_level * army.troops
		troops += army.troops
	return weighted / maxf(float(troops), 1.0) if troops > 0 else RECRUIT_QUALITY


static func _train_armies(world: WorldState, n: Nation, target: float) -> float:
	var cost := 0.0
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if not army.is_alive:
			continue
		var before := army.tech_level
		var rate := QUALITY_TRAIN_RATE if target > before else QUALITY_DECAY_RATE
		army.tech_level = move_toward(before, target, rate)
		if army.tech_level > before:
			cost += (army.tech_level - before) * army.troops * troop_cost(n) \
				* QUALITY_TRAIN_COST_MULT
	return cost


static func total_troops(world: WorldState, n: Nation) -> int:
	var total := 0
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if army.is_alive:
			total += army.troops
	return total


## 신병은 집결지 주둔군에 합류한다. 분할·이동은 M8 WarAI 가 맡는다.
static func _recruit(world: WorldState, n: Nation, troops: int) -> void:
	var muster := _muster_province(world, n)
	var home := _home_army(world, n, muster)
	if home == null:
		home = create_army(world, n, muster, 0)
		home.morale = base_morale(n)
	# 신병은 기존 병력과 사기를 인원 가중 평균한다.
	var total := home.troops + troops
	home.morale = (home.morale * home.troops + base_morale(n) * troops) / maxf(float(total), 1.0)
	home.tech_level = (home.tech_level * home.troops + RECRUIT_QUALITY * troops) \
		/ maxf(float(total), 1.0)
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
static func _home_army(world: WorldState, n: Nation, pid: int) -> Army:
	for army_id in n.armies:
		var army: Army = world.armies[army_id]
		if army.is_alive and army.province_id == pid and army.garrison_province < 0:
			return army
	return null


## 신병 집결지. 적 야전군이 서 있는 칸에 매 턴 신병을 세우면 그 병력은 태어나는
## 족족 갈리면서 적을 붙잡아 두는 소모품이 된다 — 이산 턴에서는 한 번 붙은 군대가
## 이동도 공성도 못 하기 때문이다 (실측: 절망적 열세 교전 1584건 중 1267건이
## 자국 수도, 그중 1188건은 물러설 칸조차 없었다). 적 없는 자국 땅을 우선한다.
static func _muster_province(world: WorldState, n: Nation) -> int:
	if n.capital >= 0 and _is_quiet(world, n, n.capital):
		return n.capital
	for pid in n.provinces:
		if _is_quiet(world, n, pid):
			return pid
	return n.capital                      # 온 나라가 전장이면 수도에서 마지막 저항이다


static func _is_quiet(world: WorldState, n: Nation, pid: int) -> bool:
	if pid < 0 or world.provinces[pid].controller() != n.id:
		return false
	for army_id: int in world.armies_at(pid):
		var other: Army = world.armies[army_id]
		if other.is_alive and Diplomacy.are_at_war(world, n.id, other.nation_id):
			return false
	return true
