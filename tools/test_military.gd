extends SceneTree

## M7 보급·전투 회귀 테스트.
##
##   godot4 --headless --path . --script res://tools/test_military.gd


func _initialize() -> void:
	_test_supply_table()
	_test_enemy_province_blocks_supply()
	_test_city_is_secondary_source()
	_test_lanchester_casualties_are_deterministic()
	_test_destroyed_army_releases_general()
	_test_low_supply_attrition()
	_test_general_effects_reach_army()
	_test_default_halves_army_morale()
	_test_military_share_follows_culture_and_desperation()
	_test_standing_army_converges_to_gdp_share()
	_test_conscription_law_caps_manpower()
	_test_morale_returns_to_conscription_baseline()
	print("military tests: PASS")
	quit(0)


func _test_supply_table() -> void:
	var wilderness := _chain_world(15, 0.0)
	var road := _chain_world(15, 6.0)
	var nearby := _chain_world(5, 1.0)
	var hostile := _chain_world(5, 1.0, 1.8, 1.0)

	assert(is_equal_approx(_target_supply(wilderness), 0.05),
		"15칸 인프라 0 황무지는 보급 0.05여야 한다")
	assert(absf(_target_supply(road) - 0.92) < 0.015,
		"15칸 인프라 6 도로망은 보급 약 0.92여야 한다")
	assert(absf(_target_supply(nearby) - 0.90) < 0.015,
		"5칸 인프라 1 낙후지는 보급 약 0.90이어야 한다")
	assert(is_equal_approx(_target_supply(hostile), 0.05),
		"5칸 산악·불온·인프라 1 지역은 보급 0.05여야 한다")


func _test_enemy_province_blocks_supply() -> void:
	var world := _chain_world(3, 4.0)
	var n: Nation = world.nations[0]
	world.provinces[1].owner_nation = 1
	var blocked := Supply.compute_supply_field(world, n)
	assert(is_equal_approx(blocked[3], 0.05), "적 영토는 보급선을 차단해야 한다")
	world.provinces[1].occupied_by_nation = n.id
	var occupied := Supply.compute_supply_field(world, n)
	assert(occupied[3] > 0.9, "점령한 적 영토는 보급선으로 사용할 수 있어야 한다")


func _test_city_is_secondary_source() -> void:
	var world := _chain_world(15, 0.0)
	world.provinces[10].has_city = true
	var field := Supply.compute_supply_field(world, world.nations[0])
	# 도시 초기 비용 28, 이후 황무지 5칸 비용 50 → 총 78.
	assert(absf(field[15] - Supply.supply_from_cost(78.0, 1.0)) < 0.001)
	assert(field[15] > 0.3, "도시가 먼 황무지의 보급을 실질적으로 개선해야 한다")


func _test_lanchester_casualties_are_deterministic() -> void:
	var world := _battle_world()
	var a := Military.create_army(world, world.nations[0], 0, 1500)
	var b := Military.create_army(world, world.nations[1], 1, 1000)
	var result := Military.resolve_battle(world, a, b)
	assert(result["casualties_a"] == 72)
	assert(result["casualties_b"] == 72)
	assert(a.troops == 1428 and b.troops == 928)


func _test_low_supply_attrition() -> void:
	var army := Army.new()
	army.troops = 10000
	army.supply_ratio = 0.05
	army.attrition_res = 0.25
	army.morale = 1.0
	Military.tick_attrition(army)
	assert(army.troops == 9697)
	assert(absf(army.morale - 0.973) < 0.0001)


func _test_destroyed_army_releases_general() -> void:
	var world := _battle_world()
	var a := Military.create_army(world, world.nations[0], 0, 1)
	var b := Military.create_army(world, world.nations[1], 1, 1)
	var general := Character.new()
	general.id = 0
	general.nation_id = 0
	world.characters = [general]
	world.nations[0].characters = [general.id]
	assert(Military.assign_general(world, a, general.id))
	Military.resolve_battle(world, a, b)
	assert(not a.is_alive and not b.is_alive)
	assert(a.general_id == -1 and general.role == Character.Role.NONE,
		"군대가 소멸하면 생존 장군은 다시 후보자로 돌아가야 한다")


func _test_general_effects_reach_army() -> void:
	var world := _battle_world()
	var army := Military.create_army(world, world.nations[0], 0, 1000)
	var general := Character.new()
	general.id = 0
	general.nation_id = 0
	general.charisma = 80.0
	general.health = 75.0
	general.intelligence = 60.0
	general.creativity = 50.0
	world.characters = [general]
	world.nations[0].characters = [general.id]
	assert(Military.assign_general(world, army, general.id))
	assert(general.role == Character.Role.GENERAL)
	assert(is_equal_approx(army.power_mult, 1.36))
	assert(is_equal_approx(army.attrition_res, 0.30))
	assert(is_equal_approx(army.supply_bonus, 0.15))
	assert(is_equal_approx(army.ambush_chance, 0.10))


func _test_default_halves_army_morale() -> void:
	var world := _battle_world()
	var n: Nation = world.nations[0]
	var army := Military.create_army(world, n, 0, 1000)
	army.morale = 0.8
	Credit.trigger_default(world, n)
	assert(is_equal_approx(army.morale, 0.4), "파산 시 전군 사기가 절반이어야 한다")


func _test_military_share_follows_culture_and_desperation() -> void:
	var warlike := _economy_nation(0.9)
	var pacifist := _economy_nation(0.1)
	assert(BudgetAI.military_share(warlike) > BudgetAI.military_share(pacifist) * 2.0,
		"호전적 문화가 GDP 대비 군사비를 더 많이 쓴다")

	var calm := BudgetAI.military_share(warlike)
	warlike.at_foreign_war = true
	assert(BudgetAI.military_share(warlike) > calm, "전시에는 군사비가 늘어난다")
	warlike.at_foreign_war = false

	warlike.debt = Credit.credit_limit(warlike)
	assert(BudgetAI.military_share(warlike) < calm,
		"신용한도를 소진하면 군대부터 줄인다")


func _test_standing_army_converges_to_gdp_share() -> void:
	var world := _battle_world()
	var n: Nation = world.nations[0]
	n.population = 100000.0
	n.gdp = 1000000.0

	# 1인당 GDP 10 × 4.0 = 병사 단가 40, 목표 = GDP × 3.7% / 40 = 925.
	var cost := Military.plan_spending(world, n)
	assert(Military.total_troops(world, n) == 111, "한 턴 증병은 목표의 12%로 제한된다")
	assert(absf(cost - 11100.0) < 0.5, "군사비 = 유지비 + 모집비")

	for i in range(60):
		Military.plan_spending(world, n)
	assert(Military.total_troops(world, n) == 925, "병력은 목표치로 수렴한다")
	var steady := Military.plan_spending(world, n)
	assert(absf(steady / n.gdp - BudgetAI.military_share(n)) < 0.001,
		"수렴 후 군사비는 정확히 GDP 비율이다")

	# 재정난이 오면 AI 가 스스로 병력을 줄인다 (§0.3).
	n.debt = Credit.credit_limit(n)
	Military.plan_spending(world, n)
	assert(Military.total_troops(world, n) < 925, "재정난은 군대를 먼저 깎는다")


func _test_conscription_law_caps_manpower() -> void:
	var n := _economy_nation(0.9)
	n.population = 100000.0
	var base := Military.manpower_cap(n)
	n.laws["conscription"] = _law("conscription", {"manpower": 0.4})
	var levy := Military.manpower_cap(n)
	n.laws["conscription"] = _law("conscription", {"manpower": -0.25})
	var volunteer := Military.manpower_cap(n)
	assert(is_equal_approx(base, 2500.0))
	assert(is_equal_approx(levy, 3500.0) and is_equal_approx(volunteer, 1875.0))

	# 총력전 상태의 호전국은 지원병제 상한에 걸린다.
	n.at_foreign_war = true
	n.gdp = 1000000.0
	assert(Military.target_troops(n) == int(volunteer),
		"동원 가능 인구가 전시 목표 병력을 제한해야 한다")


func _test_morale_returns_to_conscription_baseline() -> void:
	var world := _battle_world()
	var n: Nation = world.nations[0]
	n.laws["conscription"] = _law("conscription", {"army_morale": -0.1})
	n.supply_field = PackedFloat32Array([1.0, 1.0])
	var army := Military.create_army(world, n, 0, 1000)
	army.morale = 0.4
	Military.tick(world)
	assert(absf(army.morale - 0.46) < 0.0001, "보급이 충분하면 사기가 회복된다")
	for i in range(20):
		Military.tick(world)
	assert(is_equal_approx(army.morale, 0.9),
		"회복 상한은 징병 법률이 정한 기준선이다")


func _law(category: String, modifiers: Dictionary) -> Law:
	var law := Law.new()
	law.category = category
	law.modifiers = modifiers
	return law


func _economy_nation(aggression: float) -> Nation:
	var n := Nation.new()
	n.id = 0
	n.gdp = 1000000.0
	n.population = 100000.0
	n.culture_params = {"aggression": aggression, "fiscal_prudence": 0.5}
	return n


func _target_supply(world: WorldState) -> float:
	var field := Supply.compute_supply_field(world, world.nations[0])
	return field[field.size() - 1]


func _chain_world(steps: int, infra: float, terrain_supply: float = 1.0,
		unrest: float = 0.0) -> WorldState:
	var world := WorldState.new()
	var n := Nation.new()
	n.id = 0
	n.capital = 0
	world.nations = [n]
	for i in range(steps + 1):
		var p := Province.new()
		p.id = i
		p.owner_nation = n.id
		p.infra = infra
		p.terrain_supply_mult = terrain_supply
		p.unrest = unrest
		if i > 0:
			p.land_neighbors.append(i - 1)
		if i < steps:
			p.land_neighbors.append(i + 1)
		world.provinces.append(p)
		n.provinces.append(i)
	return world


func _battle_world() -> WorldState:
	var world := WorldState.new()
	for i in range(2):
		var n := Nation.new()
		n.id = i
		n.capital = i
		n.culture_params = {"fiscal_prudence": 0.5}
		n.provinces = [i]
		world.nations.append(n)
		var p := Province.new()
		p.id = i
		p.owner_nation = i
		world.provinces.append(p)
	return world
