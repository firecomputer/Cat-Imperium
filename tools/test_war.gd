extends SceneTree

## M8 불만·반란·외교·전쟁 회귀 테스트.
##
##   godot4 --headless --path . --script res://tools/test_war.gd


func _initialize() -> void:
	_test_unrest_drift_signs()
	_test_inflation_dominates_unrest()
	_test_garrison_suppresses_unrest()
	_test_rebellion_spawns_independent_nation()
	_test_city_rebellion_is_three_times_bigger()
	_test_capital_rebellion_relocates_capital()
	_test_losing_last_province_kills_nation()
	_test_single_province_state_cannot_split()
	_test_defender_wins_an_even_fight()
	_test_battle_takes_many_turns()
	_test_siege_is_not_instant_and_forts_slow_it()
	_test_liberating_own_province_clears_occupation()
	_test_occupied_land_pays_no_tax()
	_test_supply_decays_with_invasion_depth()
	_test_naval_control_needs_a_margin()
	_test_sea_supply_needs_naval_control()
	_test_truce_blocks_a_new_war()
	_test_alliance_deters_aggression()
	_test_warscore_follows_occupation()
	_test_demands_prefer_connected_land()
	_test_annexed_exclave_pays_the_price()
	_test_crushing_subjugation_takes_land()
	_test_alliance_expires_when_threat_is_gone()
	print("war tests: PASS")
	quit(0)


func _test_unrest_drift_signs() -> void:
	var world := _world(3)
	var n: Nation = world.nations[0]
	n.culture_params["cohesion"] = 0.6
	assert(Unrest.drift(world.provinces[0], n) < 0.0,
		"수도는 불만이 쌓이지 않아야 한다")

	var far: Province = world.provinces[2]
	far.distance_from_capital = 6.0
	far.culture = Culture.Kind.CHEESE_TABBY
	far.is_exclave = true
	far.integration = 0.0                  # 갓 얻은 변경지. 통합되면 압력이 준다
	assert(Unrest.drift(far, n) > 0.0, "먼 이문화 월경지는 불만이 쌓여야 한다")


func _test_inflation_dominates_unrest() -> void:
	var world := _world(2)
	var n: Nation = world.nations[0]
	var calm := Unrest.drift(world.provinces[0], n)
	n.inflation = 0.35
	var inflated := Unrest.drift(world.provinces[0], n)
	assert(absf(inflated - calm - 0.5) < 0.0001,
		"면제선(10%%) 위 25%%p 인플레는 턴당 불만 +0.5 로 다른 모든 요인을 압도한다")


func _test_garrison_suppresses_unrest() -> void:
	var world := _world(2)
	var n: Nation = world.nations[0]
	var p: Province = world.provinces[1]
	p.distance_from_capital = 5.0
	var bare := Unrest.drift(p, n)
	# 필요 치안 병력만큼 주둔 = garrison_ratio 1.0
	Military.create_army(world, n, p.id, int(Unrest.required_garrison(p)))
	Unrest.refresh_garrisons(world)
	assert(is_equal_approx(p.garrison_ratio, 1.0), "필요 치안 병력을 채우면 완전 주둔이다")
	assert(absf(bare - Unrest.drift(p, n) - Unrest.GARRISON_W) < 0.0001,
		"완전 주둔은 불만 증가를 정확히 GARRISON_W 만큼 상쇄한다")


func _test_rebellion_spawns_independent_nation() -> void:
	var world := _world(3)
	var n: Nation = world.nations[0]
	n.inflation = 0.15                      # drift 를 확실히 양수로 만든다
	var p: Province = world.provinces[2]
	p.unrest = 1.0
	Unrest.tick_province(world, p, n)

	assert(world.nations.size() == 2, "반란군은 독립 국가로 스폰된다")
	var rebel: Nation = world.nations[1]
	assert(rebel.is_rebel and rebel.rebel_origin == n.id, "반란국은 출신국을 기억한다")
	assert(p.owner_nation == rebel.id and not n.provinces.has(p.id),
		"반란 프로빈스는 실제로 국가에서 떨어져 나간다")
	assert(rebel.capital == p.id and rebel.provinces == [p.id], "반란 프로빈스가 반란국의 수도가 된다")
	assert(Diplomacy.are_at_war(world, n.id, rebel.id), "진압 전쟁이 시작된다")
	assert(n.at_war and rebel.at_war, "양쪽 모두 전시 상태가 된다")
	assert(Military.total_troops(world, rebel) == int(p.population * Unrest.REBEL_TROOP_RATIO), "반란 규모는 인구 비례다")
	assert(is_equal_approx(p.unrest, Unrest.REBEL_START_UNREST),
		"반란 성공 직후에는 불만이 내려간다")


func _test_city_rebellion_is_three_times_bigger() -> void:
	var plain := _world(2)
	plain.nations[0].inflation = 0.15
	plain.provinces[1].unrest = 1.0
	Unrest.tick_province(plain, plain.provinces[1], plain.nations[0])

	var city := _world(2)
	city.nations[0].inflation = 0.15
	city.provinces[1].has_city = true
	city.provinces[1].unrest = 1.0
	Unrest.tick_province(city, city.provinces[1], city.nations[0])

	var plain_troops := Military.total_troops(plain, plain.nations[1])
	var city_troops := Military.total_troops(city, city.nations[1])
	assert(city_troops == plain_troops * 3, "도시 반란은 규모 ×3")


func _test_capital_rebellion_relocates_capital() -> void:
	var world := _world(3)
	var n: Nation = world.nations[0]
	n.inflation = 0.15
	world.provinces[1].population = 9000.0
	world.provinces[2].population = 5000.0
	var capital: Province = world.provinces[0]
	capital.unrest = 1.0
	Unrest.tick_province(world, capital, n)

	assert(n.capital == 1, "수도를 잃으면 남은 최대 인구 프로빈스로 옮긴다")
	assert(is_equal_approx(world.provinces[1].distance_from_capital, 0.0), "새 수도의 거리는 0 이다")
	assert(is_equal_approx(world.provinces[2].distance_from_capital, 1.0),
		"수도 이전 후 거리는 다시 계산돼야 한다")


## 마지막 프로빈스는 반란으로 잃을 수 없다. 정복(할양)만이 나라를 지운다.
func _test_losing_last_province_kills_nation() -> void:
	var world := _two_nations()
	var loser: Nation = world.nations[1]
	var winner: Nation = world.nations[0]
	Military.create_army(world, loser, 1, 500)
	world.provinces[1].occupied_by_nation = winner.id
	Peace.annex(world, world.provinces[1], loser, winner, [] as Array[int])

	assert(not loser.is_alive and loser.provinces.is_empty(), "마지막 영토를 잃은 나라는 사라진다")
	assert(Military.total_troops(world, loser) == 0, "국가가 죽으면 군대도 사라진다")
	assert(not loser.at_war and not winner.at_war, "죽은 국가의 전쟁은 정리된다")


func _test_single_province_state_cannot_split() -> void:
	var world := _world(1)
	var n: Nation = world.nations[0]
	n.inflation = 0.50
	world.provinces[0].unrest = 1.0
	Unrest.tick_province(world, world.provinces[0], n)
	assert(world.nations.size() == 1, "1프로빈스 국가는 더 갈라질 수 없다")
	assert(n.is_alive and is_equal_approx(world.provinces[0].unrest, 0.99), "불만은 남지만 나라는 쪼개지지 않는다")


func _test_defender_wins_an_even_fight() -> void:
	var world := _two_nations()
	var mountain: Province = world.provinces[1]
	mountain.set_terrain(Province.Terrain.MOUNTAIN)
	mountain.infra = 5.0
	var attacker := Military.create_army(world, world.nations[0], 1, 1000)
	var defender := Military.create_army(world, world.nations[1], 1, 1000)
	Military.resolve_province_battles(world)
	assert(attacker.troops < defender.troops,
		"같은 병력이면 지형·요새를 쥔 방어 측이 이겨야 한다")
	assert(is_equal_approx(WarAI.defense_mult(mountain), 1.45 * 1.2), "산악(1.45)×인프라5(1.2) 가 그대로 방어 배율이 된다")


func _test_battle_takes_many_turns() -> void:
	var world := _two_nations()
	var strong := Military.create_army(world, world.nations[0], 1, 3000)
	var weak := Military.create_army(world, world.nations[1], 1, 300)
	Military.resolve_province_battles(world)
	assert(weak.is_alive, "3배 전력차여도 한 턴에 전멸하지 않는다")
	var turns := 1
	while weak.is_alive and turns < 100:
		Military.resolve_province_battles(world)
		turns += 1
	assert(turns >= 5, "전투는 여러 턴에 걸쳐 결판난다 (실제 %d턴)" % turns)
	assert(strong.troops > 2000, "압승한 쪽도 손실은 있지만 궤멸하지 않는다")


func _test_siege_is_not_instant_and_forts_slow_it() -> void:
	var world := _two_nations()
	var target: Province = world.provinces[1]
	var army := Military.create_army(world, world.nations[0], 1, 2000)
	world.rebuild_army_index()
	var turns := 0
	while target.occupied_by_nation < 0 and turns < 200:
		Military.tick_sieges(world)
		turns += 1
	assert(turns >= 4, "공성은 즉시 끝나지 않는다 (실제 %d턴)" % turns)
	assert(target.occupied_by_nation == 0, "공성이 끝나면 점령이 성립한다")

	var fortified := _two_nations()
	fortified.provinces[1].infra = 8.0
	fortified.provinces[1].has_city = true
	var sieger := Military.create_army(fortified, fortified.nations[0], 1, 2000)
	assert(Military.siege_rate(fortified.provinces[1], sieger)
		< Military.siege_rate(target, army),
		"인프라와 도시는 공성을 늦춘다")


func _test_liberating_own_province_clears_occupation() -> void:
	var world := _two_nations()
	var mine: Province = world.provinces[0]
	mine.occupied_by_nation = 1
	Military.occupy(world, mine, world.nations[0])
	assert(mine.occupied_by_nation == -1, "되찾은 내 땅은 점령 상태가 풀려야 한다")


func _test_occupied_land_pays_no_tax() -> void:
	var world := _two_nations()
	Economy.aggregate(world)
	var full := world.nations[0].controlled_gdp
	world.provinces[0].occupied_by_nation = 1
	Economy.aggregate(world)
	assert(world.nations[0].gdp > 0.0 and is_equal_approx(world.nations[0].controlled_gdp, 0.0),
		"점령당한 땅은 GDP 에는 남지만 세수에서는 빠진다")
	assert(full > 0.0, "점령 전에는 전 영토에서 세금이 걷힌다")


func _test_supply_decays_with_invasion_depth() -> void:
	var world := _world(7)
	var invader := Nation.new()
	invader.id = 1
	invader.capital = 0
	world.nations.append(invader)
	# 0~1 은 침공국 땅, 2~6 은 적 땅.
	var defender: Nation = world.nations[0]
	for i in range(2):
		world.provinces[i].owner_nation = invader.id
		invader.provinces.append(i)
		defender.provinces.erase(i)
	Diplomacy.declare_war(world, invader, defender, "test")
	var field := Supply.compute_supply_field(world, invader)
	assert(field[1] > 0.9, "자국 영토는 완전 보급된다")
	assert(field[2] > 0.5, "국경 너머 한 칸은 아직 버틸 만하다")
	assert(field[2] > field[3] and field[3] > field[4], "깊이 들어갈수록 보급이 무너진다")
	assert(field[5] <= 0.1, "적진 깊숙이는 굶는다 — 포위망이 성립한다")


func _test_naval_control_needs_a_margin() -> void:
	var world := _two_nations()
	Naval._create_fleet(world, world.nations[0], 7, 20)
	Naval._create_fleet(world, world.nations[1], 7, 19)
	Naval.refresh_control(world)
	assert(world.nations[0].naval_control_zones.is_empty(),
		"박빙인 바다는 아무도 통제하지 못한다")
	world.fleets[0].ships = 40
	Naval.refresh_control(world)
	assert(world.nations[0].naval_control_zones.has(7), "확실히 앞선 쪽이 제해권을 쥔다")
	assert(not world.nations[1].naval_control_zones.has(7), "진 쪽은 제해권을 갖지 못한다")


func _test_sea_supply_needs_naval_control() -> void:
	var world := _island_world()
	var n: Nation = world.nations[0]
	var without := Supply.compute_supply_field(world, n)
	assert(is_equal_approx(without[1], Supply.MIN_SUPPLY),
		"제해권이 없으면 섬 영토는 보급이 끊긴다")
	n.naval_control_zones[5] = true
	var with_navy := Supply.compute_supply_field(world, n)
	assert(with_navy[1] > 0.5, "제해권을 쥐면 바다 건너로 보급이 간다")


func _test_truce_blocks_a_new_war() -> void:
	var world := _two_nations()
	var a: Nation = world.nations[0]
	var b: Nation = world.nations[1]
	var war := Diplomacy.declare_war(world, a, b, "test")
	Diplomacy.end_war(world, war, "white_peace")
	Diplomacy.set_truce(world, a, b)
	assert(a.truces.has(b.id) and not a.at_war, "강화 직후에는 휴전 상태다")
	a.threat[b.id] = 1.0
	a.opinion[b.id] = -100.0
	Diplomacy._consider_war(world, a)
	assert(not a.at_war, "휴전 중에는 다시 선전포고하지 않는다")


func _test_alliance_deters_aggression() -> void:
	var world := _two_nations()
	var a: Nation = world.nations[0]
	var b: Nation = world.nations[1]
	Military.create_army(world, a, 0, 1000)
	Military.create_army(world, b, 1, 1000)
	a.threat[b.id] = 0.9
	var alone := Diplomacy.war_appetite(world, a, b.id)

	var ally := Nation.new()
	ally.id = 2
	world.nations.append(ally)
	Military.create_army(world, ally, 1, 3000)
	b.allies.append(ally.id)
	var deterred := Diplomacy.war_appetite(world, a, b.id)
	assert(deterred < alone - 1.0, "방어동맹은 개전 의욕을 확실히 꺾는다")
	assert(alone > 0.0 and deterred < 0.0, "동맹이 없으면 치고, 있으면 못 친다")


func _test_warscore_follows_occupation() -> void:
	var world := _two_nations()
	var war := Diplomacy.declare_war(world, world.nations[0], world.nations[1], "test")
	Peace.update_warscore(world, war)
	assert(is_equal_approx(war.warscore, 0.0), "점령이 없으면 전쟁 점수는 0 이다")
	world.provinces[1].occupied_by_nation = 0
	Peace.update_warscore(world, war)
	assert(war.warscore > 60.0, "적 영토를 다 점령하면 전쟁 점수가 크게 오른다")
	world.provinces[1].occupied_by_nation = -1
	world.provinces[0].occupied_by_nation = 1
	Peace.update_warscore(world, war)
	assert(war.warscore < -60.0, "반대로 당하면 점수가 음수가 된다")


func _test_demands_prefer_connected_land() -> void:
	var world := _demand_world()
	var winner: Nation = world.nations[0]
	var loser: Nation = world.nations[1]
	var ranked := Peace.rank_demands(world, winner, loser, [] as Array[int])
	assert(ranked.size() == 1, "고립된 적지는 요구 대상이 아니다")
	assert(int(ranked[0]["province"]) == 1, "육상으로 이어진 땅을 먼저 요구한다")

	# 1 번을 확정하면 그 너머 2 번이 새로 연결된다 (§12.3 주의).
	var next := Peace.rank_demands(world, winner, loser, [1] as Array[int])
	assert(next.size() == 1 and int(next[0]["province"]) == 2,
		"먹은 땅 너머가 새로 연결돼 국경이 한 덩어리로 자란다")


func _test_annexed_exclave_pays_the_price() -> void:
	var world := _demand_world()
	var winner: Nation = world.nations[0]
	var loser: Nation = world.nations[1]
	var far: Province = world.provinces[3]
	Peace.annex(world, far, loser, winner, [] as Array[int])
	assert(far.owner_nation == winner.id and far.is_exclave, "바다 건너 땅은 월경지가 된다")
	assert(is_equal_approx(far.admin_cost_mult, Peace.EXCLAVE_ADMIN_MULT),
		"월경지는 행정비가 2.4배로 뛴다 (§12.4)")
	assert(is_equal_approx(far.unrest, Peace.CEDED_UNREST),
		"월경지의 대가는 즉시 불만 폭발이 아니라 지속 불만·행정부하가 담당한다")
	assert(is_equal_approx(far.integration, 0.0), "할양지는 미통합 상태에서 시작한다")
	assert(loser.claims.has(far.id), "빼앗긴 쪽에는 실지회복 명분이 남는다")


## 인접한 두 나라, 각 1프로빈스. 프로빈스 0 은 0번국, 1 은 1번국 소유다.
func _two_nations() -> WorldState:
	var world := WorldState.new()
	for i in range(2):
		var n := Nation.new()
		n.id = i
		n.capital = i
		n.culture = Culture.Kind.KOREAN_SHORTHAIR
		n.culture_params = Culture.PRESETS[n.culture].duplicate()
		n.provinces = [i]
		world.nations.append(n)
		var p := Province.new()
		p.id = i
		p.owner_nation = i
		p.culture = n.culture
		p.population = 10000.0
		p.gdp = 1000000.0
		p.gdp_pc = 100.0
		p.infra = 2.0
		p.land_neighbors = [1 - i]
		world.provinces.append(p)
	Diplomacy.declare_war(world, world.nations[0], world.nations[1], "test")
	world.rebuild_army_index()
	return world


## 본토(0)와 바다 건너 섬(1). 둘 다 같은 나라 땅이고 분지 5 를 공유한다.
func _island_world() -> WorldState:
	var world := WorldState.new()
	var n := Nation.new()
	n.id = 0
	n.capital = 0
	world.nations.append(n)
	for i in range(2):
		var p := Province.new()
		p.id = i
		p.owner_nation = 0
		p.infra = 3.0
		p.sea_zone_ids = PackedInt32Array([5])
		world.provinces.append(p)
		n.provinces.append(i)
	world.provinces[1].is_island = true
	world.sea_zones.resize(6)
	var zone := SeaZone.new()
	zone.id = 5
	zone.coast_provinces = PackedInt32Array([0, 1])
	world.sea_zones[5] = zone
	return world


## 승자(0) — 적지 1 — 적지 2 — 고립된 적지 3. 1,2,3 은 모두 점령 상태다.
func _demand_world() -> WorldState:
	var world := WorldState.new()
	for i in range(2):
		var n := Nation.new()
		n.id = i
		n.capital = 0 if i == 0 else 1
		n.culture = Culture.Kind.KOREAN_SHORTHAIR
		n.culture_params = Culture.PRESETS[n.culture].duplicate()
		world.nations.append(n)
	for i in range(4):
		var p := Province.new()
		p.id = i
		p.owner_nation = 0 if i == 0 else 1
		p.population = 10000.0
		p.gdp = 1000000.0
		p.centroid = Vector2(float(i), 0.0)
		world.provinces.append(p)
		world.nations[p.owner_nation].provinces.append(i)
		if i > 0:
			world.provinces[i].occupied_by_nation = 0
	world.provinces[0].land_neighbors = [1]
	world.provinces[1].land_neighbors = [0, 2]
	world.provinces[2].land_neighbors = [1]
	world.provinces[3].land_neighbors = []
	world.nations[1].gdp = 3000000.0
	world.rng_pool = RngPool.new(1)
	return world


## 사슬 모양 국가 하나. 프로빈스 0 이 수도다.
func _world(count: int) -> WorldState:
	var world := WorldState.new()
	var n := Nation.new()
	n.id = 0
	n.capital = 0
	n.culture = Culture.Kind.KOREAN_SHORTHAIR
	n.culture_params = Culture.PRESETS[n.culture].duplicate()
	world.nations.append(n)
	for i in range(count):
		var p := Province.new()
		p.id = i
		p.owner_nation = 0
		p.culture = n.culture
		p.population = 10000.0
		p.gdp = 1000000.0
		p.infra = 3.0
		p.distance_from_capital = float(i)
		p.centroid = Vector2(float(i), 0.0)
		if i > 0:
			p.land_neighbors.append(i - 1)
		if i < count - 1:
			p.land_neighbors.append(i + 1)
		world.provinces.append(p)
		n.provinces.append(i)
	return world


## SUBJUGATION 전쟁은 35 만 넘으면 땅을 한 뼘도 안 뺏고 속국화로 끝났다 —
## warscore 100 이어도 같았다 (M10 §3.1).
func _test_crushing_subjugation_takes_land() -> void:
	for score in [50.0, 95.0]:
		var world := _two_nations()
		world.rng_pool = RngPool.new(3)    # rank_demands 의 해상 요구 판정이 쓴다
		var war: War = world.wars[0]
		war.goal = War.Goal.SUBJUGATION
		war.goal_score = Peace.SUBJUGATION_SCORE
		war.warscore = score
		var winner: Nation = world.nations[0]
		var loser: Nation = world.nations[1]
		# _province_cost 는 loser.gdp 로 나눈다. 집계값은 Economy 가 채우므로
		# 이 헬퍼 세계에서는 직접 넣어 준다.
		winner.gdp = world.provinces[0].gdp
		loser.gdp = world.provinces[1].gdp
		world.provinces[1].occupied_by_nation = winner.id
		Peace._settle(world, war, true)
		if score < Peace.ANNEX_OVER_VASSAL_SCORE:
			assert(loser.overlord == winner.id,
				"보통의 복속전은 속국화로 끝난다 (%.0f)" % score)
			assert(winner.provinces.size() == 1, "속국화는 영토를 뺏지 않는다")
		else:
			assert(winner.provinces.size() > 1,
				"압승은 영토를 먹는다 (%.0f, 프로빈스 %d)" % [score, winner.provinces.size()])


## 설계서 §11.4. 만료 없는 동맹은 영구 불가침이라 정복이 사라진다.
## 만료는 해지가 아니라 재심사다 — 공동 위협이 남아 있으면 갱신한다.
func _test_alliance_expires_when_threat_is_gone() -> void:
	# 0 과 1 이 2 를 공동으로 두려워해 맺은 동맹.
	var world := _world(3)
	for i in range(1, 3):
		var m := Nation.new()
		m.id = i
		m.capital = i
		m.culture = Culture.Kind.KOREAN_SHORTHAIR
		m.culture_params = Culture.PRESETS[m.culture].duplicate()
		m.provinces = [i]
		world.provinces[i].owner_nation = i
		world.nations[0].provinces.erase(i)
		world.nations.append(m)
	var a: Nation = world.nations[0]
	var b: Nation = world.nations[1]
	a.allies = [1]
	b.allies = [0]
	a.alliance_expiry[1] = world.turn
	b.alliance_expiry[0] = world.turn

	# 공동 위협이 살아 있으면 갱신된다.
	a.threat[2] = 0.9
	b.threat[2] = 0.9
	Diplomacy._expire_alliances(world)
	assert(a.allies.has(1), "공동 위협이 남아 있으면 동맹은 갱신된다")
	assert(int(a.alliance_expiry[1]) > world.turn, "갱신은 임기를 다시 준다")

	# 위협이 사라지면 만료된다.
	a.alliance_expiry[1] = world.turn
	b.alliance_expiry[0] = world.turn
	a.threat[2] = 0.0
	b.threat[2] = 0.0
	Diplomacy._expire_alliances(world)
	assert(not a.allies.has(1) and not b.allies.has(0),
		"공동 위협이 사라지면 임기 만료로 해지된다")
	assert(not a.alliance_expiry.has(1), "해지는 만료 기록도 지운다")
