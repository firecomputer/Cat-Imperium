extends SceneTree

## M6 인물 회귀 테스트.
##
##   godot4 --headless --path . --script res://tools/test_characters.gd


func _initialize() -> void:
	_test_cultural_names_are_deterministic()
	_test_education_changes_talent_pool()
	_test_initial_pool_and_seven_advisors()
	_test_death_fills_vacancy()
	_test_merit_changes_appointment_priority()
	_test_general_effects()
	_test_disloyal_general_requests_rebellion_once()
	_test_founding_cohort_deaths_are_staggered()
	_test_lifespan_reaches_two_hundred()
	print("character tests: PASS")
	quit(0)


func _test_cultural_names_are_deterministic() -> void:
	for culture in range(Culture.Kind.size()):
		var a := RandomNumberGenerator.new()
		var b := RandomNumberGenerator.new()
		a.seed = 1000 + culture
		b.seed = 1000 + culture
		var seen := {}
		for i in range(30):
			var name_a := CharacterSystem.generate_name(culture, a)
			var name_b := CharacterSystem.generate_name(culture, b)
			assert(name_a == name_b, "이름 생성은 같은 시드에서 결정론적이어야 한다")
			assert(not name_a.is_empty())
			seen[name_a] = true
		assert(seen.size() >= 20, "문화별 이름 조합이 지나치게 작다")


func _test_education_changes_talent_pool() -> void:
	var low := _nation_with_education(-0.4)
	var high := _nation_with_education(0.5)
	var p := _province()
	var low_world := _world(low, p, 11)
	var high_world := _world(high, p, 11)
	var low_rng := RandomNumberGenerator.new()
	var high_rng := RandomNumberGenerator.new()
	low_rng.seed = 77
	high_rng.seed = 77
	for i in range(500):
		CharacterSystem.spawn_character(low_world, low, p, 0, low_rng)
		CharacterSystem.spawn_character(high_world, high, p, 0, high_rng)
	var low_talent := _mean_talent(low_world)
	var high_talent := _mean_talent(high_world)
	assert(high_talent > low_talent + 20.0,
		"보편교육과 교육방임의 평균 능력 차이가 충분히 커야 한다: %.2f vs %.2f" % [
			high_talent, low_talent])


func _test_initial_pool_and_seven_advisors() -> void:
	var n := _nation_with_education(0.1)
	var p := _province()
	var world := _world(n, p, 91)
	CharacterSystem.initialize(world)
	assert(n.characters.size() == CharacterSystem.INITIAL_CHARACTERS_PER_NATION)
	assert(_advisor_count(world, n) == 7, "고문석은 7개여야 한다")
	assert(_role_count(world, n, Character.Role.POLITICAL) == 3)
	for role in [Character.Role.TECH, Character.Role.ECONOMIC,
		Character.Role.MILITARY, Character.Role.NAVAL]:
		assert(_role_count(world, n, role) == 1)
	AdvisorEffects.apply(world)
	assert(n.law_change_speed > 1.0)
	assert(n.infra_cost_mult < 1.0)
	assert(n.credit_bonus > 0.0)


func _test_death_fills_vacancy() -> void:
	var n := _nation_with_education(0.1)
	var p := _province()
	var world := _world(n, p, 123)
	CharacterSystem.initialize(world)
	var dead_id := -1
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if c.role == Character.Role.ECONOMIC:
			dead_id = cid
			c.death_turn = world.turn
			break
	assert(dead_id >= 0)
	p.population = 0.0                       # 이 테스트에서는 신규 배출을 막는다
	CharacterSystem.tick(world)
	assert(not world.characters[dead_id].is_alive)
	assert(_role_count(world, n, Character.Role.ECONOMIC) == 1,
		"고문 사망 뒤 기존 후보자가 공석을 채워야 한다")


func _test_general_effects() -> void:
	var c := Character.new()
	c.charisma = 80.0
	c.health = 75.0
	c.intelligence = 60.0
	c.creativity = 50.0
	var effects := c.general_effects()
	assert(is_equal_approx(effects["power_mult"], 1.36))
	assert(is_equal_approx(effects["attrition_res"], 0.30))
	assert(is_equal_approx(effects["supply_bonus"], 0.15))
	assert(is_equal_approx(effects["ambush_chance"], 0.10))


func _test_merit_changes_appointment_priority() -> void:
	var n := _nation_with_education(0.0)
	var world := _world(n, _province(), 9)
	var talented := Character.new()
	talented.id = 0
	talented.nation_id = n.id
	talented.intelligence = 100.0
	talented.creativity = 100.0
	talented.noble_birth = 0.0
	var noble := Character.new()
	noble.id = 1
	noble.nation_id = n.id
	noble.intelligence = 50.0
	noble.creativity = 50.0
	noble.noble_birth = 1.0
	world.characters = [talented, noble]
	n.characters = [talented.id, noble.id]
	assert(CharacterSystem._best_candidate(world, n, Character.Role.ECONOMIC, 1.0) == talented,
		"능력주의는 실력이 높은 후보자를 뽑아야 한다")
	assert(CharacterSystem._best_candidate(world, n, Character.Role.ECONOMIC, -1.0) == noble,
		"세습제는 귀족 출신 우대를 등용 결과에 반영해야 한다")


func _test_disloyal_general_requests_rebellion_once() -> void:
	var n := _nation_with_education(0.0)
	var p := _province()
	p.population = 0.0
	var world := _world(n, p, 13)
	var general := Character.new()
	general.id = 0
	general.nation_id = n.id
	general.name = "반란 장군"
	general.home_province = p.id
	general.role = Character.Role.GENERAL
	general.loyalty = 0.14
	general.death_turn = 999
	world.characters = [general]
	n.characters = [general.id]
	CharacterSystem.tick(world)
	CharacterSystem.tick(world)
	var requests := 0
	for event in world.events:
		if event["kind"] == "rebellion_requested":
			requests += 1
	assert(requests == 1, "불충한 장군의 반란 요청은 한 번만 발생해야 한다")


func _nation_with_education(value: float) -> Nation:
	var n := Nation.new()
	n.id = 0
	n.culture = Culture.Kind.KOREAN_SHORTHAIR
	n.culture_params = Culture.PRESETS[n.culture].duplicate()
	n.provinces = [0]
	var law := Law.new()
	law.id = "test_education"
	law.category = "education"
	law.modifiers = {"education": value}
	n.laws["education"] = law
	return n


func _province() -> Province:
	var p := Province.new()
	p.id = 0
	p.owner_nation = 0
	p.infra = 4.0
	p.population = 100000.0
	p.gdp_pc = 700.0
	p.gdp = p.population * p.gdp_pc
	p.has_city = true
	return p


func _world(n: Nation, p: Province, seed: int) -> WorldState:
	var world := WorldState.new()
	world.world_seed = seed
	world.rng_pool = RngPool.new(seed)
	world.nations = [n]
	world.provinces = [p]
	return world


func _mean_talent(world: WorldState) -> float:
	var total := 0.0
	for c in world.characters:
		total += (c.intelligence + c.charisma + c.creativity) / 3.0
	return total / maxf(world.characters.size(), 1)


func _advisor_count(world: WorldState, n: Nation) -> int:
	var count := 0
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if c.is_alive and Character.is_advisor_role(c.role):
			count += 1
	return count


func _role_count(world: WorldState, n: Nation, role: int) -> int:
	var count := 0
	for cid in n.characters:
		var c: Character = world.characters[cid]
		if c.is_alive and c.role == role:
			count += 1
	return count


## 건국 12명이 전부 birth_turn 0 이면 한 세대가 통째로 같은 구간에서 죽어
## 세계의 고문석이 동시에 빈다 (M10 §1.3).
func _test_founding_cohort_deaths_are_staggered() -> void:
	var n := _nation_with_education(0.1)
	var world := _world(n, _province(), 77)
	CharacterSystem.initialize(world)
	var earliest := 1 << 30
	var latest := -1
	for c in world.characters:
		assert(c.is_alive, "건국 시점에는 아무도 죽어 있지 않다")
		earliest = mini(earliest, c.death_turn)
		latest = maxi(latest, c.death_turn)
	assert(latest - earliest >= 60,
		"건국 세대의 사망 턴은 흩어져야 한다 (간격 %d)" % (latest - earliest))


## 수명 상한은 200턴을 넘겨야 한다 — 한 고문이 제국의 전성기를 떠받칠 수 있다.
func _test_lifespan_reaches_two_hundred() -> void:
	var n := _nation_with_education(0.1)
	var law := Law.new()
	law.id = "test_health"
	law.category = "health"
	law.modifiers = {"healthcare": 0.5}
	n.laws["health"] = law
	var world := _world(n, _province(), 99)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	var best := 0
	for i in range(400):
		var c := CharacterSystem.spawn_character(world, n, world.provinces[0], 0, rng)
		best = maxi(best, c.death_turn)
	assert(best >= 200, "건강한 인물의 수명은 200턴에 닿아야 한다 (최대 %d)" % best)
