class_name AdvisorEffects extends RefCounted

## 현재 재직 중인 7명 고문의 능력을 국가 파생 스탯으로 변환한다 (§13.4).


static func apply(world: WorldState) -> void:
	for n in world.nations:
		if not n.is_alive:
			continue
		apply_nation(world, n)


static func apply_nation(world: WorldState, n: Nation) -> void:
	var previous_supply_range := n.supply_range_mult
	var political := 0.0
	var hawk_sum := 0.0
	var hawk_count := 0
	var suppression_sum := 0.0
	var tech := 0.0
	var economic := 0.0
	var military := 0.0
	var naval := 0.0
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if not c.is_alive:
			continue
		match c.role:
			Character.Role.POLITICAL:
				political += c.score_for(c.role) / 300.0
				hawk_sum += c.hawkish
				suppression_sum += c.suppression_bias
				hawk_count += 1
			Character.Role.TECH:
				tech = c.score_for(c.role) / 100.0
			Character.Role.ECONOMIC:
				economic = c.score_for(c.role) / 100.0
			Character.Role.MILITARY:
				military = c.score_for(c.role) / 100.0
			Character.Role.NAVAL:
				naval = c.score_for(c.role) / 100.0

	political = clampf(political, 0.0, 1.0)
	tech = clampf(tech, 0.0, 1.0)
	economic = clampf(economic, 0.0, 1.0)
	military = clampf(military, 0.0, 1.0)
	naval = clampf(naval, 0.0, 1.0)

	# 정치 고문석이 비어 있으면 중립이다. 세 자리의 평균이라 매파 한 명이
	# 앉는 것만으로는 전쟁이 나지 않는다 — 내각이 매파로 채워져야 기운다.
	n.war_hawk = hawk_sum / hawk_count if hawk_count > 0 else 0.5
	n.suppression_will = suppression_sum / hawk_count if hawk_count > 0 else 0.5

	n.law_change_speed = 1.0 + political * 1.2
	n.unrest_suppression = political * 0.35
	n.diplo_bonus = political * 18.0

	n.tech_rate = 1.0 + tech * 0.8
	n.infra_cost_mult = 1.0 - tech * 0.30

	n.inflation_damping = economic * 0.45
	n.tax_efficiency = 0.7 + economic * 0.5
	n.credit_bonus = economic * 0.15

	n.army_modifier = 1.0 + military * 0.35
	n.supply_range_mult = 1.0 + military * 0.30
	n.military_modifier = n.bankruptcy_military_mult
	if not is_equal_approx(previous_supply_range, n.supply_range_mult):
		n.supply_dirty = true

	n.navy_modifier = 1.0 + naval * 0.40
	n.sea_supply_mult = 1.0 + naval * 0.35
